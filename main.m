//
//  main.m
//  WQMove
//
//  Stripped-down fork of WQ Files (kolbicz/WQFiles, GPL-3.0-or-later):
//  move WeChat chat-record folders between app containers through the
//  worse_query sandbox escape by Taj C (forcequit),
//  https://github.com/forcequitOS/worse_query, GPL-3.0-or-later.
//  This app is GPL-3.0-or-later as well (see LICENSE).
//
//  Only the escape core (WQAccess/WQLaunchServices) is reused unchanged;
//  the UI below is new and minimal: pick a source (a WeChat app or the
//  on-device 聊天记录 temp folder) and a target, pick chat-record folders,
//  move them. A folder in the target that already has the same name is
//  first moved aside into a timestamped folder under 被覆盖的聊天记录 in
//  the Files app container, so nothing is ever overwritten and the
//  displaced folder survives uninstalling this app.
//  Folders that resolve to an account show its wxid and custom WeChat ID
//  under the folder name.
//

#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <math.h>
#import <sqlite3.h>
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import "WQUI.h"
#import "WQMVTransfer.h"

#pragma mark - Small helpers

static NSString *WQMVNormalizedContainerPath(NSString *path)
{
    if ([path hasPrefix:@"/var/"]) {
        return [@"/private/var/" stringByAppendingString:[path substringFromIndex:5]];
    }
    return path;
}

// The 聊天记录 temp folder lives at the ROOT of the Files app's data
// container (not in Documents, so the Files app's own files are
// untouched). It must sit inside a container: the escape can only grant
// container paths, and the sandbox hides /private/var/mobile itself as
// ENOENT. The Files container survives uninstalling this app and
// reinstalling WeChat. The container is resolved and the path persisted
// by WQMVResolveTempFolderPath below (after the resolver).
static NSString *WQMVTempFolderName(void)
{
    return @"聊天记录";
}

// The one and only host: the Files app. No fallback to another host.
static NSString *WQMVTempHostBundleID(void)
{
    return @"com.apple.DocumentsApp";
}

static NSString *const kWQMVTempFolderPathKey = @"WQMVTempFolderPath";
static NSString *const kWQMVPinnedBundleIDsKey = @"WQMVPinnedBundleIDs";

static BOOL WQMVIsHex32FolderName(NSString *name)
{
    if (name.length != 32) return NO;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!hex) return NO;
    }
    return YES;
}

// The all-zero folder is not a chat-record folder: never listed, never
// selectable, in either folder view.
static BOOL WQMVIsAllZeroFolderName(NSString *name)
{
    return [name isEqualToString:@"00000000000000000000000000000000"];
}

// Enterprise WeChat is excluded from the auto-detected list only; the
// 全部 App search shows every app, including it.
static BOOL WQMVIsEnterpriseWeChat(NSString *bundleID, NSString *_Nullable displayName)
{
    if (displayName.length && [displayName containsString:@"企业微信"]) return YES;
    if ([bundleID isEqualToString:@"com.tencent.wework"]) return YES;
    if ([[bundleID lowercaseString] containsString:@"wework"]) return YES;
    return NO;
}

// The official WeChat gets the green 官方 tag. Exact bundle-ID match only.
static BOOL WQMVIsOfficialWeChat(NSString *bundleID)
{
    return [bundleID isEqualToString:@"com.tencent.xin"];
}

// Explicit auto-detection exclusion list: these Tencent apps are
// never auto-listed, even though their bundle IDs start with
// com.tencent. (checked before every match rule in
// detectWeChatApps). This is NOT a whitelist: a Tencent app not
// listed here is still auto-listed by the prefix rule. Exclusion
// affects auto-detection only: the 全部 App list still shows these
// apps, and they can still be pinned.
static BOOL WQMVIsExcludedFromAutoDetect(NSString *bundleID)
{
    static NSSet<NSString *> *excluded = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excluded = [NSSet setWithArray:@[
            @"com.tencent.ww", @"com.tencent.mqq", @"com.tencent.mqqi",
            @"com.tencent.qzone", @"com.tencent.weread", @"com.tencent.wetype",
            @"com.tencent.QQMusic", @"com.tencent.live4iphone", @"com.tencent.QQKSong",
            @"com.tencent.ied.app.comic", @"com.tencent.sportskbs", @"com.tencent.info",
            @"com.tencent.kairos4iphone", @"com.tencent.mttlite", @"com.tencent.qqmail",
            @"com.tencent.txdocs", @"com.tencent.meeting", @"com.tencent.sosomap",
            @"com.tencent.weiyun", @"com.tencent.mqqsecure", @"com.tencent.qqtranslator",
            @"com.tencent.portfolio", @"com.tencent.photogallery", @"com.tencent.tgclub",
            @"com.tencent.cmocmna", @"com.tencent.smoba", @"com.tencent.ngr",
            @"com.tencent.tmgp.pubgmhd", @"com.tencent.tmgp.cf", @"com.tencent.pocket",
            @"com.tencent.qqfarmios", @"com.tencent.Q108", @"com.tencent.ddtank",
        ]];
    });
    return [excluded containsObject:bundleID];
}

// Pinned apps (long-press 添加到首页 in 全部 App): bundle IDs in
// pin order, persisted in NSUserDefaults. Resolution against the
// current app list happens at display time, so a pin whose app was
// uninstalled disappears on its own.
static NSArray<NSString *> *WQMVPinnedBundleIDs(void)
{
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kWQMVPinnedBundleIDsKey];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id entry in stored) {
        if ([entry isKindOfClass:[NSString class]] && [(NSString *)entry length]) [ids addObject:entry];
    }
    return ids;
}

static void WQMVAddPinnedBundleID(NSString *bundleID)
{
    if (!bundleID.length) return;
    NSMutableArray<NSString *> *ids = [WQMVPinnedBundleIDs() mutableCopy];
    if (![ids containsObject:bundleID]) {
        [ids addObject:bundleID];
        [[NSUserDefaults standardUserDefaults] setObject:ids forKey:kWQMVPinnedBundleIDsKey];
    }
}

static void WQMVRemovePinnedBundleID(NSString *bundleID)
{
    if (!bundleID.length) return;
    NSMutableArray<NSString *> *ids = [WQMVPinnedBundleIDs() mutableCopy];
    [ids removeObject:bundleID];
    [[NSUserDefaults standardUserDefaults] setObject:ids forKey:kWQMVPinnedBundleIDsKey];
}

// The app itself must never appear as a move source or target: its own
// display name contains 微信, so the auto-list would otherwise offer it.
// The own bundle ID is resolved at runtime so the exclusion survives any
// future bundle-ID change; no literal is hardcoded here.
static BOOL WQMVIsSelfApp(NSString *bundleID)
{
    NSString *ownBundleID = [[NSBundle mainBundle] bundleIdentifier];
    return ownBundleID.length && [bundleID isEqualToString:ownBundleID];
}

static UIColor *WQMVWeChatGreen(void)
{
    return [UIColor colorWithRed:0x07 / 255.0 green:0xC1 / 255.0 blue:0x60 / 255.0 alpha:1.0];
}

// iOS system blue (#007AFF), for the custom WeChat ID tag.
static UIColor *WQMVTagBlue(void)
{
    return [UIColor colorWithRed:0x00 / 255.0 green:0x7A / 255.0 blue:0xFF / 255.0 alpha:1.0];
}

// Folder names shown in the live progress label: 32-hex names fit whole,
// longer names are cut with an ellipsis (grapheme-safe).
static NSString *WQMVTruncatedFolderName(NSString *name)
{
    if (name.length <= 32) return name;
    NSRange range = [name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 29)];
    return [[name substringWithRange:range] stringByAppendingString:@"…"];
}

// Small rounded pill with the given text and background color: bold
// 12pt white text, 6pt horizontal padding per side, 20pt tall, fully
// rounded. Used only by the green 官方 tag in the app picker; the
// folder-row identity pills use the fixed-slot builder below.
// The width constraint is one notch below required so a very long tag
// can compress (clipped by masksToBounds) instead of breaking the row
// layout; the height stays exact.
static UIView *WQMVTagViewWithTextAndColor(NSString *text, UIColor *backgroundColor)
{
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont boldSystemFontOfSize:12];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label sizeToFit];
    CGFloat tagWidth = label.bounds.size.width + 12;
    UIView *tag = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tagWidth, 20)];
    tag.backgroundColor = backgroundColor;
    tag.layer.cornerRadius = 10;
    tag.layer.masksToBounds = YES;
    // Explicit size constraints: a stack view sizes arranged subviews by
    // Auto Layout, not by frame, and a plain view has no intrinsic size.
    tag.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *widthConstraint = [tag.widthAnchor constraintEqualToConstant:tagWidth];
    widthConstraint.priority = 999;
    widthConstraint.active = YES;
    [tag.heightAnchor constraintEqualToConstant:20].active = YES;
    label.frame = tag.bounds;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [tag addSubview:label];
    return tag;
}

// Small green rounded pill with the given text: the 官方 tag.
static UIView *WQMVGreenTagViewWithText(NSString *text)
{
    return WQMVTagViewWithTextAndColor(text, WQMVWeChatGreen());
}

// Folder-row identity pill: fills one fixed half-width slot of the
// tag row, so it carries no width constraint of its own — the stack
// view's fillEqually distribution sets the width. Bold 11pt white
// text, 6pt horizontal padding per side, 20pt tall, fully rounded.
// The label shrinks to fit (down to 60%) instead of truncating, so
// the full value is always visible; the text is centered in the
// pill. Green (#07C160) for the wxid pill, blue (#007AFF) for the
// custom WeChat ID pill; the color is the only difference.
static UIView *WQMVFolderTagViewWithTextAndColor(NSString *text, UIColor *backgroundColor)
{
    UIView *tag = [[UIView alloc] init];
    tag.backgroundColor = backgroundColor;
    tag.layer.cornerRadius = 10;
    tag.layer.masksToBounds = YES;
    tag.translatesAutoresizingMaskIntoConstraints = NO;
    [tag.heightAnchor constraintEqualToConstant:20].active = YES;
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont boldSystemFontOfSize:11];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.6;
    label.lineBreakMode = NSLineBreakByClipping;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [tag addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:tag.leadingAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:tag.trailingAnchor constant:-6],
        [label.topAnchor constraintEqualToAnchor:tag.topAnchor],
        [label.bottomAnchor constraintEqualToAnchor:tag.bottomAnchor],
    ]];
    return tag;
}

// Invisible placeholder for the empty half of a tag row: keeps the
// other pill in its fixed half instead of expanding into the space.
static UIView *WQMVFolderTagSpacer(void)
{
    UIView *spacer = [UIView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer.heightAnchor constraintEqualToConstant:20].active = YES;
    return spacer;
}

// Small green rounded pill reading 官方, for the official WeChat rows.
static UIView *WQMVGreenTagView(void)
{
    return WQMVGreenTagViewWithText(@"官方");
}

// Accessory view for official rows: green 官方 pill + chevron. Nil for
// other rows (callers use the plain disclosure accessory instead).
static UIView *_Nullable WQMVTagAccessoryView(BOOL showTag)
{
    if (!showTag) return nil;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 6;
    stack.alignment = UIStackViewAlignmentCenter;
    [stack addArrangedSubview:WQMVGreenTagView()];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [chevron.widthAnchor constraintEqualToConstant:10].active = YES;
    [chevron.heightAnchor constraintEqualToConstant:16].active = YES;
    [stack addArrangedSubview:chevron];
    CGSize size = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    stack.frame = CGRectMake(0, 0, size.width, size.height);
    return stack;
}

// Progress of a container scan, reported to the visible picker (if any).
// Set by the picker while a scan runs; cleared when it finishes. Only
// ever read on the main thread.
static void (^gScanProgressHandler)(double fraction, BOOL finished) = nil;

static void WQMVReportScanProgress(double fraction, BOOL finished)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gScanProgressHandler) gScanProgressHandler(fraction, finished);
    });
}

static UIViewController *_Nullable WQMVTopViewController(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            UIViewController *top = window.rootViewController;
            while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
                top = top.presentedViewController;
            }
            return top;
        }
    }
    return nil;
}

static NSString *WQMVScanDurationText(double seconds)
{
    if (seconds < 90) return @"大约 1 分钟";
    if (seconds < 3600) return [NSString stringWithFormat:@"大约 %.0f 分钟", ceil(seconds / 60.0)];
    return [NSString stringWithFormat:@"大约 %.1f 小时", seconds / 3600.0];
}

// Called on a scan thread: asks on the main thread and waits for the answer.
// Only reached when the app folders can't be listed from the LaunchServices
// database and a full scan is the only way left.
static BOOL WQMVConfirmFullScan(NSString *what, int64_t ids, double seconds)
{
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL start = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = WQMVTopViewController();
        if (!top) {
            dispatch_semaphore_signal(answered);
            return;
        }
        NSString *whatText = [what containsString:@"Internal"] ? @"内部守护进程文件夹" : @"应用文件夹";
        NSString *count = [NSNumberFormatter localizedStringFromNumber:@(ids)
                                                           numberStyle:NSNumberFormatterDecimalStyle];
        NSString *message = [NSString stringWithFormat:@"要列出%@，需要检查这台设备上的全部文件一次：%@ 个文件，%@。\n\n只需要第一次这样做；之后只检查新文件，很快。\n\n扫描时请保持本应用打开。",
                             whatText, count, WQMVScanDurationText(seconds)];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描全部文件？"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"以后再说" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            dispatch_semaphore_signal(answered);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"开始扫描" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            start = YES;
            dispatch_semaphore_signal(answered);
        }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
    (void)dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    return start;
}

static void WQMVFullScanProgress(int64_t done, int64_t total, BOOL finished)
{
    if (finished) {
        WQMVReportScanProgress(1.0, YES);
        return;
    }
    if (total <= 0) return;
    WQMVReportScanProgress((double)done / (double)total, NO);
}

#pragma mark - App info

@interface WQMVApp : NSObject
@property (nonatomic, copy) NSString *containerPath; // normalized; for the temp folder / a backup stamp, the folder path itself; empty for a remote device
@property (nonatomic, copy) NSString *bundleID; // empty for the temp folder, backup stamps and remote devices
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic) BOOL isTempFolder;
@property (nonatomic) BOOL isBackupStamp; // a 备份 <timestamp> folder under 被覆盖的聊天记录, used as a restore source
@property (nonatomic) BOOL isRemoteDevice; // a nearby device picked as the move target; never a local path
@property (nonatomic, strong, nullable) WQMVTransferPeer *remotePeer; // set only when isRemoteDevice
@property (nonatomic, readonly) NSString *documentsPath; // container Documents, or the temp/stamp folder itself; empty for a remote device (never use as a path)
@property (nonatomic, readonly) NSString *title;
+ (instancetype)tempFolderAppWithPath:(NSString *)path;
+ (instancetype)backupStampAppWithPath:(NSString *)path;
+ (instancetype)remoteDeviceAppWithPeer:(WQMVTransferPeer *)peer;
@end

@implementation WQMVApp

+ (instancetype)tempFolderAppWithPath:(NSString *)path
{
    WQMVApp *app = [WQMVApp new];
    app.containerPath = path;
    app.bundleID = @"";
    app.displayName = @"聊天记录";
    app.isTempFolder = YES;
    return app;
}

+ (instancetype)backupStampAppWithPath:(NSString *)path
{
    WQMVApp *app = [WQMVApp new];
    app.containerPath = path;
    app.bundleID = @"";
    app.displayName = [path lastPathComponent];
    app.isBackupStamp = YES;
    return app;
}

+ (instancetype)remoteDeviceAppWithPeer:(WQMVTransferPeer *)peer
{
    WQMVApp *app = [WQMVApp new];
    app.containerPath = @"";
    app.bundleID = @"";
    app.displayName = peer.name;
    app.isRemoteDevice = YES;
    app.remotePeer = peer;
    return app;
}

- (NSString *)documentsPath
{
    if (self.isRemoteDevice) return @"";
    if (self.isTempFolder || self.isBackupStamp) return self.containerPath;
    return [self.containerPath stringByAppendingPathComponent:@"Documents"];
}

- (NSString *)title
{
    return self.displayName.length ? self.displayName : self.bundleID;
}

@end

typedef void (^WQMVAppPickedBlock)(WQMVApp *app);
typedef void (^WQMVDoneBlock)(NSArray<NSString *> *names);

#pragma mark - Container resolution (all blocking: call off the main thread)

@interface WQMVResolver : NSObject
+ (NSArray<WQMVApp *> *)detectWeChatApps;
+ (NSArray<WQMVApp *> *)detectWeChatAppsInApps:(NSArray<WQMVApp *> *)apps;
+ (NSArray<WQMVApp *> *)pinnedAppsInApps:(NSArray<WQMVApp *> *)apps detected:(NSArray<WQMVApp *> *)detected;
+ (NSArray<WQMVApp *> *)resolveBundleID:(NSString *)bundleID;
+ (NSArray<WQMVApp *> *)allApps;
@end

@implementation WQMVResolver

+ (NSArray<NSString *> *)appContainerPaths
{
    // The shared scan lists the app folders, preferably from the
    // LaunchServices database (seconds); it also finds and remembers the
    // database location, which is what makes display names work.
    NSArray<NSString *> *paths = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil,
                                              ^(int64_t done, int64_t total, NSUInteger __unused found) {
        if (total > 0) WQMVReportScanProgress((double)done / (double)total, NO);
    });
    if (!paths.count) {
        NSArray<NSString *> *fromStore = wq_ls_container_paths(nil);
        NSMutableArray<NSString *> *filtered = [NSMutableArray array];
        for (NSString *path in fromStore) {
            NSString *norm = WQMVNormalizedContainerPath(path);
            if ([norm hasPrefix:@"/private/var/mobile/Containers/Data/Application/"]) [filtered addObject:norm];
        }
        paths = filtered;
    }
    NSMutableArray<NSString *> *unique = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *path in paths) {
        NSString *norm = WQMVNormalizedContainerPath(path);
        if ([seen containsObject:norm]) continue;
        [seen addObject:norm];
        [unique addObject:norm];
    }
    return [unique sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<WQMVApp *> *)allApps
{
    NSArray<NSString *> *paths = [self appContainerPaths];
    wq_load_display_names();
    NSMutableArray<WQMVApp *> *apps = [NSMutableArray array];
    for (NSString *path in paths) {
        NSString *bundleID = wq_bundle_id_for_container(path);
        if (!bundleID.length) bundleID = wq_container_label(path);
        if (!bundleID.length) continue;
        if (WQMVIsSelfApp(bundleID)) continue; // never list ourselves; allApps feeds every picker path
        WQMVApp *app = [WQMVApp new];
        app.containerPath = path;
        app.bundleID = bundleID;
        app.displayName = wq_display_name(bundleID);
        if (bundleID.length) (void)wq_app_icon(bundleID); // warm the icon off the main thread
        [apps addObject:app];
    }
    return apps;
}

+ (NSArray<WQMVApp *> *)detectWeChatAppsInApps:(NSArray<WQMVApp *> *)apps
{
    NSMutableArray<WQMVApp *> *found = [NSMutableArray array];
    for (WQMVApp *app in apps) {
        // Exclusion first: checked before every match rule below.
        if (WQMVIsExcludedFromAutoDetect(app.bundleID)) continue;
        if (WQMVIsEnterpriseWeChat(app.bundleID, app.displayName)) continue;
        // 微信 or "wechat" (either language): an English-locale WeChat
        // displays as "WeChat", which contains no 微信, so the
        // Chinese-name check alone left it off the auto-list.
        BOOL chineseName = app.displayName.length && [app.displayName containsString:@"微信"];
        BOOL englishName = [app.title rangeOfString:@"wechat" options:NSCaseInsensitiveSearch].location != NSNotFound;
        BOOL englishID = [app.bundleID rangeOfString:@"wechat" options:NSCaseInsensitiveSearch].location != NSNotFound;
        // Any com.tencent.* app, unless excluded above: clones and
        // future Tencent apps (e.g. com.tencent.qy.xin) list too.
        // This is not a whitelist: only the exclusion list keeps an
        // app off the auto-list.
        BOOL tencentPrefix = [app.bundleID hasPrefix:@"com.tencent."];
        if (chineseName || englishName || englishID || tencentPrefix) [found addObject:app];
    }
    [found sortUsingComparator:^NSComparisonResult(WQMVApp *a, WQMVApp *b) {
        NSComparisonResult byName = [a.title compare:b.title];
        if (byName != NSOrderedSame) return byName;
        NSComparisonResult byID = [a.bundleID compare:b.bundleID];
        if (byID != NSOrderedSame) return byID;
        return [a.containerPath compare:b.containerPath];
    }];
    return found;
}

+ (NSArray<WQMVApp *> *)detectWeChatApps
{
    return [self detectWeChatAppsInApps:[self allApps]];
}

// Pinned apps (long-press 添加到首页 in 全部 App), in pin order,
// resolved against the given snapshot: a pin shows only while its
// app is still installed, and never duplicates an auto-detected
// row (a pinned app that is also auto-detected shows once, in the
// auto-detected section).
+ (NSArray<WQMVApp *> *)pinnedAppsInApps:(NSArray<WQMVApp *> *)apps detected:(NSArray<WQMVApp *> *)detected
{
    NSMutableSet<NSString *> *shownPaths = [NSMutableSet set];
    for (WQMVApp *app in detected) {
        if (app.containerPath.length) [shownPaths addObject:app.containerPath];
    }
    NSMutableArray<WQMVApp *> *pinned = [NSMutableArray array];
    for (NSString *bundleID in WQMVPinnedBundleIDs()) {
        for (WQMVApp *app in apps) {
            if (![app.bundleID isEqualToString:bundleID]) continue;
            if ([shownPaths containsObject:app.containerPath]) continue;
            [pinned addObject:app];
            [shownPaths addObject:app.containerPath];
            break;
        }
    }
    return pinned;
}

+ (NSArray<WQMVApp *> *)resolveBundleID:(NSString *)bundleID
{
    NSString *trimmed = [bundleID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return @[];
    NSMutableArray<WQMVApp *> *found = [NSMutableArray array];
    for (WQMVApp *app in [self allApps]) {
        if ([app.bundleID isEqualToString:trimmed]) [found addObject:app];
    }
    return found;
}

@end

#pragma mark - Temp folder (hosted in the Files app container)

static void WQMVPersistTempFolderPath(NSString *candidate)
{
    [NSUserDefaults.standardUserDefaults setObject:candidate forKey:kWQMVTempFolderPathKey];
}

// Blocking: call off the main thread. Resolves the 聊天记录 temp folder
// path inside the Files app container, creating the folder on first use.
// Returns nil + error text when the Files container can't be resolved
// or the folder can't be created. (a) A stored path that still stats
// as a directory wins. (b) Otherwise, if the freshly resolved Files
// container already has the folder, adopt it. (c) Otherwise create it
// there. There is no fallback to another host or location.
static NSString *_Nullable WQMVResolveTempFolderPath(NSString **errorText)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    struct stat st;
    NSString *stored = [defaults stringForKey:kWQMVTempFolderPathKey];
    if (stored.length && wq_stat(stored, &st) && S_ISDIR(st.st_mode)) return stored;

    // Resolve the Files container by bundle ID, same iteration as elsewhere.
    NSArray<WQMVApp *> *found = [WQMVResolver resolveBundleID:WQMVTempHostBundleID()];
    WQMVApp *host = found.firstObject;
    if (!host) {
        if (errorText) *errorText = @"找不到文件应用（com.apple.DocumentsApp）的容器。";
        return nil;
    }
    NSString *candidate = [host.containerPath stringByAppendingPathComponent:WQMVTempFolderName()];
    // (b) Adopt an existing folder.
    if (wq_stat(candidate, &st) && S_ISDIR(st.st_mode)) {
        WQMVPersistTempFolderPath(candidate);
        return candidate;
    }
    // (c) Create it in the Files container.
    NSString *error = nil;
    if (wq_create_dir(candidate, &error)) {
        WQMVPersistTempFolderPath(candidate);
        return candidate;
    }
    // Tolerate a race: re-check in case the folder appeared meanwhile.
    if (wq_stat(candidate, &st) && S_ISDIR(st.st_mode)) {
        WQMVPersistTempFolderPath(candidate);
        return candidate;
    }
    if (errorText) {
        *errorText = [NSString stringWithFormat:@"文件应用（com.apple.DocumentsApp）容器里建不了聊天记录文件夹：%@",
                      error.length ? error : @"未知错误"];
    }
    return nil;
}

// The backup root for displaced folders: 被覆盖的聊天记录 at the ROOT of
// the Files app's data container, next to the 聊天记录 temp folder. Same
// host, same reason: the Files container survives uninstalling this app,
// so a displaced folder is never lost with the app. Resolved the same
// way as the temp folder (freshly, on each move batch); no fallback to
// another host or location. Returns nil + error text when the Files
// container can't be resolved or the folder can't be created.
static NSString *WQMVBackupRootFolderName(void)
{
    return @"被覆盖的聊天记录";
}

static NSString *_Nullable WQMVResolveBackupRootPath(NSString **errorText)
{
    struct stat st;
    NSArray<WQMVApp *> *found = [WQMVResolver resolveBundleID:WQMVTempHostBundleID()];
    WQMVApp *host = found.firstObject;
    if (!host) {
        if (errorText) *errorText = @"找不到文件应用（com.apple.DocumentsApp）的容器。";
        return nil;
    }
    NSString *candidate = [host.containerPath stringByAppendingPathComponent:WQMVBackupRootFolderName()];
    if (wq_stat(candidate, &st) && S_ISDIR(st.st_mode)) return candidate;
    NSString *error = nil;
    if (wq_create_dir(candidate, &error)) return candidate;
    // Tolerate a race: re-check in case the folder appeared meanwhile.
    if (wq_stat(candidate, &st) && S_ISDIR(st.st_mode)) return candidate;
    if (errorText) {
        *errorText = [NSString stringWithFormat:@"文件应用（com.apple.DocumentsApp）容器里建不了被覆盖的聊天记录文件夹：%@",
                      error.length ? error : @"未知错误"];
    }
    return nil;
}

// Browsing-only sibling of the resolver above: returns the backup
// root path WITHOUT creating the folder (a missing root is an empty
// stamp list, never an error, and browsing must not create the root —
// only displacement creates it). Nil + error text only when the Files
// container itself can't be resolved. Blocking: call off the main
// thread.
static NSString *_Nullable WQMVResolveBackupRootPathForBrowsing(NSString **errorText)
{
    NSArray<WQMVApp *> *found = [WQMVResolver resolveBundleID:WQMVTempHostBundleID()];
    WQMVApp *host = found.firstObject;
    if (!host) {
        if (errorText) *errorText = @"找不到文件应用（com.apple.DocumentsApp）的容器。";
        return nil;
    }
    return [host.containerPath stringByAppendingPathComponent:WQMVBackupRootFolderName()];
}

// The staging parent for incoming transfers: .receiving at the ROOT of
// the Files app's data container, next to 聊天记录 and 被覆盖的聊天记录
// (never inside the install destination, so partially received folders
// are never listed as a source). Each transfer gets one child folder
// inside it. Created on first receive only; browsing never creates it.
static NSString *WQMVReceivingFolderName(void)
{
    return @".receiving";
}

// Timestamped folder name for one displacement, from the device's local
// time at displacement, precise to the second: 备份 MM.dd日HH.mm.ss.
// Second precision means two displacements essentially never share a
// name; a folder with the same name (same second) is reused.
static NSString *WQMVBackupTimestampFolderName(void)
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"备份 MM.dd日HH.mm.ss";
    return [formatter stringFromDate:[NSDate date]];
}

// If a backup stamp folder is empty, remove it. Called after a move out
// of a stamp folder, and proactively when the stamp list loads. Only
// ever a 备份 <timestamp> folder directly under 被覆盖的聊天记录 — never
// the root itself, never anything else. Any remaining entry, hidden
// files included, keeps the folder. wq_delete refuses non-empty folders
// (rmdir), so it is a second guard. Returns YES only when the folder
// was actually removed. Failures are silent: a leftover empty folder is
// harmless. Blocking: call off the main thread.
static BOOL WQMVDeleteStampFolderIfEmpty(NSString *stampPath)
{
    if (![stampPath.lastPathComponent hasPrefix:@"备份"]) return NO;
    if (![stampPath.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:WQMVBackupRootFolderName()]) return NO;
    NSString *listError = nil;
    NSArray<NSString *> *items = wq_list(stampPath, &listError);
    if (!items) return NO;
    for (NSString *item in items) {
        if ([item isEqualToString:@"."] || [item isEqualToString:@".."]) continue;
        return NO;
    }
    NSString *deleteError = nil;
    return wq_delete(stampPath, &deleteError);
}

#pragma mark - Folder identity (which WeChat account owns a folder)
//
// A 32-hex folder name under a WeChat Documents directory is the MD5 of
// the account's UsrName (wxid_xxx, a QQ number, or a phone-based ID).
// MD5 is one-way, so the folder name alone can never be reversed into
// the account. Identification instead reads OTHER files the escape can
// reach and matches them back to the folder by MD5:
//
//   (a) <folder>/mmsettingext.archive (current WeChat; the older
//       mmsetting.archive is still checked for older/moved folders):
//       the account's own settings file (binary NSKeyedArchiver
//       plist). The account dict holds UsrName (wxid), NickName, and
//       AliasName — the custom WeChat ID, which the Friend table does
//       not hold for the self account. Only those three keys are read;
//       the archive's other personal data (phone, city, signature) is
//       never touched.
//   (b) Documents/LoginInfo2.dat (and LoginInfo.dat): per-account
//       records holding the account ID (wxid, record field 1), the
//       custom WeChat ID (record field 13: present when the account
//       has one, empty when not), phone, and name. The file is an
//       outer protobuf message whose field 1 holds length-prefixed
//       records, parsed by field number with bounds-checked decoding.
//       Field 2 is ambiguous (custom ID when set, else phone) and is
//       never read as the ID. A property-list attempt runs first for
//       older layouts; only when no protobuf records parse does the
//       custom ID fall back to the strict positional rule (same as
//       source (e): valid field header, immediately next field only,
//       ID shape, no `gh_` ids), voted across all occurrences.
//   (c) <folder>/DB/WCDB_Contact.sqlite, Friend table: userName in plain
//       text plus dbContactRemark protobuf (Remark: 1 nickname, 2 wechat,
//       3 alias) — the layout jiegec/wechat-dump reads.
//   (d) <folder>/DB/MM.sqlite, Friend then friend_meta tables, for older
//       layouts, via the same generic column scan.
//   (e) <folder>/session/lsm_data/level_* files: the session key-value
//       store holds a protobuf-like record with the self account's
//       custom WeChat ID in the field immediately after the account-ID
//       field. Anchored by the known account ID or by MD5-verified ID
//       tokens; the anchor must carry a valid wire-type-2 field header
//       and the candidate must be the immediately next field, ID-shaped,
//       not a `gh_` id, and seen next to only one distinct anchor.
//       Nickname is never taken from this source. Only the
//       anchor-adjacent ID field is read; nothing else is used.
//
// All five sources are always consulted and their fields merged
// (first-non-empty per field, in the order above), except the custom
// ID: when LoginInfo holds the account's record but yields no custom
// ID, the account has none, and custom IDs from the other sources are
// suppressed. Only when LoginInfo has no record for the account at
// all may the other sources supply the custom ID.
//
// Hard limits: identity fields only. Message tables (Chat_*), message
// databases, and Img/Video/Audio are never opened. Nothing is written
// into a WeChat container. A database is copied with wq_read into this
// app's own tmp dir and the COPY is opened read-only (immutable=1);
// the live file is never opened in place. Every parse is defensive and
// a failure for one folder never affects the list or other folders.
// All of this runs off the main thread; rows show the hash first and
// update in place when an identity resolves.
//
// Current WeChat's mmsettingext.archive holds none of the
// UsrName/NickName/AliasName keys, so source (a) mainly helps older
// or moved-in folders. The lsm_data source is the fallback for
// folders whose account never logged in on this device or was moved
// in from elsewhere. Every step below degrades to showing the folder
// hash when its source is absent or unreadable.

// MD5 (RFC 1321), vendored: CommonCrypto's CC_MD5 is deprecated and the
// build treats warnings as errors. The K constants are computed from
// sin() at first use instead of being transcribed from the table, and
// the result is checked against md5sum test vectors before shipping.
// The lazy table init is idempotent, so a benign race only recomputes
// identical values.
static void WQMVMD5Digest(const uint8_t *input, size_t length, uint8_t digest[16])
{
    static const uint32_t shifts[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    };
    static uint32_t kTable[64];
    static int kTableReady = 0;
    if (!kTableReady) {
        for (int i = 0; i < 64; i++) {
            kTable[i] = (uint32_t)(fabs(sin((double)(i + 1))) * 4294967296.0);
        }
        kTableReady = 1;
    }
    uint32_t a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
    size_t paddedLength = length + 1;
    while ((paddedLength % 64) != 56) paddedLength++;
    paddedLength += 8;
    uint8_t *message = (uint8_t *)calloc(paddedLength, 1);
    if (!message) {
        memset(digest, 0, 16);
        return;
    }
    memcpy(message, input, length);
    message[length] = 0x80;
    uint64_t bitLength = (uint64_t)length * 8;
    for (int i = 0; i < 8; i++) {
        message[paddedLength - 8 + (size_t)i] = (uint8_t)(bitLength >> (8 * i));
    }
    for (size_t offset = 0; offset < paddedLength; offset += 64) {
        uint32_t block[16];
        for (int i = 0; i < 16; i++) {
            size_t at = offset + (size_t)(i * 4);
            block[i] = (uint32_t)message[at] | ((uint32_t)message[at + 1] << 8) |
                       ((uint32_t)message[at + 2] << 16) | ((uint32_t)message[at + 3] << 24);
        }
        uint32_t a = a0, b = b0, c = c0, d = d0;
        for (int i = 0; i < 64; i++) {
            uint32_t f;
            int g;
            if (i < 16) {
                f = (b & c) | (~b & d);
                g = i;
            } else if (i < 32) {
                f = (d & b) | (~d & c);
                g = (5 * i + 1) % 16;
            } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
            } else {
                f = c ^ (b | ~d);
                g = (7 * i) % 16;
            }
            f = f + a + kTable[i] + block[g];
            a = d;
            d = c;
            c = b;
            b = b + ((f << shifts[i]) | (f >> (32 - shifts[i])));
        }
        a0 += a;
        b0 += b;
        c0 += c;
        d0 += d;
    }
    free(message);
    uint32_t parts[4] = {a0, b0, c0, d0};
    for (int i = 0; i < 4; i++) {
        digest[i * 4] = (uint8_t)(parts[i] & 0xff);
        digest[i * 4 + 1] = (uint8_t)((parts[i] >> 8) & 0xff);
        digest[i * 4 + 2] = (uint8_t)((parts[i] >> 16) & 0xff);
        digest[i * 4 + 3] = (uint8_t)((parts[i] >> 24) & 0xff);
    }
}

// Lowercase hex MD5 of a string's UTF-8 bytes. Nil when the string has
// no UTF-8 representation.
static NSString *_Nullable WQMVMD5HexOfString(NSString *string)
{
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    uint8_t digest[16];
    WQMVMD5Digest((const uint8_t *)data.bytes, data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

@interface WQMVFolderIdentity : NSObject
@property (nonatomic, copy, nullable) NSString *nickname;
@property (nonatomic, copy, nullable) NSString *wechatID; // Remark field 2 / custom WeChat ID
@property (nonatomic, copy, nullable) NSString *alias;    // Remark field 3
@property (nonatomic, copy, nullable) NSString *wxid;     // UsrName / id_persion
@property (nonatomic, copy, nullable) NSString *phone;
- (NSString *_Nullable)wxidTagText; // labeled left tag (green): wxid：, nil when no wxid
- (NSString *_Nullable)wechatIDTagText; // labeled right tag (blue): 微信号：, nil when no custom ID
- (BOOL)hasDisplayableIdentity; // any tag the row shows (wxid or custom ID)
- (void)mergeMissingFieldsFromIdentity:(WQMVFolderIdentity *)other;
@end

@implementation WQMVFolderIdentity

// Two tags in one horizontal row under the folder hash: the green
// wxid tag on the left, the blue custom WeChat ID tag on the right.
// Each tag appears only when its value exists — no placeholder, no
// fallback to nickname/alias inside the tags. Values always carry
// their type label, never bare. Nickname/alias are parsed but never
// displayed.
- (NSString *_Nullable)wxidTagText
{
    if (self.wxid.length) return [@"wxid：" stringByAppendingString:self.wxid];
    return nil;
}

- (NSString *_Nullable)wechatIDTagText
{
    if (self.wechatID.length) return [@"微信号：" stringByAppendingString:self.wechatID];
    return nil;
}

- (BOOL)hasDisplayableIdentity
{
    return self.wxid.length || self.wechatID.length;
}

// Union helper for the merge: fills only fields this identity lacks,
// so the first source in merge order (mmsetting -> LoginInfo ->
// WCDB_Contact -> MM.sqlite -> lsm_data) wins per field.
- (void)mergeMissingFieldsFromIdentity:(WQMVFolderIdentity *)other
{
    if (!other) return;
    if (!self.nickname.length) self.nickname = other.nickname;
    if (!self.wechatID.length) self.wechatID = other.wechatID;
    if (!self.alias.length) self.alias = other.alias;
    if (!self.wxid.length) self.wxid = other.wxid;
    if (!self.phone.length) self.phone = other.phone;
}

@end

// Minimal protobuf wire parser: extracts the length-delimited string
// fields 1 (nickname), 2 (wechat), 3 (alias) from a Remark message.
// Unknown fields are skipped; malformed input stops parsing and keeps
// whatever was found. Mirrors jiegec/wechat-dump's Remark proto.
static void WQMVParseRemarkProto(NSData *data, NSString **outNickname,
                                 NSString **outWechat, NSString **outAlias)
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSUInteger pos = 0;
    while (pos < length) {
        uint64_t key = 0;
        int shift = 0;
        BOOL keyOK = NO;
        while (pos < length) {
            if (shift >= 64) return;
            uint8_t b = bytes[pos++];
            key |= (uint64_t)(b & 0x7f) << shift;
            if (!(b & 0x80)) {
                keyOK = YES;
                break;
            }
            shift += 7;
        }
        if (!keyOK) return;
        uint64_t field = key >> 3;
        uint64_t wire = key & 7;
        if (wire == 2) {
            uint64_t count = 0;
            shift = 0;
            BOOL countOK = NO;
            while (pos < length) {
                if (shift >= 64) return;
                uint8_t b = bytes[pos++];
                count |= (uint64_t)(b & 0x7f) << shift;
                if (!(b & 0x80)) {
                    countOK = YES;
                    break;
                }
                shift += 7;
            }
            if (!countOK || count > (uint64_t)(length - pos)) return;
            if (field == 1 || field == 2 || field == 3) {
                NSString *value = [[NSString alloc] initWithBytes:bytes + pos
                                                           length:(NSUInteger)count
                                                         encoding:NSUTF8StringEncoding];
                if (value.length) {
                    if (field == 1 && outNickname) *outNickname = value;
                    else if (field == 2 && outWechat) *outWechat = value;
                    else if (field == 3 && outAlias) *outAlias = value;
                }
            }
            pos += (NSUInteger)count;
        } else if (wire == 0) {
            while (pos < length) {
                if (!(bytes[pos++] & 0x80)) break;
            }
        } else if (wire == 1) {
            if (length - pos < 8) return;
            pos += 8;
        } else if (wire == 5) {
            if (length - pos < 4) return;
            pos += 4;
        } else {
            return;
        }
    }
}

@interface WQMVLoginCandidate : NSObject
@property (nonatomic, copy) NSString *accountID;
@property (nonatomic, copy, nullable) NSString *phone;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy, nullable) NSString *wechatID; // custom WeChat ID: record field 13 of the LoginInfo record for this account
@end

@implementation WQMVLoginCandidate
@end

static void WQMVCollectPlistStrings(id object, NSMutableArray<NSString *> *out)
{
    if ([object isKindOfClass:[NSString class]]) {
        [out addObject:object];
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) WQMVCollectPlistStrings(value, out);
    } else if ([object isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)object allValues]) WQMVCollectPlistStrings(value, out);
    }
}

static void WQMVCollectKeyedAccounts(id object, NSMutableArray<WQMVLoginCandidate *> *out)
{
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        NSString *accountID = nil;
        NSString *phone = nil;
        NSString *name = nil;
        for (id key in dict) {
            if (![key isKindOfClass:[NSString class]]) continue;
            id value = dict[key];
            if (![value isKindOfClass:[NSString class]]) continue;
            NSString *lower = [(NSString *)key lowercaseString];
            if ([lower containsString:@"id_persion"] || [lower containsString:@"idpersion"] ||
                [lower isEqualToString:@"wxid"] || [lower isEqualToString:@"username"] ||
                [lower isEqualToString:@"usrname"]) {
                accountID = value;
            } else if ([lower containsString:@"phone"] || [lower containsString:@"mobile"]) {
                phone = value;
            } else if ([lower isEqualToString:@"name"] || [lower containsString:@"nickname"]) {
                name = value;
            }
        }
        if (accountID.length) {
            WQMVLoginCandidate *candidate = [WQMVLoginCandidate new];
            candidate.accountID = accountID;
            candidate.phone = phone;
            candidate.name = name;
            [out addObject:candidate];
        }
        for (id value in [dict allValues]) WQMVCollectKeyedAccounts(value, out);
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) WQMVCollectKeyedAccounts(value, out);
    }
}

// Strict protobuf helpers shared with the session/lsm_data source,
// defined below with that source. The LSM extractor uses the anchor /
// next-field rule through these helpers; the LoginInfo parse reads
// field 13 by field number from parsed records (see
// WQMVLoginInfoParseRecords) and keeps the positional vote only as
// the zero-records fallback, so the two paths cannot diverge in
// strictness at vote time.
static BOOL WQMVLSMAnchorHasValidFieldHeader(const uint8_t *bytes, NSUInteger anchorPos, NSUInteger anchorLength);
static NSString *_Nullable WQMVLSMNextFieldString(const uint8_t *bytes, NSUInteger length, NSUInteger startPos, BOOL *parsedField);
static BOOL WQMVLSMIsCustomIDCandidate(NSString *value, NSString *anchor);
static BOOL WQMVIsUsableWechatID(NSString *value, NSString *anchor);
static NSString *_Nullable WQMVLSMMostFrequent(NSDictionary<NSString *, NSNumber *> *votes, NSArray<NSString *> *order);
static BOOL WQMVLSMReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *pos, uint64_t *out);

// Positional wechatID vote from one anchor occurrence in LoginInfo
// bytes — FALLBACK ONLY, used when the field-tag-aware record parse
// (WQMVLoginInfoParseRecords) yields zero records, i.e. the file
// layout was not understood. The anchor must carry a valid wire-type-2
// field header, and the candidate must be the IMMEDIATELY NEXT
// protobuf field, passing the same rejection rules as the LSM
// extractor (ID shape, not `gh_`, not the anchor, not containing the
// anchor, not all-hex, not all digits). Votes once per occurrence into
// the per-account tables. No window scan, no multi-field scan, no
// guessing.
static void WQMVLoginInfoVoteWechatID(NSData *data, NSUInteger anchorPos, NSUInteger anchorLength, NSString *anchor, NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *votesByAccount, NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *orderByAccount)
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    if (anchorPos + anchorLength > length) return;
    if (!WQMVLSMAnchorHasValidFieldHeader(bytes, anchorPos, anchorLength)) return;
    BOOL parsedField = NO;
    NSString *next = WQMVLSMNextFieldString(bytes, length, anchorPos + anchorLength, &parsedField);
    if (!next) return;
    if ([next hasPrefix:@"gh_"]) return;
    if (!WQMVLSMIsCustomIDCandidate(next, anchor)) return;
    NSMutableDictionary<NSString *, NSNumber *> *votes = votesByAccount[anchor];
    NSMutableArray<NSString *> *order = orderByAccount[anchor];
    if (!votes) {
        votes = [NSMutableDictionary dictionary];
        votesByAccount[anchor] = votes;
    }
    if (!order) {
        order = [NSMutableArray array];
        orderByAccount[anchor] = order;
    }
    NSNumber *existing = votes[next];
    if (!existing) {
        votes[next] = @1;
        [order addObject:next];
    } else {
        votes[next] = @(existing.unsignedIntegerValue + 1);
    }
}

// Reads ONE protobuf field starting at *pos within bytes[0..length).
// On success advances *pos past the field and fills the out params:
// *outField / *outWire are the field number and wire type; for wire
// type 2, *outValueStart/*outValueLength delimit the field's bytes.
// Returns NO on any malformed or truncated data (field number 0,
// unknown wire type, over-long varint, length past the bound) without
// over-reading. *pos is left undefined after NO — callers must abort
// the walk they were in.
static BOOL WQMVLoginInfoReadField(const uint8_t *bytes, NSUInteger length, NSUInteger *pos,
                                   uint64_t *outField, uint64_t *outWire,
                                   NSUInteger *outValueStart, NSUInteger *outValueLength)
{
    uint64_t key = 0;
    if (!WQMVLSMReadVarint(bytes, length, pos, &key)) return NO;
    uint64_t field = key >> 3;
    uint64_t wire = key & 7;
    if (field == 0) return NO;
    if (wire == 0) {
        uint64_t value = 0;
        if (!WQMVLSMReadVarint(bytes, length, pos, &value)) return NO;
        if (outValueStart) *outValueStart = *pos;
        if (outValueLength) *outValueLength = 0;
    } else if (wire == 2) {
        uint64_t count = 0;
        if (!WQMVLSMReadVarint(bytes, length, pos, &count)) return NO;
        if (count > (uint64_t)(length - *pos)) return NO;
        if (outValueStart) *outValueStart = *pos;
        if (outValueLength) *outValueLength = (NSUInteger)count;
        *pos += (NSUInteger)count;
    } else if (wire == 1) {
        if (length - *pos < 8) return NO;
        if (outValueStart) *outValueStart = *pos;
        if (outValueLength) *outValueLength = 8;
        *pos += 8;
    } else if (wire == 5) {
        if (length - *pos < 4) return NO;
        if (outValueStart) *outValueStart = *pos;
        if (outValueLength) *outValueLength = 4;
        *pos += 4;
    } else {
        return NO;
    }
    if (outField) *outField = field;
    if (outWire) *outWire = wire;
    return YES;
}

// Walks one length-prefixed LoginInfo record's fields in
// bytes[recordStart..recordEnd). Returns YES only when the walk
// consumes the record exactly with no malformed field. Captures
// field 1 (wxid) and field 13 (custom ID) as UTF-8 strings when
// present (first length-delimited occurrence wins; undecodable bytes
// count as absent). Field 2 is NEVER read: it holds the custom ID
// when set, else the phone — ambiguous by construction.
static BOOL WQMVLoginInfoParseRecord(const uint8_t *bytes, NSUInteger recordStart, NSUInteger recordEnd,
                                     NSString **outWxid, NSString **outAlias)
{
    NSString *wxid = nil;
    NSString *alias = nil;
    BOOL seenWxid = NO;
    BOOL seenAlias = NO;
    NSUInteger pos = recordStart;
    while (pos < recordEnd) {
        uint64_t field = 0;
        uint64_t wire = 0;
        NSUInteger valueStart = 0;
        NSUInteger valueLength = 0;
        if (!WQMVLoginInfoReadField(bytes, recordEnd, &pos, &field, &wire, &valueStart, &valueLength)) return NO;
        if (wire != 2) continue;
        if (field == 1 && !seenWxid) {
            seenWxid = YES;
            wxid = [[NSString alloc] initWithBytes:bytes + valueStart
                                            length:valueLength
                                          encoding:NSUTF8StringEncoding];
        } else if (field == 13 && !seenAlias) {
            seenAlias = YES;
            alias = [[NSString alloc] initWithBytes:bytes + valueStart
                                             length:valueLength
                                           encoding:NSUTF8StringEncoding];
        }
    }
    if (outWxid) *outWxid = wxid;
    if (outAlias) *outAlias = alias;
    return YES;
}

// Field-tag-aware parse of LoginInfo2.dat / LoginInfo.dat bytes.
// File layout: an outer protobuf message whose field 1 (wire type 2)
// holds a blob of length-prefixed records; each record is
// [varint byte-length][protobuf message bytes]. Record fields:
// 1 = wxid, 2 = custom ID if set else phone (AMBIGUOUS — never read),
// 3 = nickname, 4 = uin, 7 = phone, 11 = wxid again, 13 = custom ID
// when set, EMPTY when not. Field 13 is the unambiguous alias field:
// non-empty exactly when the account has a custom ID.
//
// For every cleanly parsed record, the record's field 1 is collected
// into recordAccountIDs (first-seen order), and one field-13 vote is
// cast into the per-account vote tables when field 13 is non-empty
// and passes the shared validator anchored on the record's field 1
// (same vote structure as the positional path: most frequent wins).
// Returns the number of cleanly parsed records; 0 means the layout
// was not understood and the caller must fall back to the positional
// vote. A malformed record is skipped via its length prefix; parsing
// never throws and never reads past a bound.
static NSUInteger WQMVLoginInfoParseRecords(NSData *data,
                                            NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *votesByAccount,
                                            NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *orderByAccount,
                                            NSMutableArray<NSString *> *recordAccountIDs)
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSUInteger parsedRecords = 0;
    NSMutableSet<NSString *> *seenAccounts = [NSMutableSet set];
    NSUInteger pos = 0;
    while (pos < length) {
        uint64_t field = 0;
        uint64_t wire = 0;
        NSUInteger valueStart = 0;
        NSUInteger valueLength = 0;
        if (!WQMVLoginInfoReadField(bytes, length, &pos, &field, &wire, &valueStart, &valueLength)) break;
        if (field != 1 || wire != 2) continue;
        NSUInteger blobStart = valueStart;
        NSUInteger blobEnd = valueStart + valueLength;
        NSUInteger recPos = blobStart;
        while (recPos < blobEnd && parsedRecords < 1024) {
            uint64_t recLength = 0;
            if (!WQMVLSMReadVarint(bytes, blobEnd, &recPos, &recLength)) break;
            if (recLength > (uint64_t)(blobEnd - recPos)) break;
            NSUInteger recStart = recPos;
            NSUInteger recEnd = recPos + (NSUInteger)recLength;
            recPos = recEnd;
            NSString *wxid = nil;
            NSString *alias = nil;
            if (!WQMVLoginInfoParseRecord(bytes, recStart, recEnd, &wxid, &alias)) continue;
            parsedRecords++;
            if (!wxid.length) continue;
            if (![seenAccounts containsObject:wxid]) {
                [seenAccounts addObject:wxid];
                [recordAccountIDs addObject:wxid];
            }
            if (!alias.length) continue;
            if ([alias hasPrefix:@"gh_"]) continue;
            if (!WQMVLSMIsCustomIDCandidate(alias, wxid)) continue;
            NSMutableDictionary<NSString *, NSNumber *> *votes = votesByAccount[wxid];
            NSMutableArray<NSString *> *order = orderByAccount[wxid];
            if (!votes) {
                votes = [NSMutableDictionary dictionary];
                votesByAccount[wxid] = votes;
            }
            if (!order) {
                order = [NSMutableArray array];
                orderByAccount[wxid] = order;
            }
            NSNumber *existing = votes[alias];
            if (!existing) {
                votes[alias] = @1;
                [order addObject:alias];
            } else {
                votes[alias] = @(existing.unsignedIntegerValue + 1);
            }
        }
    }
    return parsedRecords;
}

// Parses LoginInfo2.dat / LoginInfo.dat bytes into candidate account IDs.
// The format is undocumented: try a property list first (keyed accounts,
// plus every string value as a candidate — the MD5 match filters), then
// fall back to scanning the raw bytes for wxid_xxx / qq-number / digit
// runs (phone comes from the 256-byte window after the first
// occurrence). The custom WeChat ID comes from a field-tag-aware parse of
// the protobuf records: field 13 of the record whose field 1 is the
// account ID (field 13 holds the custom ID when set and is empty when
// not; field 2 is ambiguous — custom ID or phone — and is never read).
// Votes across all parsed records decide, most frequent wins. Only when
// the record parse yields ZERO records (malformed/unexpected layout)
// does the positional vote (immediately next field after the anchor)
// apply. Never throws; an unparseable file yields no candidates.
static NSArray<WQMVLoginCandidate *> *WQMVScanLoginInfoData(NSData *data)
{
    NSMutableArray<WQMVLoginCandidate *> *candidates = [NSMutableArray array];
    @try {
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:NULL
                                                               error:NULL];
        if (plist) {
            WQMVCollectKeyedAccounts(plist, candidates);
            NSMutableArray<NSString *> *strings = [NSMutableArray array];
            WQMVCollectPlistStrings(plist, strings);
            for (NSString *string in strings) {
                if (string.length < 4 || string.length > 64) continue;
                WQMVLoginCandidate *candidate = [WQMVLoginCandidate new];
                candidate.accountID = string;
                [candidates addObject:candidate];
            }
            if (candidates.count) return candidates;
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    NSString *latin = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!latin) return candidates;
    NSRegularExpression *idPattern = [NSRegularExpression regularExpressionWithPattern:@"wxid_[A-Za-z0-9_]+|qq[0-9]{5,15}|[0-9]{5,15}"
                                                                               options:0
                                                                                 error:NULL];
    NSRegularExpression *phonePattern = [NSRegularExpression regularExpressionWithPattern:@"1[3-9][0-9]{9}"
                                                                                  options:0
                                                                                    error:NULL];
    if (!idPattern || !phonePattern) return candidates;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableDictionary<NSString *, WQMVLoginCandidate *> *candidateByID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *idVotesByAccount = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *idOrderByAccount = [NSMutableDictionary dictionary];
    // Field-tag-aware record parse first: fills the vote tables with
    // field-13 values and collects the record account IDs. When it
    // yields no records, the positional vote in the loop below
    // applies instead — and only then.
    NSMutableArray<NSString *> *recordAccountIDs = [NSMutableArray array];
    NSUInteger parsedRecords = WQMVLoginInfoParseRecords(data, idVotesByAccount, idOrderByAccount, recordAccountIDs);
    NSArray<NSTextCheckingResult *> *matches = [idPattern matchesInString:latin
                                                                  options:0
                                                                    range:NSMakeRange(0, latin.length)];
    // Latin-1 decoding is byte-preserving, so a match's character range
    // is its byte range in `data` — the strict parse below reads raw
    // bytes at those offsets. Occurrence processing is capped as a
    // safety valve; a real LoginInfo file holds a handful of accounts.
    NSUInteger processedMatches = 0;
    for (NSTextCheckingResult *match in matches) {
        if (candidates.count >= 200) break;
        if (++processedMatches > 4096) break;
        NSString *accountID = [latin substringWithRange:match.range];
        if (![seen containsObject:accountID]) {
            [seen addObject:accountID];
            WQMVLoginCandidate *candidate = [WQMVLoginCandidate new];
            candidate.accountID = accountID;
            NSUInteger windowStart = NSMaxRange(match.range);
            NSUInteger windowLength = MIN((NSUInteger)256, latin.length - windowStart);
            NSTextCheckingResult *phoneMatch = [phonePattern firstMatchInString:latin
                                                                        options:0
                                                                          range:NSMakeRange(windowStart, windowLength)];
            if (phoneMatch) candidate.phone = [latin substringWithRange:phoneMatch.range];
            [candidates addObject:candidate];
            candidateByID[accountID] = candidate;
        }
        // Positional vote ONLY as the fallback when no protobuf
        // records parsed: with parsed records, field-13 votes decide
        // and the next-field guess must not contribute.
        if (parsedRecords == 0) {
            WQMVLoginInfoVoteWechatID(data, match.range.location, match.range.length, accountID, idVotesByAccount, idOrderByAccount);
        }
    }
    // Records are authoritative for account presence: ensure every
    // parsed record's account has a candidate (the regex scan finds
    // the same wxid strings in practice; this covers account IDs the
    // patterns miss, so "LoginInfo decides" sees the record).
    if (parsedRecords > 0) {
        for (NSString *accountID in recordAccountIDs) {
            if (candidates.count >= 200) break;
            if ([seen containsObject:accountID]) continue;
            [seen addObject:accountID];
            WQMVLoginCandidate *candidate = [WQMVLoginCandidate new];
            candidate.accountID = accountID;
            [candidates addObject:candidate];
            candidateByID[accountID] = candidate;
        }
    }
    for (NSString *accountID in candidateByID) {
        NSDictionary<NSString *, NSNumber *> *votes = idVotesByAccount[accountID];
        if (!votes.count) continue;
        NSString *best = WQMVLSMMostFrequent(votes, idOrderByAccount[accountID]);
        if (best) {
            WQMVLoginCandidate *candidate = candidateByID[accountID];
            candidate.wechatID = best;
        }
    }
    return candidates;
}

// LoginInfo candidates per Documents root, parsed at most once per path.
static NSMutableDictionary<NSString *, NSArray<WQMVLoginCandidate *> *> *gLoginInfoCache = nil;
static NSMutableSet<NSString *> *gLoginInfoMisses = nil;

static NSArray<WQMVLoginCandidate *> *WQMVLoginCandidatesForDocuments(NSString *documentsPath)
{
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLoginInfoCache = [NSMutableDictionary dictionary];
        gLoginInfoMisses = [NSMutableSet set];
        lock = [NSObject new];
    });
    @synchronized (lock) {
        NSArray<WQMVLoginCandidate *> *cached = gLoginInfoCache[documentsPath];
        if (cached) return cached;
        if ([gLoginInfoMisses containsObject:documentsPath]) return @[];
    }
    NSArray<WQMVLoginCandidate *> *found = @[];
    for (NSString *fileName in @[@"LoginInfo2.dat", @"LoginInfo.dat"]) {
        NSString *path = [documentsPath stringByAppendingPathComponent:fileName];
        NSString *error = nil;
        // 4 MB cap: the file should be tiny; anything bigger is not parsed.
        NSData *data = wq_read(path, 4 * 1024 * 1024, &error);
        if (!data.length) continue;
        NSArray<WQMVLoginCandidate *> *parsed = WQMVScanLoginInfoData(data);
        if (parsed.count) {
            found = parsed;
            break;
        }
    }
    @synchronized (lock) {
        if (found.count) gLoginInfoCache[documentsPath] = found;
        else [gLoginInfoMisses addObject:documentsPath];
    }
    return found;
}

// Scans one prepared statement's rows for the SELF row: the row whose
// userName column MD5-matches the folder hash. Identity fields are
// read ONLY from that row — values from any other row are never used,
// and a match through any other column does not count. Only the
// statement's own columns are read; the caller restricts which tables
// are ever queried.
static WQMVFolderIdentity *_Nullable WQMVIdentityFromStatement(sqlite3_stmt *stmt, NSString *folderHashLower)
{
    int columnCount = sqlite3_column_count(stmt);
    int rows = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (++rows > 20000) break;
        NSString *matchedID = nil;
        NSString *nickname = nil;
        NSString *wechatID = nil;
        NSString *alias = nil;
        NSData *remarkBlob = nil;
        for (int i = 0; i < columnCount; i++) {
            const char *columnNameUTF8 = sqlite3_column_name(stmt, i);
            NSString *columnName = columnNameUTF8 ? [NSString stringWithUTF8String:columnNameUTF8] : @"";
            NSString *lowerName = [columnName lowercaseString];
            int type = sqlite3_column_type(stmt, i);
            if (type == SQLITE_TEXT) {
                const unsigned char *text = sqlite3_column_text(stmt, i);
                if (!text) continue;
                NSString *value = [NSString stringWithUTF8String:(const char *)text];
                if (!value.length) continue;
                if ([lowerName isEqualToString:@"username"] && !matchedID && [WQMVMD5HexOfString(value) isEqualToString:folderHashLower]) {
                    matchedID = value;
                }
                if ([lowerName containsString:@"nickname"] || [lowerName isEqualToString:@"nick"]) {
                    if (!nickname) nickname = value;
                } else if ([lowerName containsString:@"alias"]) {
                    if (!alias) alias = value;
                } else if ([lowerName isEqualToString:@"wechat"] || [lowerName containsString:@"wechatid"]) {
                    if (!wechatID) wechatID = value;
                }
            } else if (type == SQLITE_BLOB && [lowerName isEqualToString:@"dbcontactremark"]) {
                const void *blob = sqlite3_column_blob(stmt, i);
                int bytes = sqlite3_column_bytes(stmt, i);
                if (blob && bytes > 0) {
                    remarkBlob = [NSData dataWithBytes:blob length:(NSUInteger)bytes];
                }
            }
        }
        if (matchedID) {
            NSString *protoNickname = nil;
            NSString *protoWechat = nil;
            NSString *protoAlias = nil;
            if (remarkBlob.length) {
                WQMVParseRemarkProto(remarkBlob, &protoNickname, &protoWechat, &protoAlias);
            }
            WQMVFolderIdentity *identity = [WQMVFolderIdentity new];
            identity.wxid = matchedID;
            identity.nickname = protoNickname ?: nickname;
            NSString *rawWechatID = protoWechat ?: wechatID;
            // The stored field is trusted only if it is a usable
            // custom ID: an unvalidated database value (e.g. another
            // account's ID sitting in the field) must never reach
            // the tag.
            if (WQMVIsUsableWechatID(rawWechatID, matchedID)) identity.wechatID = rawWechatID;
            identity.alias = protoAlias ?: alias;
            return identity;
        }
    }
    return nil;
}

// Runs one SQL query (a fixed string built by the caller from an
// allowlisted table name) and returns the matching identity, if any.
static WQMVFolderIdentity *_Nullable WQMVIdentityFromQuery(sqlite3 *db, NSString *sql, NSString *folderHashLower)
{
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) return nil;
    WQMVFolderIdentity *identity = nil;
    @try {
        identity = WQMVIdentityFromStatement(stmt, folderHashLower);
    } @catch (NSException *exception) {
        (void)exception;
        identity = nil;
    }
    sqlite3_finalize(stmt);
    return identity;
}

// Identity from one database file's bytes: the bytes are a private copy
// in this app's tmp dir, opened read-only with immutable=1 so SQLite
// never writes and never touches a -wal sidecar. Only the Friend and
// friend_meta tables are queried; message tables are never touched.
static WQMVFolderIdentity *_Nullable WQMVIdentityFromSQLiteData(NSData *dbData, NSString *folderHashLower)
{
    static const char sqliteMagic[] = "SQLite format 3";
    if (dbData.length < 16 || memcmp(dbData.bytes, sqliteMagic, 15) != 0) return nil;
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"sqlite"]];
    if (![dbData writeToFile:tmpPath atomically:NO]) return nil;
    WQMVFolderIdentity *result = nil;
    sqlite3 *db = NULL;
    @try {
        NSString *escaped = [tmpPath stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLPathAllowedCharacterSet]];
        NSString *uri = [NSString stringWithFormat:@"file:%@?immutable=1", escaped];
        if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
            (void)sqlite3_exec(db, "PRAGMA query_only=ON", NULL, NULL, NULL);
            // Tables actually present, so the queries below can only ever
            // name a real table from the allowlist.
            NSMutableSet<NSString *> *tables = [NSMutableSet set];
            sqlite3_stmt *listStmt = NULL;
            if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &listStmt, NULL) == SQLITE_OK) {
                while (sqlite3_step(listStmt) == SQLITE_ROW) {
                    const unsigned char *text = sqlite3_column_text(listStmt, 0);
                    if (text) {
                        NSString *name = [NSString stringWithUTF8String:(const char *)text];
                        if (name.length) [tables addObject:[name lowercaseString]];
                    }
                }
            }
            sqlite3_finalize(listStmt);
            for (NSString *wanted in @[@"friend", @"friend_meta"]) {
                if (![tables containsObject:wanted]) continue;
                // The exact wechat-dump query first; a generic column
                // scan covers older/drifted schemas.
                NSString *targeted = [NSString stringWithFormat:@"SELECT userName, dbContactRemark FROM \"%@\"", wanted];
                result = WQMVIdentityFromQuery(db, targeted, folderHashLower);
                if (!result) {
                    NSString *generic = [NSString stringWithFormat:@"SELECT * FROM \"%@\"", wanted];
                    result = WQMVIdentityFromQuery(db, generic, folderHashLower);
                }
                if (result) break;
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
        result = nil;
    }
    if (db) (void)sqlite3_close_v2(db);
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:NULL];
    return result;
}

// Identity from one database file inside a folder, via a size-capped
// byte copy. Nil when the file is missing, oversized, or unreadable.
static WQMVFolderIdentity *_Nullable WQMVIdentityFromDBFile(NSString *dbPath, NSString *folderHashLower)
{
    struct stat st;
    if (!wq_stat(dbPath, &st) || st.st_size <= 0 || st.st_size > 64 * 1024 * 1024) return nil;
    NSString *error = nil;
    NSData *data = wq_read(dbPath, 64 * 1024 * 1024, &error);
    if (!data.length || data.length >= 64 * 1024 * 1024) return nil;
    return WQMVIdentityFromSQLiteData(data, folderHashLower);
}

// mmsetting.archive / mmsettingext.archive: the account's own settings
// file, inside the 32-hex folder itself (current WeChat uses the "ext"
// name; both are checked). Binary NSKeyedArchiver plist: the top-level
// dict holds
// a "$objects" array, and containers reference other objects through
// UID values. The account dict ($objects[1], per WechatExport)
// carries UsrName (wxid), NickName, and AliasName — the custom WeChat
// ID, which the Friend table does NOT hold for the self account. Only
// those three keys are ever read: the archive also contains phone,
// city, signature and other personal data, which is never touched.
// Missing, oversized, or unparseable files yield nil, never a crash.
//
// The binary plist is parsed by hand below: CFUID is neither declared
// in the public SDK headers nor exported from CoreFoundation, so the
// UID objects NSPropertyListSerialization produces cannot be resolved.
// The hand reader parses the object table directly and decodes UID
// values into WQMVPlistUID markers, resolved against $objects.

// Marker for a UID reference in a binary plist; resolved lazily against
// the $objects array, never mistaken for a value.
@interface WQMVPlistUID : NSObject
@property (nonatomic) NSUInteger uid;
@end

@implementation WQMVPlistUID
@end

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    NSUInteger offsetIntSize;
    NSUInteger objectRefSize;
    NSUInteger objectCount;
    NSUInteger offsetTableOffset;
} WQMVPlistReader;

static BOOL WQMVPlistReadUInt(const uint8_t *bytes, NSUInteger length, NSUInteger pos, NSUInteger size, uint64_t *out)
{
    if (size == 0 || size > 8 || pos > length || size > length - pos) return NO;
    uint64_t value = 0;
    for (NSUInteger i = 0; i < size; i++) value = (value << 8) | bytes[pos + i];
    *out = value;
    return YES;
}

// Length of a sized object: inline when info < 0xF, else the following
// object must be an int giving the length.
static BOOL WQMVPlistReadLength(WQMVPlistReader *reader, NSUInteger pos, NSUInteger info, uint64_t *outLength, NSUInteger *outNextPos)
{
    if (info < 0xF) {
        *outLength = info;
        *outNextPos = pos;
        return YES;
    }
    if (pos >= reader->length) return NO;
    uint8_t marker = reader->bytes[pos];
    if ((marker >> 4) != 0x1) return NO;
    NSUInteger intInfo = marker & 0xF;
    if (intInfo > 3) return NO;
    NSUInteger size = (NSUInteger)1 << intInfo;
    uint64_t value = 0;
    if (!WQMVPlistReadUInt(reader->bytes, reader->length, pos + 1, size, &value)) return NO;
    *outLength = value;
    *outNextPos = pos + 1 + size;
    return YES;
}

static id _Nullable WQMVPlistDecodeObject(WQMVPlistReader *reader, NSUInteger index, NSUInteger depth);

static BOOL WQMVPlistObjectOffset(WQMVPlistReader *reader, NSUInteger index, NSUInteger *outOffset)
{
    if (index >= reader->objectCount) return NO;
    uint64_t tablePos = (uint64_t)reader->offsetTableOffset + (uint64_t)index * (uint64_t)reader->offsetIntSize;
    if (tablePos > reader->length) return NO;
    uint64_t offset = 0;
    if (!WQMVPlistReadUInt(reader->bytes, reader->length, (NSUInteger)tablePos, reader->offsetIntSize, &offset)) return NO;
    if (offset >= reader->length) return NO;
    *outOffset = (NSUInteger)offset;
    return YES;
}

static id _Nullable WQMVPlistDecodeObject(WQMVPlistReader *reader, NSUInteger index, NSUInteger depth)
{
    if (depth > 64) return nil;
    NSUInteger pos = 0;
    if (!WQMVPlistObjectOffset(reader, index, &pos)) return nil;
    uint8_t marker = reader->bytes[pos];
    NSUInteger type = marker >> 4;
    NSUInteger info = marker & 0xF;
    pos += 1;
    switch (type) {
        case 0x0: {
            if (info == 0x9) return @YES;
            if (info == 0x8) return @NO;
            return [NSNull null];
        }
        case 0x1: {
            if (info > 3) return nil;
            NSUInteger size = (NSUInteger)1 << info;
            uint64_t raw = 0;
            if (!WQMVPlistReadUInt(reader->bytes, reader->length, pos, size, &raw)) return nil;
            int64_t value = (int64_t)raw;
            if (size < 8 && (raw & ((uint64_t)1 << (size * 8 - 1)))) {
                value = (int64_t)(raw | (~(uint64_t)0 << (size * 8)));
            }
            return @(value);
        }
        case 0x2: {
            if (info > 3) return nil;
            NSUInteger size = (NSUInteger)1 << info;
            if (size != 4 && size != 8) return nil;
            if (pos > reader->length || size > reader->length - pos) return nil;
            double value = 0;
            if (size == 4) {
                uint32_t bits = 0;
                for (NSUInteger i = 0; i < 4; i++) bits = (bits << 8) | reader->bytes[pos + i];
                float f = 0;
                memcpy(&f, &bits, 4);
                value = f;
            } else {
                uint64_t bits = 0;
                for (NSUInteger i = 0; i < 8; i++) bits = (bits << 8) | reader->bytes[pos + i];
                memcpy(&value, &bits, 8);
            }
            return @(value);
        }
        case 0x3: {
            if (info != 3) return nil;
            if (pos > reader->length || 8 > reader->length - pos) return nil;
            uint64_t bits = 0;
            for (NSUInteger i = 0; i < 8; i++) bits = (bits << 8) | reader->bytes[pos + i];
            double seconds = 0;
            memcpy(&seconds, &bits, 8);
            return [NSDate dateWithTimeIntervalSinceReferenceDate:seconds];
        }
        case 0x4: {
            uint64_t len = 0;
            NSUInteger next = 0;
            if (!WQMVPlistReadLength(reader, pos, info, &len, &next)) return nil;
            if (len > reader->length - next) return nil;
            return [NSData dataWithBytes:reader->bytes + next length:(NSUInteger)len];
        }
        case 0x5: {
            uint64_t len = 0;
            NSUInteger next = 0;
            if (!WQMVPlistReadLength(reader, pos, info, &len, &next)) return nil;
            if (len > reader->length - next) return nil;
            NSString *s = [[NSString alloc] initWithBytes:reader->bytes + next length:(NSUInteger)len encoding:NSASCIIStringEncoding];
            if (!s) s = [[NSString alloc] initWithBytes:reader->bytes + next length:(NSUInteger)len encoding:NSUTF8StringEncoding];
            return s;
        }
        case 0x6: {
            uint64_t len = 0;
            NSUInteger next = 0;
            if (!WQMVPlistReadLength(reader, pos, info, &len, &next)) return nil;
            if (len > (reader->length - next) / 2) return nil;
            return [[NSString alloc] initWithBytes:reader->bytes + next length:(NSUInteger)len * 2 encoding:NSUTF16BigEndianStringEncoding];
        }
        case 0x8: {
            NSUInteger size = info + 1;
            if (size > 8) return nil;
            uint64_t value = 0;
            if (!WQMVPlistReadUInt(reader->bytes, reader->length, pos, size, &value)) return nil;
            WQMVPlistUID *uid = [WQMVPlistUID new];
            uid.uid = (NSUInteger)value;
            return uid;
        }
        case 0xA:
        case 0xC: {
            uint64_t len = 0;
            NSUInteger next = 0;
            if (!WQMVPlistReadLength(reader, pos, info, &len, &next)) return nil;
            if (len > reader->objectCount) return nil;
            if (len > (reader->length - next) / reader->objectRefSize) return nil;
            NSMutableArray *array = [NSMutableArray arrayWithCapacity:(NSUInteger)len];
            for (uint64_t i = 0; i < len; i++) {
                uint64_t ref = 0;
                if (!WQMVPlistReadUInt(reader->bytes, reader->length, next + (NSUInteger)i * reader->objectRefSize, reader->objectRefSize, &ref)) return nil;
                if (ref >= reader->objectCount) return nil;
                id child = WQMVPlistDecodeObject(reader, (NSUInteger)ref, depth + 1);
                if (!child) return nil;
                [array addObject:child];
            }
            return array;
        }
        case 0xD: {
            uint64_t len = 0;
            NSUInteger next = 0;
            if (!WQMVPlistReadLength(reader, pos, info, &len, &next)) return nil;
            if (len > reader->objectCount) return nil;
            if (len > (reader->length - next) / (reader->objectRefSize * 2)) return nil;
            NSUInteger keyBase = next;
            NSUInteger valueBase = next + (NSUInteger)len * reader->objectRefSize;
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)len];
            for (uint64_t i = 0; i < len; i++) {
                uint64_t keyRef = 0, valueRef = 0;
                if (!WQMVPlistReadUInt(reader->bytes, reader->length, keyBase + (NSUInteger)i * reader->objectRefSize, reader->objectRefSize, &keyRef)) return nil;
                if (!WQMVPlistReadUInt(reader->bytes, reader->length, valueBase + (NSUInteger)i * reader->objectRefSize, reader->objectRefSize, &valueRef)) return nil;
                if (keyRef >= reader->objectCount || valueRef >= reader->objectCount) return nil;
                id key = WQMVPlistDecodeObject(reader, (NSUInteger)keyRef, depth + 1);
                if (![key isKindOfClass:[NSString class]]) continue;
                id value = WQMVPlistDecodeObject(reader, (NSUInteger)valueRef, depth + 1);
                if (!value) return nil;
                dict[key] = value;
            }
            return dict;
        }
        default:
            return nil;
    }
}

// Follows UID markers against the $objects array. Depth-capped, so a
// cyclic archive degrades to nil instead of recursing forever.
static id _Nullable WQMVPlistResolveUID(id _Nullable node, NSArray *objects, NSUInteger depth)
{
    if (!node || depth > 32) return nil;
    if ([node isKindOfClass:[WQMVPlistUID class]]) {
        NSUInteger uid = ((WQMVPlistUID *)node).uid;
        if (uid >= objects.count) return nil;
        return WQMVPlistResolveUID(objects[uid], objects, depth + 1);
    }
    return node;
}

static NSString *_Nullable WQMVPlistStringForKey(id _Nullable dictNode, NSArray *objects, NSString *key)
{
    id dict = WQMVPlistResolveUID(dictNode, objects, 0);
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    id value = WQMVPlistResolveUID(((NSDictionary *)dict)[key], objects, 0);
    if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length) return (NSString *)value;
    return nil;
}

static void WQMVPlistFillFromDict(id _Nullable dictNode, NSArray *objects, WQMVFolderIdentity *identity, NSString *folderHashLower)
{
    // A dict contributes only when it belongs to this folder's
    // account: its UsrName must be absent (an unattributed dict inside
    // this folder's own file) or MD5-match the folder. A dict whose
    // UsrName names another account contributes nothing — fields must
    // never be mixed across accounts.
    NSString *usrName = WQMVPlistStringForKey(dictNode, objects, @"UsrName");
    if (usrName.length && ![WQMVMD5HexOfString(usrName) isEqualToString:folderHashLower]) return;
    if (!identity.wxid.length) identity.wxid = usrName;
    if (!identity.nickname.length) identity.nickname = WQMVPlistStringForKey(dictNode, objects, @"NickName");
    if (!identity.wechatID.length) identity.wechatID = WQMVPlistStringForKey(dictNode, objects, @"AliasName");
}

// Returns YES when the data parsed as a binary plist (keys may still be
// absent); NO when it is not a binary plist at all, so the caller can
// fall back to a plain property-list walk.
static BOOL WQMVFillIdentityFromBPlist(NSData *data, WQMVFolderIdentity *identity, NSString *folderHashLower)
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    if (length < 8 + 32) return NO;
    if (memcmp(bytes, "bplist00", 8) != 0) return NO;
    const uint8_t *trailer = bytes + length - 32;
    NSUInteger offsetIntSize = trailer[6];
    NSUInteger objectRefSize = trailer[7];
    if (offsetIntSize < 1 || offsetIntSize > 8 || objectRefSize < 1 || objectRefSize > 8) return NO;
    uint64_t objectCount = 0, topIndex = 0, offsetTableOffset = 0;
    for (int i = 0; i < 8; i++) objectCount = (objectCount << 8) | trailer[8 + i];
    for (int i = 0; i < 8; i++) topIndex = (topIndex << 8) | trailer[16 + i];
    for (int i = 0; i < 8; i++) offsetTableOffset = (offsetTableOffset << 8) | trailer[24 + i];
    if (objectCount == 0 || objectCount > 1000000) return NO;
    if (topIndex >= objectCount) return NO;
    if (offsetTableOffset >= length) return NO;
    if (objectCount > (length - offsetTableOffset) / offsetIntSize) return NO;
    WQMVPlistReader reader = { bytes, length, offsetIntSize, objectRefSize, (NSUInteger)objectCount, (NSUInteger)offsetTableOffset };
    id top = WQMVPlistDecodeObject(&reader, (NSUInteger)topIndex, 0);
    if (!top) return NO;
    if (![top isKindOfClass:[NSDictionary class]]) return YES;
    NSDictionary *topDict = (NSDictionary *)top;
    NSArray *objects = topDict[@"$objects"];
    if (![objects isKindOfClass:[NSArray class]] || !objects.count) {
        // Plain binary plist: read the keys from the top dict itself.
        WQMVPlistFillFromDict(topDict, @[], identity, folderHashLower);
        return YES;
    }
    // Primary: the account dict at $objects[1] (WechatExport).
    if (objects.count > 1) WQMVPlistFillFromDict(objects[1], objects, identity, folderHashLower);
    // $top root, then a scan of every object for a dict holding any key.
    if (!identity.wxid.length || !identity.nickname.length || !identity.wechatID.length) {
        id topRef = topDict[@"$top"];
        if ([topRef isKindOfClass:[NSDictionary class]]) {
            WQMVPlistFillFromDict(WQMVPlistResolveUID(((NSDictionary *)topRef)[@"root"], objects, 0), objects, identity, folderHashLower);
        }
    }
    if (!identity.wxid.length || !identity.nickname.length || !identity.wechatID.length) {
        for (id node in objects) {
            WQMVPlistFillFromDict(node, objects, identity, folderHashLower);
            if (identity.wxid.length && identity.nickname.length && identity.wechatID.length) break;
        }
    }
    return YES;
}

// Plain property-list walk for non-binary archives: collects literal
// string values of the three keys from any dictionary in the graph.
// No UID resolution here — the binary reader above covers keyed
// archives; this only helps if the file is a plain plist.
static void WQMVFillIdentityFromPlainPlist(id _Nullable node, WQMVFolderIdentity *identity, NSUInteger depth, NSString *folderHashLower)
{
    if (!node || depth > 32) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        // Same attribution rule as the binary reader: a dict whose
        // UsrName names another account contributes nothing.
        id usrNameValue = dict[@"UsrName"];
        BOOL attributed = [usrNameValue isKindOfClass:[NSString class]] && ((NSString *)usrNameValue).length > 0;
        if (!attributed || [WQMVMD5HexOfString((NSString *)usrNameValue) isEqualToString:folderHashLower]) {
            for (NSString *key in @[@"UsrName", @"NickName", @"AliasName"]) {
                id value = dict[key];
                if (![value isKindOfClass:[NSString class]] || !((NSString *)value).length) continue;
                if ([key isEqualToString:@"UsrName"] && !identity.wxid.length) identity.wxid = value;
                else if ([key isEqualToString:@"NickName"] && !identity.nickname.length) identity.nickname = value;
                else if ([key isEqualToString:@"AliasName"] && !identity.wechatID.length) identity.wechatID = value;
            }
        }
        for (id value in [dict allValues]) WQMVFillIdentityFromPlainPlist(value, identity, depth + 1, folderHashLower);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) WQMVFillIdentityFromPlainPlist(value, identity, depth + 1, folderHashLower);
    }
}

static WQMVFolderIdentity *_Nullable WQMVIdentityFromMMSettingData(NSData *data, NSString *folderHashLower)
{
    WQMVFolderIdentity *identity = [WQMVFolderIdentity new];
    @try {
        if (!WQMVFillIdentityFromBPlist(data, identity, folderHashLower)) {
            id plist = [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListImmutable
                                                                  format:NULL
                                                                   error:NULL];
            WQMVFillIdentityFromPlainPlist(plist, identity, 0, folderHashLower);
        }
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
    if (!identity.wxid.length && !identity.nickname.length && !identity.wechatID.length) return nil;
    // Sanity guard: when UsrName is present it must MD5-match the folder,
    // else the whole archive is ignored. Without UsrName, the file's
    // location inside the folder already scopes AliasName/NickName.
    if (identity.wxid.length && ![WQMVMD5HexOfString(identity.wxid) isEqualToString:folderHashLower]) return nil;
    // A stored AliasName is trusted only if it is a usable custom ID.
    if (identity.wechatID.length && !WQMVIsUsableWechatID(identity.wechatID, identity.wxid)) identity.wechatID = nil;
    if (!identity.wxid.length && !identity.nickname.length && !identity.wechatID.length) return nil;
    return identity;
}

static WQMVFolderIdentity *_Nullable WQMVIdentityFromMMSettingFile(NSString *folderPath, NSString *fileName, NSString *folderHashLower)
{
    NSString *path = [folderPath stringByAppendingPathComponent:fileName];
    struct stat st;
    if (!wq_stat(path, &st) || st.st_size <= 0 || st.st_size > 4 * 1024 * 1024) return nil;
    NSString *error = nil;
    // 4 MB cap: the file should be tiny; anything bigger is not parsed.
    NSData *data = wq_read(path, 4 * 1024 * 1024, &error);
    if (!data.length || data.length >= 4 * 1024 * 1024) return nil;
    return WQMVIdentityFromMMSettingData(data, folderHashLower);
}

// --- session/lsm_data identity source ---
//
// The self account's custom WeChat ID also appears in
// <folder>/session/lsm_data/level_* files, in a protobuf-like record
// adjacent to the account ID: the account ID string, two structural
// bytes (a field tag + length), then the custom ID. Byte-identical
// records repeat across level files (compaction duplicates).
// LoginInfo2.dat holds the same field (source (b) above) for accounts
// that logged in on this device, so this source is the fallback for
// folders whose account never did, or was moved in from elsewhere.
// The LSM store is WeChat's session key-value storage (LevelDB-style);
// its records are protobuf-framed and unencrypted, so the custom ID
// is a length-delimited field right after the account-ID field. This
// source is LAST in the merge: it only fills fields the earlier
// sources did not.
//
// STRICT matching: missing is acceptable; wrong is not. An occurrence
// counts only when:
// (1) the anchor is a real protobuf length-delimited field — the two
// bytes before it are a wire-type-2 tag plus a length equal to the
// anchor length; (2) the candidate is the IMMEDIATELY NEXT protobuf
// field, parsed as exactly one length-delimited field, matching the
// custom-ID shape; (3) the candidate is not a `gh_` id, not the
// anchor, not containing the anchor, not all-hex, not all digits;
// (4) the candidate neighbors only ONE distinct anchor across the
// whole scan (shared entities neighbor many). No window scan, no
// multi-field scan. Nickname is NEVER taken from lsm_data.
//
// Identity-only: bytes are read only to find an MD5-verified anchor
// (the account ID) and the ID field immediately after it. Record
// contents are never dumped, message data is never touched, and
// nothing else from these files reaches the UI. No
// account-specific value is ever hardcoded: anchoring is by the
// account ID / folder-hash MD5, and ID recognition is a generic shape
// check.

static const NSUInteger kWQMVLSMMaxFileBytes = 64 * 1024 * 1024;
static const unsigned long long kWQMVLSMMaxTotalBytes = 256ULL * 1024 * 1024;
static const NSUInteger kWQMVLSMMaxOccurrencesPerFile = 4096;

// Shape of a custom WeChat ID: 6-20 chars, starts with a letter, then
// letters, digits, _ or -. (WeChat's own rule for settable IDs.)
static BOOL WQMVLSMMatchesIDShape(NSString *value)
{
    if (value.length < 6 || value.length > 20) return NO;
    unichar first = [value characterAtIndex:0];
    if (!((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z'))) return NO;
    for (NSUInteger i = 1; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-')) return NO;
    }
    return YES;
}

// A usable custom-ID candidate: right shape, not a reserved word
// (WeChat's own names `weixin`/`wechat` are unregistrable as custom
// IDs — a record for an account without a custom ID can carry one as
// a marker/default in the field next to the account ID, and it must
// never reach the tag), not a system ID (the `wxid_` account-ID
// prefix is never a settable custom ID), not the anchor itself, not
// containing the anchor (a longer string that merely embeds the
// account ID is not the custom ID), not an all-hex token of 8+ chars
// (a hash or machine id, not a settable ID), and not all digits. The
// `gh_` official-account prefix is rejected separately by the caller.
static BOOL WQMVLSMIsCustomIDCandidate(NSString *value, NSString *anchor)
{
    if (!WQMVLSMMatchesIDShape(value)) return NO;
    if ([value caseInsensitiveCompare:@"weixin"] == NSOrderedSame) return NO;
    if ([value caseInsensitiveCompare:@"wechat"] == NSOrderedSame) return NO;
    if ([value hasPrefix:@"wxid_"]) return NO;
    if ([value isEqualToString:anchor]) return NO;
    if (anchor.length && [value containsString:anchor]) return NO;
    BOOL allHex = YES;
    BOOL allDigits = YES;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) allHex = NO;
        if (c < '0' || c > '9') allDigits = NO;
    }
    if (allDigits) return NO;
    if (allHex && value.length >= 8) return NO;
    return YES;
}

// Full usability check for a custom WeChat ID from ANY source: the
// shape/rejection rules above plus the `gh_` official-account prefix
// (rejected separately by the strict-path callers, folded in here so
// every path applies one identical rule) and the reserved words
// `weixin`/`wechat` (rejected here explicitly as well, so the
// merge-time gate kills them even if a source bypassed the validator).
// Used by the database and settings-archive sources and by the
// merge-time gate; the strict LoginInfo/LSM paths apply the same rules
// at vote time.
static BOOL WQMVIsUsableWechatID(NSString *value, NSString *anchor)
{
    if (!value.length) return NO;
    if ([value hasPrefix:@"gh_"]) return NO;
    if ([value caseInsensitiveCompare:@"weixin"] == NSOrderedSame) return NO;
    if ([value caseInsensitiveCompare:@"wechat"] == NSOrderedSame) return NO;
    return WQMVLSMIsCustomIDCandidate(value, anchor);
}

// Bounds-checked varint reader for the strict protobuf parse.
static BOOL WQMVLSMReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *pos, uint64_t *out)
{
    uint64_t value = 0;
    int shift = 0;
    while (*pos < length) {
        if (shift >= 64) return NO;
        uint8_t b = bytes[(*pos)++];
        value |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) {
            *out = value;
            return YES;
        }
        shift += 7;
    }
    return NO;
}

// Field-start verification: the anchor must be a real protobuf
// length-delimited field, not a byte run that happens to contain the
// account ID (message text, keys, other records). The two bytes
// immediately before the anchor must be a tag byte with wire type 2
// and field number >= 1, plus a one-byte length equal to the anchor
// length. Anchors are < 128 bytes, so a one-byte length is the only
// canonical encoding; anything else is skipped, never guessed.
static BOOL WQMVLSMAnchorHasValidFieldHeader(const uint8_t *bytes, NSUInteger anchorPos, NSUInteger anchorLength)
{
    if (anchorPos < 2) return NO;
    uint8_t tag = bytes[anchorPos - 2];
    if ((tag & 0x07) != 2) return NO;
    if ((tag >> 3) == 0) return NO;
    return bytes[anchorPos - 1] == anchorLength;
}

// Parses EXACTLY ONE protobuf field starting at startPos (just after
// the anchor): tag varint + wire type 2 + length varint + string
// bytes. Returns the field's UTF-8 string, or nil when the bytes do
// not form one complete length-delimited UTF-8 field. *parsedField is
// set YES only when a complete field was read and decoded; nil with
// *parsedField == NO means "no valid next field", not "wrong shape".
// Nothing past this one field is ever read.
static NSString *_Nullable WQMVLSMNextFieldString(const uint8_t *bytes, NSUInteger length, NSUInteger startPos, BOOL *parsedField)
{
    if (parsedField) *parsedField = NO;
    NSUInteger pos = startPos;
    uint64_t key = 0;
    if (!WQMVLSMReadVarint(bytes, length, &pos, &key)) return nil;
    if ((key >> 3) == 0) return nil; // field number 0 is invalid
    if ((key & 7) != 2) return nil;
    uint64_t count = 0;
    if (!WQMVLSMReadVarint(bytes, length, &pos, &count)) return nil;
    if (count > length - pos) return nil;
    NSString *field = [[NSString alloc] initWithBytes:bytes + pos
                                               length:(NSUInteger)count
                                             encoding:NSUTF8StringEncoding];
    if (!field) return nil;
    if (parsedField) *parsedField = YES;
    return field;
}

// Finds MD5-verified anchor occurrences in raw bytes. Two ways in:
// (i) occurrences of the already-known account ID (from earlier merge
// sources), (ii) candidate account-ID tokens — `wxid_` runs and
// maximal digit runs of 5-11 chars — each MD5-checked against the
// folder hash. Only exact MD5 matches anchor. Returns an array of
// @{@"pos": @(byte offset), @"anchor": account ID}, position-deduped,
// capped per file as a safety valve (real files hold a handful).
static NSArray<NSDictionary *> *WQMVLSMAnchorOccurrences(NSData *data, NSString *folderHashLower, NSData *_Nullable knownWxidUTF8, NSString *_Nullable knownWxid)
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSMutableArray<NSDictionary *> *occurrences = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenPositions = [NSMutableSet set];
    if (knownWxid.length && knownWxidUTF8.length) {
        const uint8_t *pattern = (const uint8_t *)knownWxidUTF8.bytes;
        NSUInteger patternLength = knownWxidUTF8.length;
        NSUInteger pos = 0;
        while (pos + patternLength <= length && occurrences.count < kWQMVLSMMaxOccurrencesPerFile) {
            const uint8_t *hit = memchr(bytes + pos, pattern[0], length - pos);
            if (!hit) break;
            NSUInteger at = (NSUInteger)(hit - bytes);
            if (at + patternLength > length) break;
            if (memcmp(hit, pattern, patternLength) == 0) {
                [occurrences addObject:@{@"pos": @(at), @"anchor": knownWxid}];
                [seenPositions addObject:@(at)];
                pos = at + patternLength;
            } else {
                pos = at + 1;
            }
        }
    }
    NSUInteger i = 0;
    while (i < length && occurrences.count < kWQMVLSMMaxOccurrencesPerFile) {
        uint8_t b = bytes[i];
        if (b == 'w' && i + 5 <= length && memcmp(bytes + i, "wxid_", 5) == 0) {
            NSUInteger end = i + 5;
            while (end < length) {
                uint8_t c = bytes[end];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_') end++;
                else break;
            }
            if (end > i + 5 && ![seenPositions containsObject:@(i)]) {
                NSString *token = [[NSString alloc] initWithBytes:bytes + i
                                                           length:end - i
                                                         encoding:NSASCIIStringEncoding];
                if (token && [WQMVMD5HexOfString(token) isEqualToString:folderHashLower]) {
                    [occurrences addObject:@{@"pos": @(i), @"anchor": token}];
                    [seenPositions addObject:@(i)];
                }
            }
            i = end;
        } else if (b >= '0' && b <= '9') {
            NSUInteger end = i;
            while (end < length && bytes[end] >= '0' && bytes[end] <= '9') end++;
            if (end - i >= 5 && end - i <= 11 && ![seenPositions containsObject:@(i)]) {
                NSString *token = [[NSString alloc] initWithBytes:bytes + i
                                                           length:end - i
                                                         encoding:NSASCIIStringEncoding];
                if (token && [WQMVMD5HexOfString(token) isEqualToString:folderHashLower]) {
                    [occurrences addObject:@{@"pos": @(i), @"anchor": token}];
                    [seenPositions addObject:@(i)];
                }
            }
            i = end;
        } else {
            i++;
        }
    }
    return occurrences;
}

static void WQMVLSMVote(NSMutableDictionary<NSString *, NSNumber *> *votes, NSMutableArray<NSString *> *order, NSString *candidate)
{
    NSNumber *existing = votes[candidate];
    if (!existing) {
        votes[candidate] = @1;
        [order addObject:candidate];
    } else {
        votes[candidate] = @(existing.unsignedIntegerValue + 1);
    }
}

// Extracts at most one ID vote from one anchor occurrence, strictly:
// field-start verification, then the immediately next protobuf field
// only, then the rejection rules. Surviving candidates vote once per
// occurrence and
// record their anchor, for the cross-anchor uniqueness filter applied
// after the whole scan. Never votes for a nickname.
static void WQMVLSMExtractFromOccurrence(NSData *data, NSUInteger anchorPos, NSString *anchor, NSMutableDictionary<NSString *, NSNumber *> *idVotes, NSMutableArray<NSString *> *idOrder, NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *candidateAnchors)
{
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSData *anchorUTF8 = [anchor dataUsingEncoding:NSUTF8StringEncoding];
    if (!anchorUTF8.length || anchorPos + anchorUTF8.length > length) {
        return;
    }
    if (!WQMVLSMAnchorHasValidFieldHeader(bytes, anchorPos, anchorUTF8.length)) {
        return;
    }
    BOOL parsedField = NO;
    NSString *next = WQMVLSMNextFieldString(bytes, length, anchorPos + anchorUTF8.length, &parsedField);
    if (!next) {
        return;
    }
    if ([next hasPrefix:@"gh_"]) {
        return;
    }
    if (!WQMVLSMIsCustomIDCandidate(next, anchor)) {
        return;
    }
    WQMVLSMVote(idVotes, idOrder, next);
    NSMutableSet<NSString *> *anchors = candidateAnchors[next];
    if (!anchors) {
        anchors = [NSMutableSet set];
        candidateAnchors[next] = anchors;
    }
    [anchors addObject:anchor];
}

// Most frequent candidate; ties go to the first seen.
static NSString *_Nullable WQMVLSMMostFrequent(NSDictionary<NSString *, NSNumber *> *votes, NSArray<NSString *> *order)
{
    NSString *best = nil;
    NSUInteger bestCount = 0;
    for (NSString *candidate in order) {
        NSUInteger count = votes[candidate].unsignedIntegerValue;
        if (count > bestCount) {
            bestCount = count;
            best = candidate;
        }
    }
    return best;
}

// Identity from <folder>/session/lsm_data/: scans level_* files for
// the account ID (known wxid, or MD5-verified tokens) and extracts the
// custom WeChat ID from the protobuf field immediately after the
// anchor, under the strict rules above. Returns nil when the directory
// is missing or nothing survives. knownWxid may be nil (token
// anchoring only). Blocking: call off the main
// thread. This function NEVER sets nickname.
static WQMVFolderIdentity *_Nullable WQMVIdentityFromLSMData(NSString *folderPath, NSString *folderHashLower, NSString *_Nullable knownWxid)
{
    NSString *lsmDir = [[folderPath stringByAppendingPathComponent:@"session"] stringByAppendingPathComponent:@"lsm_data"];
    NSString *error = nil;
    NSArray<NSString *> *names = wq_list(lsmDir, &error);
    if (!names) return nil;
    NSMutableArray<NSString *> *levelFiles = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"level_"]) [levelFiles addObject:name];
    }
    [levelFiles sortUsingSelector:@selector(compare:)];
    NSData *knownWxidUTF8 = knownWxid.length ? [knownWxid dataUsingEncoding:NSUTF8StringEncoding] : nil;
    NSMutableDictionary<NSString *, NSNumber *> *idVotes = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *idOrder = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *candidateAnchors = [NSMutableDictionary dictionary];
    NSString *verifiedAnchor = nil;
    unsigned long long bytesRead = 0;
    for (NSString *fileName in levelFiles) {
        NSString *full = [lsmDir stringByAppendingPathComponent:fileName];
        struct stat st;
        if (!wq_stat(full, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0) continue;
        if ((unsigned long long)st.st_size > kWQMVLSMMaxFileBytes) {
            continue;
        }
        if (bytesRead + (unsigned long long)st.st_size > kWQMVLSMMaxTotalBytes) {
            break;
        }
        NSString *readError = nil;
        NSData *data = wq_read(full, kWQMVLSMMaxFileBytes, &readError);
        if (!data.length || (unsigned long long)data.length != (unsigned long long)st.st_size) continue;
        bytesRead += data.length;
        NSArray<NSDictionary *> *occurrences = WQMVLSMAnchorOccurrences(data, folderHashLower, knownWxidUTF8, knownWxid);
        for (NSDictionary *occurrence in occurrences) {
            NSUInteger anchorPos = [occurrence[@"pos"] unsignedIntegerValue];
            NSString *anchor = occurrence[@"anchor"];
            if (!verifiedAnchor) verifiedAnchor = anchor;
            WQMVLSMExtractFromOccurrence(data, anchorPos, anchor, idVotes, idOrder, candidateAnchors);
        }
    }
    // Cross-anchor uniqueness: a personal custom ID neighbors only its
    // own account ID. A candidate seen next to two or more distinct
    // anchors belongs to a shared entity (e.g. a followed account),
    // not to this folder's account — drop it entirely.
    for (NSString *candidate in [idVotes allKeys]) {
        if (candidateAnchors[candidate].count >= 2) {
            [idVotes removeObjectForKey:candidate];
        }
    }
    NSString *bestID = WQMVLSMMostFrequent(idVotes, idOrder);
    if (!bestID && !verifiedAnchor) return nil;
    WQMVFolderIdentity *identity = [WQMVFolderIdentity new];
    identity.wxid = verifiedAnchor;
    identity.wechatID = bestID;
    // Nickname is NEVER set from lsm_data: the session store's nearby
    // strings include message fragments, and a wrong nickname is worse
    // than none. Other sources may still supply it.
    return identity;
}

// Identity cache: folder path -> identity, plus recorded misses, so a
// folder is never re-scanned within a session.
static NSMutableDictionary<NSString *, WQMVFolderIdentity *> *gIdentityCache = nil;
static NSMutableSet<NSString *> *gIdentityMisses = nil;

// Blocking: call off the main thread. Merge: ALL five sources are
// always consulted — (a) mmsetting.archive / mmsettingext.archive
// inside the folder, (b) LoginInfo files at the Documents root,
// (c) WCDB_Contact.sqlite, (d) MM.sqlite, (e) session/lsm_data — and
// their fields are merged first-non-empty per field (source order
// a -> b -> c -> d -> e). mmsetting goes first because it is the
// account's own settings file (older data may hold UsrName/NickName/
// AliasName there); lsm_data goes last as the fallback for folders
// whose account never logged in on this device. LoginInfo decides the
// custom ID: when LoginInfo2.dat holds this account's record but the
// parse yields no custom ID, the account has none, and wechatID values
// from the folder-local sources are suppressed — those sources emit
// ID-shaped neighbor/system values for accounts without a custom ID.
// Only when LoginInfo has no record for the account at all may the
// folder-local sources supply a custom ID. Alias and the other fields
// still merge from every source. Every source is keyed by the same
// folder hash (MD5 match), so merged fields always belong to this
// folder. Nil means "show the folder hash"; that happens only when
// all five sources yield nothing.
// Shared merge body for both resolution paths. loginCandidates is
// the LoginInfo evidence for this folder's account: the containing
// container's own records for a normal source, or the union across
// every detected WeChat container for a folder under the backup root
// (whose own container has no LoginInfo). Everything else — the
// folder-local sources, the merge order, "LoginInfo decides", and the
// merge-time gate — is identical for both paths.
static WQMVFolderIdentity *_Nullable WQMVResolveFolderIdentityWithLoginCandidates(NSString *folderPath, NSString *folderName, NSArray<WQMVLoginCandidate *> *loginCandidates)
{
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gIdentityCache = [NSMutableDictionary dictionary];
        gIdentityMisses = [NSMutableSet set];
        lock = [NSObject new];
    });
    @synchronized (lock) {
        WQMVFolderIdentity *cached = gIdentityCache[folderPath];
        if (cached) return cached;
        if ([gIdentityMisses containsObject:folderPath]) return nil;
    }
    NSString *folderHashLower = [folderName lowercaseString];
    WQMVFolderIdentity *merged = [WQMVFolderIdentity new];
    BOOL any = NO;
    // "LoginInfo decides": set when LoginInfo2.dat / LoginInfo.dat
    // holds a record for this folder's account (an anchor occurrence
    // whose MD5 matches the folder hash). If the LoginInfo parse then
    // yields no custom ID, the account has none, and wechatID values
    // from the other sources are suppressed below.
    BOOL loginInfoSawAccount = NO;
    NSString *_Nullable loginInfoWechatID = nil;
    @try {
        // Both settings-archive names, oldest first: the merge is
        // first-non-empty per field, so an older folder's archive and
        // a current one agree rather than fight.
        for (NSString *fileName in @[@"mmsetting.archive", @"mmsettingext.archive"]) {
            WQMVFolderIdentity *mmsettingIdentity = WQMVIdentityFromMMSettingFile(folderPath, fileName, folderHashLower);
            if (mmsettingIdentity) {
                [merged mergeMissingFieldsFromIdentity:mmsettingIdentity];
                any = YES;
            }
        }
        for (WQMVLoginCandidate *candidate in loginCandidates) {
            if ([WQMVMD5HexOfString(candidate.accountID) isEqualToString:folderHashLower]) {
                loginInfoSawAccount = YES;
                loginInfoWechatID = candidate.wechatID;
                WQMVFolderIdentity *loginIdentity = [WQMVFolderIdentity new];
                loginIdentity.wxid = candidate.accountID;
                loginIdentity.phone = candidate.phone;
                loginIdentity.nickname = candidate.name;
                loginIdentity.wechatID = candidate.wechatID;
                [merged mergeMissingFieldsFromIdentity:loginIdentity];
                any = YES;
                break;
            }
        }
        WQMVFolderIdentity *wcdbIdentity = WQMVIdentityFromDBFile([folderPath stringByAppendingPathComponent:@"DB/WCDB_Contact.sqlite"], folderHashLower);
        if (wcdbIdentity) {
            [merged mergeMissingFieldsFromIdentity:wcdbIdentity];
            any = YES;
        }
        WQMVFolderIdentity *mmIdentity = WQMVIdentityFromDBFile([folderPath stringByAppendingPathComponent:@"DB/MM.sqlite"], folderHashLower);
        if (mmIdentity) {
            [merged mergeMissingFieldsFromIdentity:mmIdentity];
            any = YES;
        }
        WQMVFolderIdentity *lsmIdentity = WQMVIdentityFromLSMData(folderPath, folderHashLower, merged.wxid);
        if (lsmIdentity) {
            [merged mergeMissingFieldsFromIdentity:lsmIdentity];
            any = YES;
        }
    } @catch (NSException *exception) {
        (void)exception;
        any = NO;
    }
    // "LoginInfo decides": when LoginInfo holds this account's record
    // but yields no custom ID, the account has no custom ID, so any
    // merged custom ID necessarily came from a folder-local source
    // reading an ID-shaped neighbor/system value, and it is dropped.
    // Only the wechatID field is suppressed, and only under this
    // condition; wxid/nickname/alias merging is unchanged.
    if (loginInfoSawAccount && !loginInfoWechatID.length) {
        merged.wechatID = nil;
    }
    // Merge-time gate (defense in depth): no source may put an
    // unusable value on the tag. A merged custom ID that fails the
    // shape rules, carries a system prefix, or equals/contains the
    // account ID is dropped — an empty tag is always better than a
    // wrong one.
    if (merged.wechatID.length && !WQMVIsUsableWechatID(merged.wechatID, merged.wxid)) {
        merged.wechatID = nil;
    }
    WQMVFolderIdentity *found = any ? merged : nil;
    @synchronized (lock) {
        if (found) gIdentityCache[folderPath] = found;
        else [gIdentityMisses addObject:folderPath];
    }
    return found;
}

// Per-container path (normal WeChat / temp sources): LoginInfo
// evidence comes from the containing container's own Documents root.
static WQMVFolderIdentity *_Nullable WQMVResolveFolderIdentity(NSString *documentsPath, NSString *folderPath, NSString *folderName)
{
    return WQMVResolveFolderIdentityWithLoginCandidates(folderPath, folderName,
                                                        WQMVLoginCandidatesForDocuments(documentsPath));
}

// Union of LoginInfo records across every detected WeChat container,
// built once per launch and cached (blocking: call off the main
// thread — the container scan takes seconds). One candidate per
// account: the most frequent non-empty field-13 value across files
// wins. When every record for an account has an empty field 13, the
// candidate carries no custom ID, so "LoginInfo decides" suppresses
// folder-local values exactly as in the per-container path. A
// non-empty field 13 from any file is positive proof of a custom ID
// and beats empty fields from other files (a record written before
// the ID was set).
static NSArray<WQMVLoginCandidate *> *WQMVGlobalLoginCandidates(void)
{
    static NSObject *lock = nil;
    static NSArray<WQMVLoginCandidate *> *cached = nil;
    static BOOL built = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    @synchronized (lock) {
        if (built) return cached;
    }
    NSMutableDictionary<NSString *, WQMVLoginCandidate *> *candidateByID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *votesByAccount = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *orderByAccount = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *accountOrder = [NSMutableArray array];
    for (WQMVApp *app in [WQMVResolver detectWeChatApps]) {
        for (WQMVLoginCandidate *candidate in WQMVLoginCandidatesForDocuments(app.documentsPath)) {
            if (!candidate.accountID.length) continue;
            if (!candidateByID[candidate.accountID]) {
                WQMVLoginCandidate *merged = [WQMVLoginCandidate new];
                merged.accountID = candidate.accountID;
                merged.phone = candidate.phone;
                merged.name = candidate.name;
                candidateByID[candidate.accountID] = merged;
                [accountOrder addObject:candidate.accountID];
            }
            if (!candidate.wechatID.length) continue;
            NSMutableDictionary<NSString *, NSNumber *> *votes = votesByAccount[candidate.accountID];
            NSMutableArray<NSString *> *order = orderByAccount[candidate.accountID];
            if (!votes) {
                votes = [NSMutableDictionary dictionary];
                votesByAccount[candidate.accountID] = votes;
            }
            if (!order) {
                order = [NSMutableArray array];
                orderByAccount[candidate.accountID] = order;
            }
            if (!votes[candidate.wechatID]) [order addObject:candidate.wechatID];
            votes[candidate.wechatID] = @(votes[candidate.wechatID].unsignedIntegerValue + 1);
        }
    }
    for (NSString *accountID in accountOrder) {
        NSDictionary<NSString *, NSNumber *> *votes = votesByAccount[accountID];
        if (!votes.count) continue;
        candidateByID[accountID].wechatID = WQMVLSMMostFrequent(votes, orderByAccount[accountID]);
    }
    NSMutableArray<WQMVLoginCandidate *> *result = [NSMutableArray array];
    for (NSString *accountID in accountOrder) [result addObject:candidateByID[accountID]];
    @synchronized (lock) {
        cached = [result copy];
        built = YES;
    }
    return cached;
}

// Backup-root path: the Files container holds no LoginInfo, so the
// LoginInfo evidence is the union across all detected WeChat
// containers. Folder-local sources contribute a custom ID only when
// the account appears in no WeChat LoginInfo file — the same
// "LoginInfo decides" rule as the per-container path.
static WQMVFolderIdentity *_Nullable WQMVResolveBackupFolderIdentity(NSString *folderPath, NSString *folderName)
{
    return WQMVResolveFolderIdentityWithLoginCandidates(folderPath, folderName, WQMVGlobalLoginCandidates());
}

#pragma mark - Folder items

@interface WQMVItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isDir;
@property (nonatomic, strong, nullable) WQMVFolderIdentity *identity; // set on the main thread when resolved
@end

@implementation WQMVItem
@end

// Blocking: call off the main thread. Nil on failure (errorText set).
static NSArray<WQMVItem *> *_Nullable WQMVListDocuments(NSString *documentsPath, NSString **errorText)
{
    NSString *error = nil;
    NSArray<NSString *> *names = wq_list(documentsPath, &error);
    if (!names) {
        if (errorText) *errorText = error;
        return nil;
    }
    NSMutableArray<WQMVItem *> *items = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
        if (WQMVIsAllZeroFolderName(name)) continue;
        struct stat st;
        NSString *full = [documentsPath stringByAppendingPathComponent:name];
        WQMVItem *item = [WQMVItem new];
        item.name = name;
        item.isDir = wq_stat(full, &st) && S_ISDIR(st.st_mode);
        [items addObject:item];
    }
    return items;
}

#pragma mark - All-apps index (one search box: name or bundle ID)

@interface WQMVAllAppsViewController : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithForbiddenDataPath:(NSString *_Nullable)forbidden
                               completion:(WQMVAppPickedBlock)completion;
@end

@implementation WQMVAllAppsViewController {
    NSString *_Nullable _forbiddenDataPath;
    WQMVAppPickedBlock _completion;
    NSArray<WQMVApp *> *_apps;
    NSArray<WQMVApp *> *_filtered;
    NSArray<WQMVApp *> *_resolved; // exact bundle-ID matches, merged into _filtered
    NSString *_Nullable _resolvedQuery;
    NSUInteger _resolveGeneration; // stale resolve results are dropped
    BOOL _loading;
    UILabel *_headerLabel;
}

- (instancetype)initWithForbiddenDataPath:(NSString *_Nullable)forbidden
                               completion:(WQMVAppPickedBlock)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _forbiddenDataPath = [forbidden copy];
        _completion = [completion copy];
        _apps = @[];
        _filtered = @[];
        _loading = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"全部 App";
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索名字或包ID";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    _headerLabel = [UILabel new];
    _headerLabel.textAlignment = NSTextAlignmentCenter;
    _headerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _headerLabel.textColor = [UIColor secondaryLabelColor];
    _headerLabel.frame = CGRectMake(0, 0, self.view.bounds.size.width, 36);
    self.tableView.tableHeaderView = _headerLabel;
    [self loadApps];
}

- (void)loadApps
{
    _loading = YES;
    _apps = @[];
    _filtered = @[];
    _resolved = @[];
    _resolvedQuery = nil;
    _resolveGeneration++; // drop any in-flight exact-ID resolve
    _headerLabel.text = @"正在加载全部 App…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WQMVApp *> *found = [[WQMVResolver allApps] sortedArrayUsingComparator:^NSComparisonResult(WQMVApp *a, WQMVApp *b) {
            NSComparisonResult byName = [a.title localizedCompare:b.title];
            if (byName != NSOrderedSame) return byName;
            NSComparisonResult byID = [a.bundleID compare:b.bundleID];
            if (byID != NSOrderedSame) return byID;
            return [a.containerPath compare:b.containerPath];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_loading = NO;
            strongSelf->_apps = found;
            [strongSelf applyCurrentQuery];
            [strongSelf maybeResolveExactID];
            strongSelf->_headerLabel.text = found.count ? @"" : @"没有找到应用";
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSString *)currentQuery
{
    NSString *text = self.navigationItem.searchController.searchBar.text ?: @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)applyCurrentQuery
{
    NSString *query = [self currentQuery];
    if (!query.length) {
        _filtered = _apps;
        return;
    }
    NSMutableArray<WQMVApp *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (WQMVApp *app in _apps) {
        BOOL directMatch = [app.title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [app.bundleID rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
        // Alias: "wechat" and 微信 mean each other, so searching either
        // finds apps named with the other (an English "WeChat" display
        // name contains no 微信, and no WeChat bundle ID says wechat).
        BOOL aliasMatch = ([query rangeOfString:@"wechat" options:NSCaseInsensitiveSearch].location != NSNotFound &&
                           [app.title containsString:@"微信"]) ||
                          ([query containsString:@"微信"] &&
                           [app.title rangeOfString:@"wechat" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (directMatch || aliasMatch) {
            [out addObject:app];
            [seen addObject:app.containerPath];
        }
    }
    // Exact bundle-ID matches resolved directly: they show even when the
    // enumeration missed the app or its name is unreadable.
    if ([query isEqualToString:_resolvedQuery]) {
        for (WQMVApp *app in _resolved) {
            if (![seen containsObject:app.containerPath]) {
                [out addObject:app];
                [seen addObject:app.containerPath];
            }
        }
    }
    _filtered = out;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    (void)searchController;
    if (_loading) return;
    [self applyCurrentQuery];
    [self.tableView reloadData];
    [self maybeResolveExactID];
}

// One search box serves both: substring matches in applyCurrentQuery,
// plus an exact bundle-ID resolve for text that looks like a bundle ID.
- (void)maybeResolveExactID
{
    NSString *query = [self currentQuery];
    if (!query.length || [query rangeOfString:@"."].location == NSNotFound) return;
    if ([query isEqualToString:_resolvedQuery]) return;
    _resolveGeneration++;
    NSUInteger generation = _resolveGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<WQMVApp *> *found = [WQMVResolver resolveBundleID:query];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_resolveGeneration != generation) return;
            strongSelf->_resolvedQuery = query;
            strongSelf->_resolved = found;
            [strongSelf applyCurrentQuery];
            [strongSelf.tableView reloadData];
        });
    });
}

- (void)retry
{
    wq_display_names_reset_miss();
    wq_enumerate_invalidate();
    [self loadApps];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    if (_loading) return 1;
    if (_filtered.count) return (NSInteger)_filtered.count;
    return [self currentQuery].length ? 1 : 2; // empty note, plus retry when not searching
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *reuseID = @"WQMVAllAppsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    if (_loading) {
        config.text = @"正在加载…";
        config.textProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration = config;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (!_filtered.count) {
        if (indexPath.row == 0) {
            config.text = @"未找到";
            config.secondaryText = [self currentQuery].length ? @"没有名字或包ID包含该文字的应用" : @"没有找到应用";
            config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
            cell.contentConfiguration = config;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            config.text = @"重试";
            config.textProperties.color = [UIColor systemBlueColor];
            cell.contentConfiguration = config;
        }
        return cell;
    }
    WQMVApp *app = _filtered[(NSUInteger)indexPath.row];
    config.image = wq_app_icon(app.bundleID) ?: [UIImage systemImageNamed:@"app.dashed"];
    config.imageProperties.maximumSize = CGSizeMake(38, 38);
    config.text = app.title;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    config.secondaryText = app.bundleID;
    config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    cell.contentConfiguration = config;
    BOOL official = WQMVIsOfficialWeChat(app.bundleID);
    cell.accessoryView = WQMVTagAccessoryView(official);
    cell.accessoryType = official ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading) return;
    if (!_filtered.count) {
        if (indexPath.row == 1 && ![self currentQuery].length) [self retry];
        return;
    }
    WQMVApp *app = _filtered[(NSUInteger)indexPath.row];
    if (_forbiddenDataPath.length && [app.documentsPath isEqualToString:_forbiddenDataPath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"不能选择同一个位置"
                                                                       message:@"来源和目标是同一个位置，请换一个。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    // Do NOT deactivate the search controller here: the completion pops
    // this view controller immediately, and the animated dismissal
    // transition races with the pop + folder-list push, swallowing the
    // push (tapping a search result returned to the list instead of
    // opening the folders). The search controller is torn down with
    // this view controller when it is popped.
    if (_completion) _completion(app);
}

// Long-press any app row (searching or not): pin it to the picker
// list (首页), after the auto-detected apps, in pin order. The pin
// is stored by bundle ID and survives relaunch.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    (void)tableView;
    (void)point;
    if (_loading || !_filtered.count) return nil;
    WQMVApp *app = _filtered[(NSUInteger)indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        (void)suggestedActions;
        UIAction *pin = [UIAction actionWithTitle:@"添加到首页" image:nil identifier:nil handler:^(__kindof UIAction *action) {
            (void)action;
            WQMVAddPinnedBundleID(app.bundleID);
        }];
        return [UIMenu menuWithTitle:@"" children:@[pin]];
    }];
}

@end

#pragma mark - Backup stamp list (restore source: 被覆盖的聊天记录)

// Lists the timestamped folders directly under the backup root,
// newest first. Plain rows, no tags: tapping one delivers it as the
// move source (a synthetic app whose Documents is the stamp folder
// itself), and the normal folder list takes over from there. A
// missing backup root is an empty list, never an error: browsing
// must not create the root (only displacement creates it).
@interface WQMVBackupStampListViewController : UITableViewController
- (instancetype)initWithBackupRootPath:(NSString *)rootPath
                 forbiddenDataPath:(NSString *_Nullable)forbidden
                        completion:(WQMVAppPickedBlock)completion;
@end

@implementation WQMVBackupStampListViewController {
    NSString *_rootPath;
    NSString *_Nullable _forbiddenDataPath;
    WQMVAppPickedBlock _completion;
    NSArray<NSString *> *_stamps;
    BOOL _loading;
    BOOL _failed;
    NSString *_Nullable _loadError;
    UILabel *_headerLabel;
}

- (instancetype)initWithBackupRootPath:(NSString *)rootPath
                 forbiddenDataPath:(NSString *_Nullable)forbidden
                        completion:(WQMVAppPickedBlock)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _rootPath = [rootPath copy];
        _forbiddenDataPath = [forbidden copy];
        _completion = [completion copy];
        _stamps = @[];
        _loading = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQMVBackupRootFolderName();
    _headerLabel = [UILabel new];
    _headerLabel.textAlignment = NSTextAlignmentCenter;
    _headerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _headerLabel.textColor = [UIColor secondaryLabelColor];
    _headerLabel.frame = CGRectMake(0, 0, self.view.bounds.size.width, 36);
    _headerLabel.text = @"正在加载…";
    self.tableView.tableHeaderView = _headerLabel;
    [self loadStamps];
}

- (void)loadStamps
{
    _loading = YES;
    _failed = NO;
    _loadError = nil;
    _stamps = @[];
    _headerLabel.text = @"正在加载…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    NSString *rootPath = _rootPath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSArray<WQMVItem *> *items = WQMVListDocuments(rootPath, &error);
        BOOL failed = NO;
        NSMutableArray<NSString *> *stamps = [NSMutableArray array];
        if (!items) {
            // A missing root is an empty list, not an error. A
            // present-but-unreadable root is a failure with a retry row.
            struct stat st;
            if (wq_stat(rootPath, &st) && S_ISDIR(st.st_mode)) failed = YES;
        } else {
            for (WQMVItem *item in items) {
                if (!item.isDir || ![item.name hasPrefix:@"备份"]) continue;
                // Proactive cleanup: an empty stamp folder is removed
                // silently and never shown; a folder that could not be
                // removed (non-empty, list/delete failure) stays listed.
                NSString *stampPath = [rootPath stringByAppendingPathComponent:item.name];
                if (!WQMVDeleteStampFolderIfEmpty(stampPath)) [stamps addObject:item.name];
            }
            // Zero-padded timestamps sort chronologically, so a
            // descending name sort is newest first.
            [stamps sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [b compare:a]; }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_loading = NO;
            strongSelf->_failed = failed;
            strongSelf->_loadError = error;
            strongSelf->_stamps = stamps;
            strongSelf->_headerLabel.text = failed
                ? (error.length ? error : @"未找到，请重试。")
                : [NSString stringWithFormat:@"%lu 个文件夹", (unsigned long)stamps.count];
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    if (_loading) return 1;
    if (_failed) return 1; // retry row
    return (NSInteger)_stamps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *reuseID = @"WQMVStampCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    if (_loading) {
        config.text = @"正在加载…";
        config.textProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration = config;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (_failed) {
        config.text = @"重试";
        config.textProperties.color = [UIColor systemBlueColor];
        cell.contentConfiguration = config;
        return cell;
    }
    config.image = [UIImage systemImageNamed:@"folder.fill"];
    config.imageProperties.tintColor = [UIColor systemBlueColor];
    config.imageProperties.maximumSize = CGSizeMake(26, 26);
    config.text = _stamps[(NSUInteger)indexPath.row];
    config.textProperties.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading) return;
    if (_failed) {
        [self loadStamps];
        return;
    }
    NSString *stampPath = [_rootPath stringByAppendingPathComponent:_stamps[(NSUInteger)indexPath.row]];
    if (_forbiddenDataPath.length && [stampPath isEqualToString:_forbiddenDataPath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"不能选择同一个位置"
                                                                       message:@"来源和目标是同一个位置，请换一个。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (_completion) _completion([WQMVApp backupStampAppWithPath:stampPath]);
}

@end

#pragma mark - Device list (send to another phone)

@interface WQMVDeviceListViewController : UITableViewController
- (instancetype)initWithCompletion:(WQMVAppPickedBlock)completion;
@end

@implementation WQMVDeviceListViewController {
    WQMVAppPickedBlock _completion;
    WQMVTransferBrowser *_Nullable _browser;
    NSArray<WQMVTransferPeer *> *_peers;
    UILabel *_headerLabel;
    BOOL _searching;
}

- (instancetype)initWithCompletion:(WQMVAppPickedBlock)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _completion = [completion copy];
        _peers = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"传到另一台手机";
    _headerLabel = [UILabel new];
    _headerLabel.textAlignment = NSTextAlignmentCenter;
    _headerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _headerLabel.textColor = [UIColor secondaryLabelColor];
    _headerLabel.numberOfLines = 0;
    _headerLabel.frame = CGRectMake(0, 0, self.view.bounds.size.width, 36);
    self.tableView.tableHeaderView = _headerLabel;
    UILabel *footnoteLabel = [UILabel new];
    footnoteLabel.text = @"两台设备需打开本应用、连上同一 WiFi";
    footnoteLabel.textAlignment = NSTextAlignmentCenter;
    footnoteLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footnoteLabel.textColor = [UIColor secondaryLabelColor];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 36)];
    footnoteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footnoteLabel];
    [NSLayoutConstraint activateConstraints:@[
        [footnoteLabel.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [footnoteLabel.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [footnoteLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:footer.leadingAnchor constant:16],
        [footnoteLabel.trailingAnchor constraintLessThanOrEqualToAnchor:footer.trailingAnchor constant:-16],
    ]];
    self.tableView.tableFooterView = footer;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _searching = YES;
    _peers = @[];
    [self updateHeader];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    _browser = [[WQMVTransferBrowser alloc] initWithUpdate:^(NSArray<WQMVTransferPeer *> *peers) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_peers = peers;
        [strongSelf updateHeader];
        [strongSelf.tableView reloadData];
    }];
    [_browser start];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_browser stop];
    _browser = nil;
    _searching = NO;
}

- (void)updateHeader
{
    if (_peers.count) {
        _headerLabel.text = @"";
    } else if (_searching) {
        _headerLabel.text = @"正在搜索附近的设备…";
    } else {
        _headerLabel.text = @"没有找到附近的设备";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return _peers.count ? (NSInteger)_peers.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *reuseID = @"WQMVDeviceCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    if (!_peers.count) {
        config.text = @"没有找到附近的设备";
        config.secondaryText = @"请确认另一台设备打开了本应用并连上同一 WiFi";
        config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration = config;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQMVTransferPeer *peer = _peers[(NSUInteger)indexPath.row];
    config.image = [UIImage systemImageNamed:@"iphone"];
    config.imageProperties.tintColor = [UIColor systemBlueColor];
    config.imageProperties.maximumSize = CGSizeMake(30, 30);
    config.text = peer.name;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    if (peer.model.length) {
        config.secondaryText = peer.model;
        config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    }
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_peers.count) return;
    WQMVTransferPeer *peer = _peers[(NSUInteger)indexPath.row];
    if (_completion) _completion([WQMVApp remoteDeviceAppWithPeer:peer]);
}

@end

#pragma mark - App picker (auto-detect WeChat)

typedef NS_ENUM(NSInteger, WQMVPickerState) {
    WQMVPickerStateLoading,
    WQMVPickerStateLoaded,
};

@interface WQMVAppPickerViewController : UITableViewController
- (instancetype)initForA:(BOOL)forA
    forbiddenDataPath:(NSString *_Nullable)forbidden
           completion:(WQMVAppPickedBlock)completion;
// Receive-destination picker: only the auto-detected WeChat apps and
// the 全部 App search row. No temp folder row (the temp folder is the
// other choice on the confirm screen), no backup row, no device row.
- (instancetype)initForReceiveDestinationWithCompletion:(WQMVAppPickedBlock)completion;
@end

@implementation WQMVAppPickerViewController {
    BOOL _forA;
    BOOL _receiveDestination;
    NSString *_Nullable _forbiddenDataPath;
    WQMVAppPickedBlock _completion;
    NSArray<WQMVApp *> *_apps;
    NSArray<WQMVApp *> *_allApps; // cached snapshot pins resolve against
    NSArray<WQMVApp *> *_pinnedApps; // pinned apps, in pin order, after _apps
    WQMVPickerState _state;
    UILabel *_headerLabel;
}

- (instancetype)initForA:(BOOL)forA
    forbiddenDataPath:(NSString *_Nullable)forbidden
           completion:(WQMVAppPickedBlock)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _forA = forA;
        _forbiddenDataPath = [forbidden copy];
        _completion = [completion copy];
        _apps = @[];
        _state = WQMVPickerStateLoading;
    }
    return self;
}

- (instancetype)initForReceiveDestinationWithCompletion:(WQMVAppPickedBlock)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _forA = NO;
        _receiveDestination = YES;
        _completion = [completion copy];
        _apps = @[];
        _state = WQMVPickerStateLoading;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _forA ? @"选择来源微信" : @"选择目标微信";
    _headerLabel = [UILabel new];
    _headerLabel.textAlignment = NSTextAlignmentCenter;
    _headerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _headerLabel.textColor = [UIColor secondaryLabelColor];
    _headerLabel.frame = CGRectMake(0, 0, self.view.bounds.size.width, 36);
    self.tableView.tableHeaderView = _headerLabel;
    [self loadApps];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // Pins may have changed in the 全部 App list (long-press
    // 添加到首页) while this picker was covered: re-resolve
    // against the cached snapshot, no rescan.
    if (_state == WQMVPickerStateLoaded) [self refreshPinnedApps];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    gScanProgressHandler = nil;
}

- (void)loadApps
{
    _state = WQMVPickerStateLoading;
    _apps = @[];
    _allApps = @[];
    _pinnedApps = @[];
    _headerLabel.text = @"正在查找微信…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    gScanProgressHandler = ^(double fraction, BOOL __unused finished) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_headerLabel.text = [NSString stringWithFormat:@"正在查找微信… %.0f%%", fraction * 100];
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // One scan feeds both lists: the auto-detected apps and the
        // pinned apps resolved against the same snapshot.
        NSArray<WQMVApp *> *all = [WQMVResolver allApps];
        NSArray<WQMVApp *> *found = [WQMVResolver detectWeChatAppsInApps:all];
        NSArray<WQMVApp *> *pinned = [WQMVResolver pinnedAppsInApps:all detected:found];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            gScanProgressHandler = nil;
            strongSelf->_state = WQMVPickerStateLoaded;
            strongSelf->_allApps = all;
            strongSelf->_apps = found;
            strongSelf->_pinnedApps = pinned;
            strongSelf->_headerLabel.text = [strongSelf idleHeaderText];
            [strongSelf.tableView reloadData];
        });
    });
}

- (NSString *)idleHeaderText
{
    if (_state == WQMVPickerStateLoading) return @"正在查找微信…";
    return [self displayedAppCount] ? @"" : @"没有找到名称含“微信”的应用";
}

- (NSInteger)displayedAppCount
{
    return (NSInteger)_apps.count + (NSInteger)_pinnedApps.count;
}

// Display order: auto-detected apps first (as listed today), then
// pinned apps in pin order. Pinned rows behave exactly like
// auto-detected rows when tapped.
- (WQMVApp *)appAtDisplayIndex:(NSInteger)index
{
    if (index < (NSInteger)_apps.count) return _apps[(NSUInteger)index];
    return _pinnedApps[(NSUInteger)index - _apps.count];
}

- (BOOL)isPinnedDisplayIndex:(NSInteger)index
{
    return index >= (NSInteger)_apps.count;
}

- (void)refreshPinnedApps
{
    _pinnedApps = [WQMVResolver pinnedAppsInApps:_allApps detected:_apps];
    _headerLabel.text = [self idleHeaderText];
    [self.tableView reloadData];
}

- (void)retry
{
    wq_display_names_reset_miss();
    wq_enumerate_invalidate();
    [self loadApps];
}

// The backup row (被覆盖的聊天记录) appears only in the source
// picker, immediately after the temp folder row: it is a restore
// source, never a move target. The device row (传到另一台手机)
// appears only in the target picker, as the top row. The
// receive-destination picker shows neither, and no temp folder row
// either: the temp folder is the other choice on the confirm screen.
- (BOOL)showsBackupRow
{
    return _forA;
}

- (BOOL)showsDeviceRow
{
    return !_forA && !_receiveDestination;
}

- (BOOL)showsTempRow
{
    return !_receiveDestination;
}

- (NSInteger)tempRowIndex
{
    return _forA ? 0 : 1;
}

- (NSInteger)leadingRowCount
{
    if (_receiveDestination) return 0; // apps only
    if (_forA) return 2; // temp folder row + backup row
    return 2; // device row + temp folder row
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) {
        NSInteger leading = [self leadingRowCount];
        if (_state == WQMVPickerStateLoading) return leading + 1; // leading rows + loading row
        NSInteger displayed = [self displayedAppCount];
        return leading + (displayed ? displayed : 2); // leading rows + apps, or leading rows + empty note + retry
    }
    return 1; // section 1: name/bundle-ID index
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *reuseID = @"WQMVPickerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    if (indexPath.section == 1) {
        config.text = @"按名字查找全部 App";
        config.textProperties.color = [UIColor systemBlueColor];
        config.image = [UIImage systemImageNamed:@"magnifyingglass"];
        config.imageProperties.tintColor = [UIColor systemBlueColor];
        config.imageProperties.maximumSize = CGSizeMake(26, 26);
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if ([self showsDeviceRow] && indexPath.row == 0) {
        // Device row (target picker only): send to another phone.
        config.image = [UIImage systemImageNamed:@"iphone"];
        config.imageProperties.tintColor = [UIColor systemBlueColor];
        config.imageProperties.maximumSize = CGSizeMake(38, 38);
        config.text = @"传到另一台手机";
        config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        config.secondaryText = @"通过局域网传到另一台设备";
        config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if ([self showsTempRow] && indexPath.row == [self tempRowIndex]) {
        // Temp folder row: an ordinary choice, same card row style.
        config.image = [UIImage systemImageNamed:@"folder.fill"];
        config.imageProperties.tintColor = [UIColor systemBlueColor];
        config.imageProperties.maximumSize = CGSizeMake(38, 38);
        config.text = @"聊天记录";
        config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        config.secondaryText = @"聊天记录临时存放";
        config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if ([self showsBackupRow] && indexPath.row == 1) {
        // Backup row (source picker only): the 被覆盖的聊天记录
        // folder, same card row style, no subtitle.
        config.image = [UIImage systemImageNamed:@"folder.fill"];
        config.imageProperties.tintColor = [UIColor systemBlueColor];
        config.imageProperties.maximumSize = CGSizeMake(38, 38);
        config.text = WQMVBackupRootFolderName();
        config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    NSInteger leading = [self leadingRowCount];
    if (_state == WQMVPickerStateLoading) {
        config.text = @"正在查找…";
        config.textProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration = config;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (![self displayedAppCount]) {
        if (indexPath.row == leading) {
            config.text = @"未找到";
            config.secondaryText = @"没有找到名称含“微信”的应用";
            config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
            cell.contentConfiguration = config;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            config.text = @"重试";
            config.textProperties.color = [UIColor systemBlueColor];
            cell.contentConfiguration = config;
        }
        return cell;
    }
    WQMVApp *app = [self appAtDisplayIndex:indexPath.row - leading];
    config.image = wq_app_icon(app.bundleID) ?: [UIImage systemImageNamed:@"app.dashed"];
    config.imageProperties.maximumSize = CGSizeMake(38, 38);
    config.text = app.title;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    config.secondaryText = app.bundleID;
    config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    cell.contentConfiguration = config;
    BOOL official = WQMVIsOfficialWeChat(app.bundleID);
    cell.accessoryView = WQMVTagAccessoryView(official);
    cell.accessoryType = official ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        __weak typeof(self) weakSelf = self;
        WQMVAllAppsViewController *index =
            [[WQMVAllAppsViewController alloc] initWithForbiddenDataPath:_forbiddenDataPath
                                                              completion:^(WQMVApp *app) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:NO];
            if (strongSelf->_completion) strongSelf->_completion(app);
        }];
        [self.navigationController pushViewController:index animated:YES];
        return;
    }
    if ([self showsDeviceRow] && indexPath.row == 0) {
        [self selectDeviceRow];
        return;
    }
    if ([self showsTempRow] && indexPath.row == [self tempRowIndex]) {
        [self selectTempFolderRow];
        return;
    }
    if ([self showsBackupRow] && indexPath.row == 1) {
        [self selectBackupRow];
        return;
    }
    if (_state == WQMVPickerStateLoading) return;
    NSInteger leading = [self leadingRowCount];
    if (![self displayedAppCount]) {
        if (indexPath.row == leading + 1) [self retry];
        return;
    }
    WQMVApp *app = [self appAtDisplayIndex:indexPath.row - leading];
    if (_forbiddenDataPath.length && [app.documentsPath isEqualToString:_forbiddenDataPath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"不能选择同一个位置"
                                                                       message:@"来源和目标是同一个位置，请换一个。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (_completion) _completion(app);
}

// Footnote under the 按名字查找全部 App row: bundle-ID search is
// the reliable path when an app's name doesn't show.
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 1) return @"如果没有显示 App，通过包 ID 进行搜索（不要使用名字搜索）";
    return nil;
}

// Long-press: pinned rows offer 移除. Leading rows, auto-detected
// apps, and the empty/retry rows have no menu.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    (void)tableView;
    (void)point;
    if (indexPath.section != 0 || _state == WQMVPickerStateLoading) return nil;
    NSInteger displayIndex = indexPath.row - [self leadingRowCount];
    if (![self isPinnedDisplayIndex:displayIndex]) return nil;
    if (displayIndex >= [self displayedAppCount]) return nil;
    WQMVApp *app = [self appAtDisplayIndex:displayIndex];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        (void)suggestedActions;
        UIAction *remove = [UIAction actionWithTitle:@"移除" image:nil identifier:nil handler:^(__kindof UIAction *action) {
            (void)action;
            WQMVRemovePinnedBundleID(app.bundleID);
            [weakSelf refreshPinnedApps];
        }];
        return [UIMenu menuWithTitle:@"" children:@[remove]];
    }];
}

- (void)selectTempFolderRow
{
    _headerLabel.text = @"正在准备聊天记录文件夹…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *tempPath = WQMVResolveTempFolderPath(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_headerLabel.text = [strongSelf idleHeaderText];
            if (!tempPath) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"打不开聊天记录文件夹"
                                                                               message:error.length ? error : @"未知错误"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:alert animated:YES completion:nil];
                return;
            }
            if (strongSelf->_forbiddenDataPath.length && [tempPath isEqualToString:strongSelf->_forbiddenDataPath]) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"不能选择同一个位置"
                                                                               message:@"来源和目标是同一个位置，请换一个。"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:alert animated:YES completion:nil];
                return;
            }
            if (strongSelf->_completion) strongSelf->_completion([WQMVApp tempFolderAppWithPath:tempPath]);
        });
    });
}

- (void)selectBackupRow
{
    _headerLabel.text = @"正在准备被覆盖的聊天记录…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Browsing only: the root path is resolved without creating
        // the folder (a missing root shows an empty stamp list).
        NSString *error = nil;
        NSString *rootPath = WQMVResolveBackupRootPathForBrowsing(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_headerLabel.text = [strongSelf idleHeaderText];
            if (!rootPath) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"打不开被覆盖的聊天记录"
                                                                               message:error.length ? error : @"未知错误"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:alert animated:YES completion:nil];
                return;
            }
            WQMVBackupStampListViewController *stamps =
                [[WQMVBackupStampListViewController alloc] initWithBackupRootPath:rootPath
                                                                forbiddenDataPath:strongSelf->_forbiddenDataPath
                                                                       completion:^(WQMVApp *app) {
                __strong typeof(self) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                if (strongSelf2->_completion) strongSelf2->_completion(app);
            }];
            [strongSelf.navigationController pushViewController:stamps animated:YES];
        });
    });
}

- (void)selectDeviceRow
{
    __weak typeof(self) weakSelf = self;
    WQMVDeviceListViewController *devices =
        [[WQMVDeviceListViewController alloc] initWithCompletion:^(WQMVApp *app) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_completion) strongSelf->_completion(app);
    }];
    [self.navigationController pushViewController:devices animated:YES];
}

@end

#pragma mark - Folder list

typedef NS_ENUM(NSInteger, WQMVFolderFilter) {
    WQMVFolderFilterHexOnly,
    WQMVFolderFilterAll,
};

@interface WQMVFolderListViewController : UITableViewController
- (instancetype)initWithApp:(WQMVApp *)app completion:(WQMVDoneBlock)completion;
@end

// Tag for the custom identified-row layout inside a reused cell's
// contentView, so it can be removed before the cell is reconfigured.
static const NSInteger kWQMVFolderCustomContentTag = 1977;

@implementation WQMVFolderListViewController {
    WQMVApp *_app;
    WQMVDoneBlock _completion;
    NSArray<WQMVItem *> *_allItems; // nil while loading, empty array on failure handled by _failed
    BOOL _failed;
    BOOL _loading;
    NSString *_Nullable _loadError;
    WQMVFolderFilter _filter;
    NSMutableSet<NSString *> *_selected;
    UISegmentedControl *_filterControl;
    UILabel *_headerLabel;
    UIBarButtonItem *_doneButton;
    NSUInteger _identifyGeneration; // stale identification results are dropped
}

- (instancetype)initWithApp:(WQMVApp *)app completion:(WQMVDoneBlock)completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _app = app;
        _completion = [completion copy];
        _selected = [NSMutableSet set];
        _filter = WQMVFolderFilterHexOnly;
        _loading = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = _app.title;
    _doneButton = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                   style:UIBarButtonItemStyleProminent
                                                  target:self
                                                  action:@selector(doneTapped)];
    _doneButton.enabled = NO;
    self.navigationItem.rightBarButtonItem = _doneButton;

    _filterControl = [[UISegmentedControl alloc] initWithItems:@[@"聊天记录文件夹", @"全部"]];
    _filterControl.selectedSegmentIndex = 0;
    [_filterControl addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];

    _headerLabel = [UILabel new];
    _headerLabel.textAlignment = NSTextAlignmentCenter;
    _headerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _headerLabel.textColor = [UIColor secondaryLabelColor];
    _headerLabel.text = @"正在加载…";

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 92)];
    _filterControl.translatesAutoresizingMaskIntoConstraints = NO;
    _headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_filterControl];
    [header addSubview:_headerLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_filterControl.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [_filterControl.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [_headerLabel.topAnchor constraintEqualToAnchor:_filterControl.bottomAnchor constant:8],
        [_headerLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [_headerLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
    ]];
    self.tableView.tableHeaderView = header;
    UILabel *footnoteLabel = [UILabel new];
    footnoteLabel.text = @"没有登录过的账号不会显示微信号";
    footnoteLabel.textAlignment = NSTextAlignmentCenter;
    footnoteLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footnoteLabel.textColor = [UIColor secondaryLabelColor];
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 36)];
    footnoteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footnoteLabel];
    [NSLayoutConstraint activateConstraints:@[
        [footnoteLabel.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [footnoteLabel.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        [footnoteLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:footer.leadingAnchor constant:16],
        [footnoteLabel.trailingAnchor constraintLessThanOrEqualToAnchor:footer.trailingAnchor constant:-16],
    ]];
    self.tableView.tableFooterView = footer;
    [self loadItems];
}

- (void)loadItems
{
    _loading = YES;
    _failed = NO;
    _loadError = nil;
    _allItems = nil;
    _identifyGeneration++;
    NSUInteger generation = _identifyGeneration;
    _headerLabel.text = @"正在加载…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    NSString *documents = _app.documentsPath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSArray<WQMVItem *> *items = WQMVListDocuments(documents, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_loading = NO;
            strongSelf->_failed = (items == nil);
            strongSelf->_loadError = error;
            strongSelf->_allItems = items ?: @[];
            [strongSelf updateHeaderAndDone];
            [strongSelf.tableView reloadData];
            [strongSelf startIdentificationWithGeneration:generation];
        });
    });
}

// Resolves folder identities off the main thread; rows show the hash
// immediately and update in place when an identity resolves. A failure
// for one folder never blocks the list or other folders.
- (void)startIdentificationWithGeneration:(NSUInteger)generation
{
    if (_failed || !_allItems.count) return;
    NSMutableArray<WQMVItem *> *targets = [NSMutableArray array];
    for (WQMVItem *item in _allItems) {
        if (item.isDir && WQMVIsHex32FolderName(item.name) && !item.identity) {
            [targets addObject:item];
        }
    }
    if (!targets.count) return;
    NSString *documents = _app.documentsPath;
    BOOL isBackupStamp = _app.isBackupStamp;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (WQMVItem *item in targets) {
            NSString *folderPath = [documents stringByAppendingPathComponent:item.name];
            // Folders under a backup stamp have
            // no LoginInfo in their own container: their custom ID is
            // resolved against the union of every WeChat container's
            // LoginInfo records.
            WQMVFolderIdentity *identity = isBackupStamp
                ? WQMVResolveBackupFolderIdentity(folderPath, item.name)
                : WQMVResolveFolderIdentity(documents, folderPath, item.name);
            if (!identity) continue;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_identifyGeneration != generation) return;
                if ([strongSelf->_allItems indexOfObjectIdenticalTo:item] == NSNotFound) return;
                item.identity = identity;
                NSArray<WQMVItem *> *visible = [strongSelf visibleItems];
                NSUInteger row = [visible indexOfObjectIdenticalTo:item];
                if (row == NSNotFound) return;
                if (row < (NSUInteger)[strongSelf.tableView numberOfRowsInSection:0]) {
                    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)row inSection:0];
                    [strongSelf.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
                }
            });
        }
    });
}

- (NSArray<WQMVItem *> *)visibleItems
{
    if (!_allItems) return @[];
    if (_filter == WQMVFolderFilterHexOnly) {
        NSMutableArray<WQMVItem *> *hex = [NSMutableArray array];
        for (WQMVItem *item in _allItems) {
            if (item.isDir && WQMVIsHex32FolderName(item.name)) [hex addObject:item];
        }
        [hex sortUsingComparator:^NSComparisonResult(WQMVItem *a, WQMVItem *b) { return [a.name compare:b.name]; }];
        return hex;
    }
    NSMutableArray<WQMVItem *> *sorted = [_allItems mutableCopy];
    [sorted sortUsingComparator:^NSComparisonResult(WQMVItem *a, WQMVItem *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        return [a.name compare:b.name];
    }];
    return sorted;
}

- (void)updateHeaderAndDone
{
    if (_loading) {
        _headerLabel.text = @"正在加载…";
    } else if (_failed) {
        _headerLabel.text = _loadError.length ? _loadError : @"未找到，请重试。";
    } else {
        NSArray<WQMVItem *> *visible = [self visibleItems];
        _headerLabel.text = [NSString stringWithFormat:@"%lu 个文件夹", (unsigned long)visible.count];
    }
    _doneButton.enabled = _selected.count > 0;
    self.navigationItem.prompt = _selected.count
        ? [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)_selected.count]
        : nil;
}

- (void)filterChanged
{
    _filter = _filterControl.selectedSegmentIndex == 0 ? WQMVFolderFilterHexOnly : WQMVFolderFilterAll;
    // Keep selections that are still visible; drop the rest.
    NSMutableSet<NSString *> *visibleNames = [NSMutableSet set];
    for (WQMVItem *item in [self visibleItems]) [visibleNames addObject:item.name];
    [_selected intersectSet:visibleNames];
    [self updateHeaderAndDone];
    [self.tableView reloadData];
}

- (void)doneTapped
{
    if (!_selected.count) return;
    NSArray<NSString *> *names = [[_selected allObjects] sortedArrayUsingSelector:@selector(compare:)];
    if (_completion) _completion(names);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    if (_loading) return 1;
    if (_failed) return 1; // retry row
    return (NSInteger)[self visibleItems].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *reuseID = @"WQMVFolderCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    // A reused cell may carry the custom identified-row layout from a
    // previous row; always remove it first, then configure afresh.
    [[cell.contentView viewWithTag:kWQMVFolderCustomContentTag] removeFromSuperview];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    if (_loading) {
        config.text = @"正在加载…";
        config.textProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration = config;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (_failed) {
        config.text = @"重试";
        config.textProperties.color = [UIColor systemBlueColor];
        cell.contentConfiguration = config;
        return cell;
    }
    WQMVItem *item = [self visibleItems][(NSUInteger)indexPath.row];
    config.image = [UIImage systemImageNamed:item.isDir ? @"folder.fill" : @"doc.fill"];
    config.imageProperties.tintColor = item.isDir ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    config.imageProperties.maximumSize = CGSizeMake(26, 26);
    WQMVFolderIdentity *identity = item.identity;
    if (item.isDir && WQMVIsHex32FolderName(item.name) && identity && [identity hasDisplayableIdentity]) {
        // Identified row: folder hash on the top line, one horizontal
        // row of identity tags below it — two FIXED EQUAL HALVES: the
        // green wxid pill on the left, the blue custom WeChat ID pill
        // on the right, 8pt apart. A missing value leaves its half
        // empty (an invisible spacer); the other pill never expands,
        // so both tags keep fixed positions. Tag text shrinks to fit
        // and is never truncated, so the full value always shows. No
        // subtitle: no other text is shown under the hash. The tags
        // are real pill views, so the row uses a custom layout
        // instead of the default content configuration. The row grows
        // vertically with the tag row: the container is pinned to the
        // text column top/bottom and centered with >= 6pt margins, so
        // the table view's automatic row height fits without clipping
        // or overlap.
        cell.contentConfiguration = nil;
        UIView *container = [[UIView alloc] init];
        container.tag = kWQMVFolderCustomContentTag;
        container.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:container];

        UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"folder.fill"]];
        iconView.tintColor = [UIColor systemBlueColor];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *hashLabel = [UILabel new];
        hashLabel.text = item.name;
        hashLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        hashLabel.textColor = [UIColor labelColor];
        hashLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [hashLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                   forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *tagRow = [[UIStackView alloc] init];
        tagRow.axis = UILayoutConstraintAxisHorizontal;
        tagRow.spacing = 8;
        tagRow.alignment = UIStackViewAlignmentFill;
        tagRow.distribution = UIStackViewDistributionFillEqually;
        NSString *wxidTag = [identity wxidTagText];
        NSString *wechatIDTag = [identity wechatIDTagText];
        [tagRow addArrangedSubview:wxidTag.length ? WQMVFolderTagViewWithTextAndColor(wxidTag, WQMVWeChatGreen()) : WQMVFolderTagSpacer()];
        [tagRow addArrangedSubview:wechatIDTag.length ? WQMVFolderTagViewWithTextAndColor(wechatIDTag, WQMVTagBlue()) : WQMVFolderTagSpacer()];

        NSMutableArray<UIView *> *textViews = [NSMutableArray arrayWithObject:hashLabel];
        if (wxidTag.length || wechatIDTag.length) [textViews addObject:tagRow];
        UIStackView *textColumn = [[UIStackView alloc] initWithArrangedSubviews:textViews];
        textColumn.axis = UILayoutConstraintAxisVertical;
        textColumn.spacing = 4;
        textColumn.alignment = UIStackViewAlignmentFill;
        textColumn.translatesAutoresizingMaskIntoConstraints = NO;

        [container addSubview:iconView];
        [container addSubview:textColumn];
        UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [container.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [container.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [container.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [container.topAnchor constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:6],
            [container.bottomAnchor constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-6],
            [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [iconView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [iconView.widthAnchor constraintEqualToConstant:26],
            [iconView.heightAnchor constraintEqualToConstant:26],
            [textColumn.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
            [textColumn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [textColumn.topAnchor constraintEqualToAnchor:container.topAnchor],
            [textColumn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        ]];
    } else {
        config.text = item.name;
        config.textProperties.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        cell.contentConfiguration = config;
    }
    cell.accessoryType = [_selected containsObject:item.name] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading) return;
    if (_failed) {
        [self loadItems];
        return;
    }
    WQMVItem *item = [self visibleItems][(NSUInteger)indexPath.row];
    if ([_selected containsObject:item.name]) [_selected removeObject:item.name];
    else [_selected addObject:item.name];
    [self updateHeaderAndDone];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - Progress

@interface WQMVProgressViewController : UIViewController
- (instancetype)initWithMessage:(NSString *)message;
// When set before presentation, a 取消 button appears under the message.
// Tapping it calls the handler once and disables the button.
@property (nonatomic, copy, nullable) void (^cancelHandler)(void);
// When set before presentation, a warning note stays visible under the
// message for the whole session. Transfer flows only; the local move
// flow leaves it unset.
@property (nonatomic, copy, nullable) NSString *footerNote;
// Thread-safe: may be called from the move loop on a background queue.
- (void)updateMessage:(NSString *)message;
@end

@implementation WQMVProgressViewController {
    NSString *_message;
    UILabel *_Nullable _label;
    UIButton *_Nullable _cancelButton;
    BOOL _cancelTapped;
}

- (instancetype)initWithMessage:(NSString *)message
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _message = [message copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.08;
    card.layer.shadowRadius = 12;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    [spinner startAnimating];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:spinner];
    UILabel *label = [UILabel new];
    label.text = _message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.textColor = [UIColor secondaryLabelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:label];
    _label = label;
    UILabel *noteLabel = nil;
    if (self.footerNote.length) {
        noteLabel = [UILabel new];
        noteLabel.text = self.footerNote;
        noteLabel.numberOfLines = 0;
        noteLabel.textAlignment = NSTextAlignmentCenter;
        noteLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        noteLabel.textColor = [UIColor systemOrangeColor];
        noteLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:noteLabel];
    }
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:40],
        [card.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-40],
        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:28],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:16],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
    ]];
    UIView *belowLabel = label;
    if (noteLabel) {
        [constraints addObjectsFromArray:@[
            [noteLabel.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:12],
            [noteLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
            [noteLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        ]];
        belowLabel = noteLabel;
    }
    if (self.cancelHandler) {
        UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *cancelConfig = [UIButtonConfiguration plainButtonConfiguration];
        cancelConfig.title = @"取消";
        cancelButton.configuration = cancelConfig;
        [cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:cancelButton];
        _cancelButton = cancelButton;
        [constraints addObjectsFromArray:@[
            [cancelButton.topAnchor constraintEqualToAnchor:belowLabel.bottomAnchor constant:12],
            [cancelButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
            [cancelButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
        ]];
    } else {
        [constraints addObject:[belowLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-28]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)cancelTapped
{
    if (_cancelTapped) return;
    _cancelTapped = YES;
    _cancelButton.enabled = NO;
    if (self.cancelHandler) self.cancelHandler();
}

- (void)updateMessage:(NSString *)message
{
    NSString *text = [message copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        _message = text;
        _label.text = text;
    });
}

@end

#pragma mark - Move result

@interface WQMVResultItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL moved;
@property (nonatomic, copy, nullable) NSString *failureReason;
@property (nonatomic, copy, nullable) NSString *backupName; // target's same-named folder was moved aside into this timestamped folder under 被覆盖的聊天记录
@property (nonatomic) NSUInteger skippedCount; // non-regular items skipped while sending (transfers only)
@property (nonatomic) BOOL transferred; // sent to another device (status wording says 已发送, not 已移动)
@end

@implementation WQMVResultItem
@end

// Status-confirmation screen shown after a move: big outcome header,
// summary counts, one scrollable row per folder, and a single 完成 button.
// When the move displaced folders, one small line per distinct timestamp
// folder used sits below the 完成 button, saying where the originals went.
// Presented only after the progress screen's dismissal animation has
// finished (see executeMove); presenting on top of an in-flight dismissal
// can be dropped by UIKit, leaving the user with no confirmation at all.
@interface WQMVStatusViewController : UITableViewController
- (instancetype)initWithResults:(NSArray<WQMVResultItem *> *)results
                     completion:(void (^)(void))completion;
- (instancetype)initWithResults:(NSArray<WQMVResultItem *> *)results
                      isTransfer:(BOOL)isTransfer
                      completion:(void (^)(void))completion;
@end

@implementation WQMVStatusViewController {
    NSArray<WQMVResultItem *> *_results;
    void (^_completion)(void);
    NSUInteger _movedCount;
    NSUInteger _backedUpCount;
    NSArray<NSString *> *_backupStampNames; // distinct stamp folders used, in first-use order
    BOOL _isTransfer;
}

- (instancetype)initWithResults:(NSArray<WQMVResultItem *> *)results
                     completion:(void (^)(void))completion
{
    return [self initWithResults:results isTransfer:NO completion:completion];
}

- (instancetype)initWithResults:(NSArray<WQMVResultItem *> *)results
                      isTransfer:(BOOL)isTransfer
                      completion:(void (^)(void))completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _results = [results copy];
        _completion = [completion copy];
        _isTransfer = isTransfer;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        NSMutableArray<NSString *> *stamps = [NSMutableArray array];
        for (WQMVResultItem *item in _results) {
            if (item.moved) _movedCount++;
            if (item.backupName.length) {
                _backedUpCount++;
                if (![stamps containsObject:item.backupName]) [stamps addObject:item.backupName];
            }
        }
        _backupStampNames = [stamps copy];
    }
    return self;
}

- (void)doneTapped
{
    if (_completion) _completion();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    // Section 3 (backup-location lines) exists only when the move
    // displaced at least one folder.
    return _backupStampNames.count ? 4 : 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 1) return (NSInteger)_results.count;
    if (section == 3) return (NSInteger)_backupStampNames.count;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        static NSString *headerReuseID = @"WQMVStatusHeaderCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:headerReuseID];
        UILabel *titleLabel = nil;
        UILabel *summaryLabel = nil;
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:headerReuseID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            titleLabel = [UILabel new];
            titleLabel.tag = 1;
            titleLabel.font = [UIFont boldSystemFontOfSize:26];
            titleLabel.textAlignment = NSTextAlignmentCenter;
            titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:titleLabel];
            summaryLabel = [UILabel new];
            summaryLabel.tag = 2;
            summaryLabel.numberOfLines = 0;
            summaryLabel.textAlignment = NSTextAlignmentCenter;
            summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            summaryLabel.textColor = [UIColor secondaryLabelColor];
            summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:summaryLabel];
            [NSLayoutConstraint activateConstraints:@[
                [titleLabel.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:20],
                [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [titleLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [summaryLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
                [summaryLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [summaryLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [summaryLabel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-20],
            ]];
        } else {
            titleLabel = [cell.contentView viewWithTag:1];
            summaryLabel = [cell.contentView viewWithTag:2];
        }
        NSUInteger failed = _results.count - _movedCount;
        if (_movedCount == _results.count) {
            titleLabel.text = @"全部成功";
            titleLabel.textColor = WQMVWeChatGreen();
        } else if (_movedCount > 0) {
            titleLabel.text = @"部分失败";
            titleLabel.textColor = [UIColor systemOrangeColor];
        } else {
            titleLabel.text = @"全部失败";
            titleLabel.textColor = [UIColor systemRedColor];
        }
        summaryLabel.text = _isTransfer
            ? [NSString stringWithFormat:@"已发送 %lu 个 · 失败 %lu 个 · 已移入备份 %lu 个",
               (unsigned long)_movedCount, (unsigned long)failed, (unsigned long)_backedUpCount]
            : [NSString stringWithFormat:@"已移动 %lu 个 · 失败 %lu 个 · 已移入备份 %lu 个",
               (unsigned long)_movedCount, (unsigned long)failed, (unsigned long)_backedUpCount];
        return cell;
    }
    if (indexPath.section == 3) {
        static NSString *backupReuseID = @"WQMVStatusBackupCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:backupReuseID];
        UILabel *label = nil;
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:backupReuseID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor clearColor];
            cell.contentView.backgroundColor = [UIColor clearColor];
            label = [UILabel new];
            label.tag = 1;
            label.numberOfLines = 0;
            label.textAlignment = NSTextAlignmentCenter;
            label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            label.textColor = [UIColor secondaryLabelColor];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:label];
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [label.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:4],
                [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-4],
            ]];
        } else {
            label = [cell.contentView viewWithTag:1];
        }
        label.text = [NSString stringWithFormat:@"原聊天记录文件已放置在 被覆盖的聊天记录/%@ 下",
                      _backupStampNames[(NSUInteger)indexPath.row]];
        return cell;
    }
    if (indexPath.section == 2) {
        static NSString *doneReuseID = @"WQMVStatusDoneCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:doneReuseID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:doneReuseID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor clearColor];
            cell.contentView.backgroundColor = [UIColor clearColor];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
            config.title = @"完成";
            config.baseBackgroundColor = WQMVWeChatGreen();
            config.baseForegroundColor = [UIColor whiteColor];
            config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
            config.contentInsets = NSDirectionalEdgeInsetsMake(14, 0, 14, 0);
            config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
                NSMutableDictionary *updated = [attributes mutableCopy];
                updated[NSFontAttributeName] = [UIFont boldSystemFontOfSize:17];
                return updated;
            };
            button.configuration = config;
            [button addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
            button.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:button];
            [NSLayoutConstraint activateConstraints:@[
                [button.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
                [button.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
                [button.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
                [button.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
                [button.heightAnchor constraintEqualToConstant:52],
            ]];
        }
        return cell;
    }
    static NSString *reuseID = @"WQMVStatusRowCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    WQMVResultItem *item = _results[(NSUInteger)indexPath.row];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = item.name;
    config.textProperties.adjustsFontSizeToFitWidth = YES;
    config.textProperties.numberOfLines = 1;
    config.secondaryTextProperties.numberOfLines = 0;
    NSMutableString *status = [NSMutableString string];
    if (item.moved) {
        config.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        config.imageProperties.tintColor = WQMVWeChatGreen();
        [status appendString:item.transferred ? @"已发送" : @"已移动"];
    } else {
        config.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
        config.imageProperties.tintColor = [UIColor systemRedColor];
        config.secondaryTextProperties.color = [UIColor systemRedColor];
        [status appendFormat:@"失败：%@", item.failureReason.length ? item.failureReason : @"未知错误"];
    }
    if (item.skippedCount > 0) {
        [status appendFormat:@" · 跳过 %lu 个", (unsigned long)item.skippedCount];
    }
    if (item.backupName.length) {
        [status appendFormat:@" · 原文件夹 → 被覆盖的聊天记录/%@", item.backupName];
    }
    config.secondaryText = status;
    cell.contentConfiguration = config;
    return cell;
}

@end

#pragma mark - Transfer receive store

// Single path component: no slash, not "." or "..". Used to guard
// staging-tree operations so they can never escape their parent.
static BOOL WQMVIsSinglePathComponent(NSString *name)
{
    return name.length && [name rangeOfString:@"/"].location == NSNotFound &&
           ![name isEqualToString:@"."] && ![name isEqualToString:@".."];
}

// Filesystem side of receiving: staging under .receiving in the Files
// container, installation into the destination the user chose for this
// transfer (a WeChat's Documents, or the 聊天记录 temp folder), with the
// same timestamped displacement as a local move. All methods are
// blocking and run on the receiver's background queue.
@interface WQMVTransferStore : NSObject <WQMVTransferReceiverStore>
// Set on the main thread when the user accepts a transfer, before the
// decision unblocks the receiver thread; read on the receiver's
// background queues from installStagedFolder:. Either a WeChat app
// (install into its Documents) or the temp folder (installDestinationApp
// nil + installDestinationIsTempFolder, resolved lazily per install:
// adopt the existing folder or create it). Cleared when the session
// ends, so a stale destination can never leak into a later transfer.
@property (nonatomic, strong, nullable) WQMVApp *installDestinationApp;
@property (nonatomic) BOOL installDestinationIsTempFolder;
@end

@implementation WQMVTransferStore {
    NSString *_Nullable _stagingRoot;
}

- (NSString *_Nullable)filesContainerPath
{
    NSArray<WQMVApp *> *found = [WQMVResolver resolveBundleID:WQMVTempHostBundleID()];
    return found.firstObject.containerPath;
}

- (NSString *)stagingTransferFolderName
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    return [NSString stringWithFormat:@"%@-%06x", [formatter stringFromDate:[NSDate date]],
            (unsigned int)(arc4random() & 0xFFFFFF)];
}

// Creates `path` when it does not already stat as a directory.
- (BOOL)ensureDirectory:(NSString *)path error:(NSString **)error
{
    struct stat st;
    if (wq_stat(path, &st) && S_ISDIR(st.st_mode)) return YES;
    NSString *createError = nil;
    if (wq_create_dir(path, &createError)) return YES;
    if (wq_stat(path, &st) && S_ISDIR(st.st_mode)) return YES;
    if (error) *error = createError.length ? createError : @"建不了文件夹";
    return NO;
}

- (NSString *_Nullable)createStagingDirectoryWithError:(NSString **)error
{
    NSString *containerPath = [self filesContainerPath];
    if (!containerPath.length) {
        if (error) *error = @"找不到文件应用（com.apple.DocumentsApp）的容器。";
        return nil;
    }
    NSString *receivingRoot = [containerPath stringByAppendingPathComponent:WQMVReceivingFolderName()];
    NSString *ensureError = nil;
    if (![self ensureDirectory:receivingRoot error:&ensureError]) {
        if (error) *error = ensureError;
        return nil;
    }
    NSString *stagingRoot = [receivingRoot stringByAppendingPathComponent:[self stagingTransferFolderName]];
    if (![self ensureDirectory:stagingRoot error:&ensureError]) {
        if (error) *error = ensureError;
        return nil;
    }
    _stagingRoot = stagingRoot;
    return stagingRoot;
}

- (BOOL)createStagingDirectoriesForRelativePath:(NSString *)relativePath error:(NSString **)error
{
    if (!_stagingRoot.length) {
        if (error) *error = @"暂存文件夹不存在";
        return NO;
    }
    NSString *current = _stagingRoot;
    for (NSString *part in [relativePath componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        current = [current stringByAppendingPathComponent:part];
        NSString *ensureError = nil;
        if (![self ensureDirectory:current error:&ensureError]) {
            if (error) *error = ensureError;
            return NO;
        }
    }
    return YES;
}

- (BOOL)storeReceivedFileFromTempPath:(NSString *)tempPath
                         relativePath:(NSString *)relativePath
                                error:(NSString **)error
{
    if (!_stagingRoot.length) {
        if (error) *error = @"暂存文件夹不存在";
        return NO;
    }
    NSString *destPath = [_stagingRoot stringByAppendingPathComponent:relativePath];
    NSString *parentRelPath = [relativePath stringByDeletingLastPathComponent];
    if (parentRelPath.length && ![parentRelPath isEqualToString:@"."]) {
        NSString *dirError = nil;
        if (![self createStagingDirectoriesForRelativePath:parentRelPath error:&dirError]) {
            if (error) *error = dirError;
            return NO;
        }
    }
    NSString *createError = nil;
    if (!wq_create_file_from(destPath, tempPath, &createError)) {
        if (error) *error = createError.length ? createError : @"保存文件失败";
        return NO;
    }
    return YES;
}

- (NSDictionary *)installStagedFolder:(NSString *)folderName
{
    NSDictionary *(^failure)(NSString *) = ^NSDictionary *(NSString *reason) {
        return @{@"ok": @NO, @"reason": reason, @"backupName": [NSNull null]};
    };
    if (!_stagingRoot.length) return failure(@"暂存文件夹不存在");
    NSString *stagedPath = [_stagingRoot stringByAppendingPathComponent:folderName];
    struct stat st;
    if (!wq_stat(stagedPath, &st) || !S_ISDIR(st.st_mode)) return failure(@"收到的文件夹不完整");
    NSString *destRoot = nil;
    if (self.installDestinationIsTempFolder) {
        NSString *resolveError = nil;
        destRoot = WQMVResolveTempFolderPath(&resolveError);
        if (!destRoot) return failure(resolveError.length ? resolveError : @"打不开聊天记录文件夹");
    } else {
        destRoot = self.installDestinationApp.documentsPath;
        if (!destRoot.length) return failure(@"没有选择接收位置");
    }
    NSString *destPath = [destRoot stringByAppendingPathComponent:folderName];
    NSString *backupName = nil;
    if (wq_stat(destPath, &st)) {
        // Same conflict rule as a local move: the existing folder is
        // moved aside into a timestamped folder under 被覆盖的聊天记录.
        NSString *rootError = nil;
        NSString *backupRootPath = WQMVResolveBackupRootPath(&rootError);
        if (!backupRootPath) return failure(rootError.length ? rootError : @"打不开备份位置");
        NSString *stampName = WQMVBackupTimestampFolderName();
        NSString *stampDir = [backupRootPath stringByAppendingPathComponent:stampName];
        NSString *stampError = nil;
        if (![self ensureDirectory:stampDir error:&stampError]) {
            return failure([NSString stringWithFormat:@"建不了备份文件夹“%@”（%@）",
                            stampName, stampError.length ? stampError : @"未知错误"]);
        }
        if (wq_stat([stampDir stringByAppendingPathComponent:folderName], &st)) {
            return failure([NSString stringWithFormat:@"备份文件夹“%@”里已有同名文件夹", stampName]);
        }
        NSString *displaceError = nil;
        if (!wq_move(destPath, stampDir, &displaceError)) {
            return failure([NSString stringWithFormat:@"移走原文件夹失败（%@）",
                            displaceError.length ? displaceError : @"未知错误"]);
        }
        backupName = stampName;
    }
    NSString *moveError = nil;
    if (!wq_move(stagedPath, destRoot, &moveError)) {
        return failure([NSString stringWithFormat:@"移入接收位置失败（%@）",
                        moveError.length ? moveError : @"未知错误"]);
    }
    return @{@"ok": @YES, @"reason": [NSNull null],
             @"backupName": backupName ?: [NSNull null]};
}

- (void)removeStagingTree:(NSString *)path
{
    // Purge removes every item inside (recursively, without following
    // links); the emptied folder itself is then removed. Only ever
    // called with paths under the staging root.
    unsigned long long freed = 0;
    (void)wq_purge_contents(path, &freed);
    NSString *deleteError = nil;
    (void)wq_delete(path, &deleteError);
}

- (void)discardStagedFolder:(NSString *)folderName
{
    if (!_stagingRoot.length) return;
    if (!WQMVIsSinglePathComponent(folderName)) return;
    [self removeStagingTree:[_stagingRoot stringByAppendingPathComponent:folderName]];
}

- (void)finishStaging
{
    if (_stagingRoot.length) {
        [self removeStagingTree:_stagingRoot];
        _stagingRoot = nil;
    }
}

- (void)cleanupStaleStaging
{
    NSString *containerPath = [self filesContainerPath];
    if (!containerPath.length) return;
    NSString *receivingRoot = [containerPath stringByAppendingPathComponent:WQMVReceivingFolderName()];
    struct stat st;
    if (!wq_stat(receivingRoot, &st) || !S_ISDIR(st.st_mode)) return;
    NSString *listError = nil;
    NSArray<NSString *> *children = wq_list(receivingRoot, &listError);
    if (!children) return;
    for (NSString *child in children) {
        if ([child isEqualToString:@"."] || [child isEqualToString:@".."]) continue;
        if (!WQMVIsSinglePathComponent(child)) continue;
        [self removeStagingTree:[receivingRoot stringByAppendingPathComponent:child]];
    }
}

@end

#pragma mark - Main screen

// One pending incoming transfer: the request, its exactly-once decision,
// and the choice UI currently on screen (choice alert, note alert, or
// destination picker). The 180s timeout holds this object strongly, so
// the decision is delivered even if the main view controller is gone;
// the receiver thread blocks on the decision, so it must always fire.
@interface WQMVTransferChoiceState : NSObject
@property (nonatomic, strong) WQMVTransferRequest *request;
@property (nonatomic, copy) WQMVTransferDecisionBlock decision;
@property (nonatomic) BOOL decided;
@property (nonatomic, weak, nullable) UIViewController *presentedUI;
- (void)decide:(BOOL)accept; // exactly once; later calls are ignored
@end

@implementation WQMVTransferChoiceState
- (void)decide:(BOOL)accept
{
    if (_decided) return;
    _decided = YES;
    if (_decision) _decision(accept);
}
@end

// Defined in the update-check section below; the footer's 检查更新 entry
// calls it.
static void WQMVCheckForUpdateManually(void);

@interface WQMVMainViewController : UITableViewController
@end

@implementation WQMVMainViewController {
    WQMVApp *_Nullable _appA;
    WQMVApp *_Nullable _appB;
    NSArray<NSString *> *_selectedFolders;
    BOOL _appGroupChecked;
    UIButton *_Nullable _moveButton;
    WQMVTransferChoiceState *_Nullable _pendingTransferChoice;
    NSString *_Nullable _receiveDestinationLabel;
    WQMVTransferStore *_transferStore;
    WQMVTransferReceiver *_transferReceiver;
    WQMVTransferSender *_Nullable _transferSender; // held for the whole send; the sender only weakly references itself on its queue
    BOOL _sending;
    BOOL _receiving;
    WQMVProgressViewController *_Nullable _receiveProgress;
}

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _selectedFolders = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"微信迁移";
    [self installBottomFooter];
    [self checkAppGroupOnce];
    [self installTransferReceiver];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(transferWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(transferDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)transferWillEnterForeground
{
    [_transferReceiver start];
}

- (void)transferDidEnterBackground
{
    // Backgrounding cancels an in-flight transfer: receiving only
    // works while the app is in the foreground.
    [_transferReceiver stop];
}

// Footer icon links (GitHub / Telegram): 44pt tap targets showing the
// brand marks as template images, tinted with the label color so they
// read in both light and dark mode. The destination URLs live only here,
// never as visible text in the footer.
- (UIButton *)footerIconButtonWithImageName:(NSString *)imageName
                        accessibilityLabel:(NSString *)accessibilityLabel
                                    action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImage *image = [[UIImage imageNamed:imageName]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    button.accessibilityLabel = accessibilityLabel;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)openFooterGitHubLink
{
    [self openFooterLink:@"https://github.com/xqwzka/wq-move"];
}

- (void)openFooterTelegramLink
{
    [self openFooterLink:@"https://t.me/sry_ios"];
}

- (void)openFooterLink:(NSString *)urlString
{
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

// Footer pinned to the bottom of the screen, horizontally centered. A
// tableFooterView sits right under the content when the content is short,
// so the footer is a subview of the table view pinned to the frame/safe-area
// guides so it stays at the screen bottom, and the table gets a matching
// bottom inset so content never hides under it.
//
// Centering: the footer is a UITextView showing an attributed string
// (for the tappable links), and UITextView takes line alignment from
// the attributed string's paragraph style. Setting textAlignment
// BEFORE assigning attributedText does nothing: the assignment
// replaces the text storage with a string that had no paragraph
// style, so lines fall back to default left alignment. The centered
// paragraph style must be part of the attributed string itself.
//
// Below the text lines, a centered row of GitHub/Telegram icon buttons
// provides the project and TG jumps; no URL text is shown in the footer.
// Below the icon row, a tappable 检查更新 line runs a manual update check.
- (void)installBottomFooter
{
    UIView *footer = [UIView new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    UITextView *credits = [UITextView new];
    credits.translatesAutoresizingMaskIntoConstraints = NO;
    credits.editable = NO;
    credits.scrollEnabled = NO;
    credits.backgroundColor = [UIColor clearColor];
    credits.textContainerInset = UIEdgeInsetsZero;
    credits.textContainer.lineFragmentPadding = 0;
    credits.textAlignment = NSTextAlignmentCenter;
    NSMutableParagraphStyle *centeredStyle = [NSMutableParagraphStyle new];
    centeredStyle.alignment = NSTextAlignmentCenter;
    NSDictionary *baseAttributes = @{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
        NSParagraphStyleAttributeName: centeredStyle,
    };
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithString:@"基于 kolbicz 的 WQFiles 开发\n仅支持 iOS 26.0–26.7.2 / 27.x"
        attributes:baseAttributes];
    [text addAttribute:NSLinkAttributeName value:@"https://github.com/kolbicz"
                 range:[text.string rangeOfString:@"kolbicz"]];
    [text addAttribute:NSLinkAttributeName value:@"https://github.com/kolbicz/WQFiles"
                 range:[text.string rangeOfString:@"WQFiles"]];
    credits.attributedText = text;
    // Re-assert after the assignment; the paragraph style above is
    // what actually centers the lines.
    credits.textAlignment = NSTextAlignmentCenter;
    [footer addSubview:credits];
    // Icon row: GitHub + Telegram marks as the jumps to the project repo
    // and TG. No URL text is shown in the footer.
    UIStackView *iconRow = [UIStackView new];
    iconRow.translatesAutoresizingMaskIntoConstraints = NO;
    iconRow.axis = UILayoutConstraintAxisHorizontal;
    iconRow.alignment = UIStackViewAlignmentCenter;
    iconRow.distribution = UIStackViewDistributionEqualSpacing;
    iconRow.spacing = 28;
    UIButton *gitHubButton = [self footerIconButtonWithImageName:@"FooterGitHub"
                                             accessibilityLabel:@"GitHub 项目地址"
                                                         action:@selector(openFooterGitHubLink)];
    UIButton *telegramButton = [self footerIconButtonWithImageName:@"FooterTelegram"
                                                accessibilityLabel:@"Telegram"
                                                            action:@selector(openFooterTelegramLink)];
    [iconRow addArrangedSubview:gitHubButton];
    [iconRow addArrangedSubview:telegramButton];
    [footer addSubview:iconRow];
    UIButton *updateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    updateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [updateButton setTitle:@"检查更新" forState:UIControlStateNormal];
    updateButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    [updateButton addTarget:self action:@selector(checkUpdateTapped) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:updateButton];
    [NSLayoutConstraint activateConstraints:@[
        [credits.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16],
        [credits.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16],
        [credits.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
        [iconRow.topAnchor constraintEqualToAnchor:credits.bottomAnchor constant:2],
        [iconRow.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [updateButton.topAnchor constraintEqualToAnchor:iconRow.bottomAnchor constant:2],
        [updateButton.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [updateButton.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-8],
        [gitHubButton.widthAnchor constraintEqualToConstant:44],
        [gitHubButton.heightAnchor constraintEqualToConstant:44],
        [telegramButton.widthAnchor constraintEqualToConstant:44],
        [telegramButton.heightAnchor constraintEqualToConstant:44],
    ]];
    [self.tableView addSubview:footer];
    UILayoutGuide *frame = self.tableView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:frame.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:frame.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.tableView.safeAreaLayoutGuide.bottomAnchor],
        [footer.heightAnchor constraintEqualToConstant:140],
    ]];
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 140, 0);
    self.tableView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, 140, 0);
}

- (void)checkUpdateTapped
{
    WQMVCheckForUpdateManually();
}

- (void)updateMoveButton
{
    if (!_moveButton) return;
    BOOL ready = [self readyToMove];
    _moveButton.enabled = ready;
    UIButtonConfiguration *config = _moveButton.configuration;
    if (!config) return;
    config.baseBackgroundColor = ready ? WQMVWeChatGreen() : [UIColor systemGray4Color];
    config.baseForegroundColor = ready ? [UIColor whiteColor] : [UIColor secondaryLabelColor];
    _moveButton.configuration = config;
}

- (void)checkAppGroupOnce
{
    if (_appGroupChecked) return;
    _appGroupChecked = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *group = wq_app_group();
        if (group.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"没有 App Group"
                                                                           message:@"签名时没有保留 App Group 权限，本应用无法读取其他应用的数据。请用 AltStore 或 SideStore 以 Apple ID 重新签名（会自动创建 App Group）；Sideloadly 签名没有 App Group，不能用。"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (BOOL)readyToMove
{
    return _appA && _appB && _selectedFolders.count > 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? 2 : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 1) {
        static NSString *moveReuseID = @"WQMVMoveCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:moveReuseID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:moveReuseID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor clearColor];
            cell.contentView.backgroundColor = [UIColor clearColor];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
            config.title = @"开始移动";
            config.baseBackgroundColor = WQMVWeChatGreen();
            config.baseForegroundColor = [UIColor whiteColor];
            config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
            config.contentInsets = NSDirectionalEdgeInsetsMake(14, 0, 14, 0);
            config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
                NSMutableDictionary *updated = [attributes mutableCopy];
                updated[NSFontAttributeName] = [UIFont boldSystemFontOfSize:17];
                return updated;
            };
            button.configuration = config;
            [button addTarget:self action:@selector(startMoveTapped) forControlEvents:UIControlEventTouchUpInside];
            button.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:button];
            [NSLayoutConstraint activateConstraints:@[
                [button.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
                [button.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
                [button.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
                [button.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
                [button.heightAnchor constraintEqualToConstant:52],
            ]];
            _moveButton = button;
        }
        [self updateMoveButton];
        return cell;
    }
    static NSString *reuseID = @"WQMVMainCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    cell.accessoryView = nil;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.imageProperties.maximumSize = CGSizeMake(30, 30);
    config.imageProperties.tintColor = WQMVWeChatGreen();
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    config.secondaryTextProperties.color = [UIColor secondaryLabelColor];
    WQMVApp *selectedApp = nil;
    if (indexPath.row == 0) {
        config.text = @"需要迁移的微信";
        config.image = [UIImage systemImageNamed:@"bubble.left.and.bubble.right.fill"];
        selectedApp = _appA;
        if (_appA) {
            if (_appA.isTempFolder) {
                config.secondaryText = _selectedFolders.count
                    ? [NSString stringWithFormat:@"聊天记录 · 已选 %lu 个文件夹", (unsigned long)_selectedFolders.count]
                    : @"聊天记录 · 未选文件夹";
            } else if (_appA.isBackupStamp) {
                config.secondaryText = _selectedFolders.count
                    ? [NSString stringWithFormat:@"被覆盖的聊天记录 · %@ · 已选 %lu 个文件夹", _appA.title, (unsigned long)_selectedFolders.count]
                    : [NSString stringWithFormat:@"被覆盖的聊天记录 · %@ · 未选文件夹", _appA.title];
            } else {
                config.secondaryText = _selectedFolders.count
                    ? [NSString stringWithFormat:@"%@ · %@ · 已选 %lu 个文件夹", _appA.title, _appA.bundleID, (unsigned long)_selectedFolders.count]
                    : [NSString stringWithFormat:@"%@ · %@ · 未选文件夹", _appA.title, _appA.bundleID];
            }
        } else {
            config.secondaryText = @"请选择";
        }
    } else {
        config.text = @"移动到";
        config.image = [UIImage systemImageNamed:@"tray.and.arrow.down.fill"];
        selectedApp = _appB;
        if (_appB) {
            if (_appB.isRemoteDevice) {
                config.secondaryText = [NSString stringWithFormat:@"传到：%@", _appB.title];
            } else if (_appB.isTempFolder) {
                config.secondaryText = @"聊天记录";
            } else {
                config.secondaryText = [NSString stringWithFormat:@"%@ · %@", _appB.title, _appB.bundleID];
            }
        } else {
            config.secondaryText = @"请选择";
        }
    }
    cell.contentConfiguration = config;
    BOOL official = selectedApp && WQMVIsOfficialWeChat(selectedApp.bundleID);
    cell.accessoryView = WQMVTagAccessoryView(official);
    cell.accessoryType = official ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        [self startMoveTapped];
        return;
    }
    __weak typeof(self) weakSelf = self;
    if (indexPath.row == 0) {
        WQMVAppPickerViewController *picker =
            [[WQMVAppPickerViewController alloc] initForA:YES
                                      forbiddenDataPath:_appB.documentsPath
                                             completion:^(WQMVApp *app) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            WQMVFolderListViewController *folders =
                [[WQMVFolderListViewController alloc] initWithApp:app completion:^(NSArray<NSString *> *names) {
                __strong typeof(self) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                strongSelf2->_appA = app;
                strongSelf2->_selectedFolders = names;
                [strongSelf2.navigationController popToRootViewControllerAnimated:YES];
                [strongSelf2.tableView reloadData];
            }];
            [strongSelf.navigationController pushViewController:folders animated:YES];
        }];
        [self.navigationController pushViewController:picker animated:YES];
    } else {
        WQMVAppPickerViewController *picker =
            [[WQMVAppPickerViewController alloc] initForA:NO
                                      forbiddenDataPath:_appA.documentsPath
                                             completion:^(WQMVApp *app) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_appB = app;
            [strongSelf.navigationController popToRootViewControllerAnimated:YES];
            [strongSelf.tableView reloadData];
        }];
        [self.navigationController pushViewController:picker animated:YES];
    }
}

- (void)startMoveTapped
{
    if (![self readyToMove]) return;
    BOOL isRemote = _appB.isRemoteDevice;
    if (!isRemote && [_appA.documentsPath isEqualToString:_appB.documentsPath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"不能移动到同一个位置"
                                                                       message:@"来源和目标是同一个位置，请换一个。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (isRemote) {
        // The transfer branch never checks the target: A cannot know
        // B's state. The dialog stays exactly as before.
        [self presentMoveConfirmWithConflicts:nil];
        return;
    }
    // Local move: check which selected names already exist in the
    // target, off the main thread (escape-layer calls block), so
    // conflicting names can be flagged in red in the dialog.
    NSString *dstDir = _appB.documentsPath;
    NSArray<NSString *> *names = [_selectedFolders copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableSet<NSString *> *conflicts = [NSMutableSet set];
        struct stat st;
        for (NSString *name in names) {
            // Same existence check the move itself uses: if the
            // destination path exists, the move displaces it first,
            // so the warning matches what will actually happen.
            if (wq_stat([dstDir stringByAppendingPathComponent:name], &st)) [conflicts addObject:name];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf presentMoveConfirmWithConflicts:conflicts];
        });
    });
}

// Conflicts is nil for the transfer branch (never checked) and a
// (possibly empty) set of already-existing names for local moves.
// With no conflicts the dialog is exactly as before; with conflicts
// the conflicting names and the added notice render red, and all
// other text stays the default color.
- (void)presentMoveConfirmWithConflicts:(NSSet<NSString *> *_Nullable)conflicts
{
    BOOL isRemote = _appB.isRemoteDevice;
    NSString *srcDesc = _appA.isTempFolder
        ? @"聊天记录"
        : _appA.isBackupStamp
        ? [NSString stringWithFormat:@"被覆盖的聊天记录/%@", _appA.title]
        : [NSString stringWithFormat:@"%@（%@）", _appA.title, _appA.bundleID];
    NSString *dstDesc = isRemote
        ? [NSString stringWithFormat:@"另一台手机（%@）", _appB.title]
        : _appB.isTempFolder
        ? @"聊天记录"
        : [NSString stringWithFormat:@"%@（%@）的 Documents", _appB.title, _appB.bundleID];
    NSMutableString *message = [NSMutableString string];
    [message appendFormat:@"从：%@\n", srcDesc];
    [message appendString:@"文件夹：\n"];
    NSUInteger shown = MIN(_selectedFolders.count, (NSUInteger)8);
    for (NSUInteger i = 0; i < shown; i++) [message appendFormat:@"· %@\n", _selectedFolders[i]];
    if (_selectedFolders.count > shown) {
        [message appendFormat:@"· 等共 %lu 个\n", (unsigned long)_selectedFolders.count];
    }
    [message appendFormat:@"到：%@\n\n", dstDesc];
    if (isRemote) {
        [message appendString:@"发送的是副本，本机原文件夹不动。对方选择接收位置（直接存入微信，或先存到聊天记录临时存放）后开始传。\n\n传输中请两台手机都保持本应用打开。开始前请两台手机都关闭微信（从后台划掉），否则传输可能不完整。"];
    } else {
        [message appendString:@"如果目标里已有同名文件夹，会先把它移入文件应用里的“被覆盖的聊天记录”文件夹（按时间分文件夹存放，删本应用不消失），再移入。\n\n移动前请把微信从后台划掉，否则移动可能不完整。"];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:isRemote ? @"开始传输？" : @"开始移动？"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (!isRemote && conflicts.count) {
        NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:message];
        for (NSString *name in conflicts) {
            NSString *line = [NSString stringWithFormat:@"· %@\n", name];
            NSRange range = [message rangeOfString:line];
            if (range.location != NSNotFound) {
                [styled addAttribute:NSForegroundColorAttributeName value:[UIColor systemRedColor] range:range];
            }
        }
        NSString *notice = @"\n\n移动后原聊天记录将存放在文件应用里的“被覆盖的聊天记录”文件夹里。";
        NSMutableAttributedString *noticeStyled = [[NSMutableAttributedString alloc] initWithString:notice];
        [noticeStyled addAttribute:NSForegroundColorAttributeName value:[UIColor systemRedColor] range:NSMakeRange(0, notice.length)];
        [styled appendAttributedString:noticeStyled];
        [alert setValue:styled forKey:@"attributedMessage"];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:isRemote ? @"开始传输" : @"开始移动" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (isRemote) [strongSelf executeTransfer];
        else [strongSelf executeMove];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)executeMove
{
    WQMVApp *srcApp = _appA;
    WQMVApp *dstApp = _appB;
    NSArray<NSString *> *names = _selectedFolders;
    WQMVProgressViewController *progress = [[WQMVProgressViewController alloc] initWithMessage:@"正在移动…"];
    [self presentViewController:progress animated:YES completion:nil];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *dstDir = dstApp.documentsPath;
        NSMutableArray<WQMVResultItem *> *results = [NSMutableArray array];
        NSString *backupRootPath = nil; // resolved lazily on the first conflict, reused for the batch
        NSUInteger total = names.count;
        for (NSUInteger idx = 0; idx < total; idx++) {
            NSString *name = names[idx];
            [progress updateMessage:[NSString stringWithFormat:@"正在移动第 %lu/%lu 个\n%@",
                                     (unsigned long)(idx + 1), (unsigned long)total,
                                     WQMVTruncatedFolderName(name)]];
            WQMVResultItem *item = [WQMVResultItem new];
            item.name = name;
            NSString *srcPath = [srcApp.documentsPath stringByAppendingPathComponent:name];
            NSString *dstPath = [dstDir stringByAppendingPathComponent:name];
            struct stat st;
            if (wq_stat(dstPath, &st)) {
                // Same-named item already in the target: move it aside
                // into a timestamped folder under 被覆盖的聊天记录 in
                // the Files container (survives uninstalling this
                // app), keeping its original name, then move the
                // incoming folder in under the original name. Nothing
                // is overwritten; any failure here skips the item
                // without moving the incoming folder.
                NSString *rootError = nil;
                if (!backupRootPath) backupRootPath = WQMVResolveBackupRootPath(&rootError);
                if (!backupRootPath) {
                    item.failureReason = rootError.length ? rootError : @"打不开备份位置";
                    [results addObject:item];
                    continue;
                }
                NSString *stampName = WQMVBackupTimestampFolderName();
                NSString *stampDir = [backupRootPath stringByAppendingPathComponent:stampName];
                NSString *stampError = nil;
                if (!(wq_stat(stampDir, &st) && S_ISDIR(st.st_mode))) {
                    if (!wq_create_dir(stampDir, &stampError) && !(wq_stat(stampDir, &st) && S_ISDIR(st.st_mode))) {
                        item.failureReason = [NSString stringWithFormat:@"建不了备份文件夹“%@”（%@）",
                                              stampName, stampError.length ? stampError : @"未知错误"];
                        [results addObject:item];
                        continue;
                    }
                }
                if (wq_stat([stampDir stringByAppendingPathComponent:name], &st)) {
                    item.failureReason = [NSString stringWithFormat:@"备份文件夹“%@”里已有同名文件夹", stampName];
                    [results addObject:item];
                    continue;
                }
                NSString *displaceError = nil;
                if (!wq_move(dstPath, stampDir, &displaceError)) {
                    item.failureReason = [NSString stringWithFormat:@"移走原文件夹失败（%@）",
                                          displaceError.length ? displaceError : @"未知错误"];
                    [results addObject:item];
                    continue;
                }
                item.backupName = stampName;
            }
            NSString *moveError = nil;
            if (!wq_move(srcPath, dstDir, &moveError)) {
                item.failureReason = [NSString stringWithFormat:@"移动失败（%@）",
                                      moveError.length ? moveError : @"未知错误"];
            } else {
                item.moved = YES;
            }
            [results addObject:item];
        }
        // Restore source: a stamp folder left empty by this move is
        // removed; the emptiness test inside decides, nothing else.
        // Other sources are never touched.
        if (srcApp.isBackupStamp) {
            WQMVDeleteStampFolderIfEmpty(srcApp.documentsPath);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            // Present the result ONLY after the progress dismissal has
            // finished: a presentation started while the dismissal
            // animation is still in flight can be dropped by UIKit.
            [progress dismissViewControllerAnimated:YES completion:^{
                if (!strongSelf) return;
                BOOL fullSuccess = YES;
                for (WQMVResultItem *item in results) {
                    if (!item.moved) { fullSuccess = NO; break; }
                }
                WQMVStatusViewController *status = [[WQMVStatusViewController alloc]
                    initWithResults:results completion:^{
                        __strong typeof(self) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        // Full success: reset to the fresh state (both rows
                        // back to 请选择) when the user taps 完成, before
                        // dismissing. Partial failure keeps the selections
                        // so the user can retry.
                        if (fullSuccess) {
                            strongSelf2->_appA = nil;
                            strongSelf2->_appB = nil;
                            strongSelf2->_selectedFolders = @[];
                            [strongSelf2.tableView reloadData];
                        }
                        [strongSelf2 dismissViewControllerAnimated:YES completion:nil];
                    }];
                [strongSelf presentViewController:status animated:YES completion:nil];
            }];
        });
    });
}

- (void)executeTransfer
{
    WQMVApp *srcApp = _appA;
    WQMVTransferPeer *peer = _appB.remotePeer;
    NSArray<NSString *> *names = _selectedFolders;
    if (!peer || !srcApp || !names.count) return;
    NSMutableArray<WQMVTransferFolderSource *> *sources = [NSMutableArray array];
    for (NSString *name in names) {
        WQMVTransferFolderSource *source = [WQMVTransferFolderSource new];
        source.name = name;
        source.rootPath = [srcApp.documentsPath stringByAppendingPathComponent:name];
        [sources addObject:source];
    }
    WQMVTransferSender *sender = [[WQMVTransferSender alloc] initWithPeer:peer folders:sources];
    _transferSender = sender;
    WQMVProgressViewController *progress = [[WQMVProgressViewController alloc] initWithMessage:@"正在准备…"];
    progress.footerNote = @"传输中请勿退出 App，退到后台会中断传输";
    __weak WQMVTransferSender *weakSender = sender;
    progress.cancelHandler = ^{
        [weakSender cancel];
    };
    [self presentViewController:progress animated:YES completion:nil];
    _sending = YES;
    // Transfer only: keep the screen awake for the whole send. Restored
    // in the completion block below, which every exit path funnels through.
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    __weak typeof(self) weakSelf = self;
    sender.progressHandler = ^(unsigned long long done, unsigned long long total,
                               NSUInteger folderIndex, NSUInteger folderCount, NSString *folderName) {
        [progress updateMessage:[NSString stringWithFormat:@"正在传第 %lu/%lu 个\n%@\n%@ / %@",
                                 (unsigned long)(folderIndex + 1), (unsigned long)folderCount,
                                 WQMVTruncatedFolderName(folderName),
                                 wq_size_text(done), wq_size_text(total)]];
    };
    [sender startWithCompletion:^(NSArray<NSDictionary *> *results, NSString *_Nullable error) {
        (void)error; // send runs report per-folder results; there is no batch error
        NSMutableArray<WQMVResultItem *> *items = [NSMutableArray array];
        for (NSDictionary *result in results) {
            WQMVResultItem *item = [WQMVResultItem new];
            id folder = result[@"folder"];
            item.name = [folder isKindOfClass:[NSString class]] ? folder : @"";
            item.moved = [result[@"ok"] boolValue];
            id reason = result[@"reason"];
            item.failureReason = [reason isKindOfClass:[NSString class]] ? reason : nil;
            id backup = result[@"backupName"];
            item.backupName = [backup isKindOfClass:[NSString class]] ? backup : nil;
            item.skippedCount = [result[@"skipped"] unsignedIntegerValue];
            item.transferred = YES;
            [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Shared send teardown: every exit path (completion, cancel,
            // failure) lands here; the screen must never stay forced awake.
            [UIApplication sharedApplication].idleTimerDisabled = NO;
            __strong typeof(self) strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_sending = NO;
                strongSelf->_transferSender = nil;
            }
            // Present the result ONLY after the progress dismissal has
            // finished, same as the local move path.
            [progress dismissViewControllerAnimated:YES completion:^{
                if (!strongSelf) return;
                BOOL fullSuccess = YES;
                for (WQMVResultItem *item in items) {
                    if (!item.moved) { fullSuccess = NO; break; }
                }
                WQMVStatusViewController *status = [[WQMVStatusViewController alloc]
                    initWithResults:items isTransfer:YES completion:^{
                        __strong typeof(self) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        if (fullSuccess) {
                            strongSelf2->_appA = nil;
                            strongSelf2->_appB = nil;
                            strongSelf2->_selectedFolders = @[];
                            [strongSelf2.tableView reloadData];
                        }
                        [strongSelf2 dismissViewControllerAnimated:YES completion:nil];
                    }];
                [strongSelf presentViewController:status animated:YES completion:nil];
            }];
        });
    }];
}

#pragma mark - Receiving

- (void)installTransferReceiver
{
    _transferStore = [WQMVTransferStore new];
    _transferReceiver = [[WQMVTransferReceiver alloc] initWithStore:_transferStore];
    __weak typeof(self) weakSelf = self;
    _transferReceiver.requestHandler = ^(WQMVTransferRequest *request, WQMVTransferDecisionBlock decision) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_sending) {
            decision(NO);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf presentTransferRequest:request decision:decision];
        });
    };
    _transferReceiver.progressHandler = ^(unsigned long long done, unsigned long long total,
                                          NSUInteger folderIndex, NSUInteger folderCount, NSString *folderName) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        WQMVProgressViewController *progress = strongSelf->_receiveProgress;
        if (!progress) return;
        NSString *dest = strongSelf->_receiveDestinationLabel;
        NSString *destLine = dest.length ? [NSString stringWithFormat:@"\n接收到：%@", dest] : @"";
        [progress updateMessage:[NSString stringWithFormat:@"正在接收第 %lu/%lu 个\n%@\n%@ / %@%@",
                                 (unsigned long)(folderIndex + 1), (unsigned long)folderCount,
                                 WQMVTruncatedFolderName(folderName),
                                 wq_size_text(done), wq_size_text(total), destLine]];
    };
    _transferReceiver.completionHandler = ^(NSArray<NSDictionary *> *results, NSString *_Nullable error) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf finishReceivingWithResults:results error:error];
        });
    };
    [_transferReceiver start];
}

// Main thread only. The decision block must be called exactly once;
// WQMVTransferChoiceState's `decided` flag guards all paths (decline,
// accept with a destination, timeout). The choice UI has three steps:
// the destination choice alert, then either the WeChat picker or the
// temp-folder note; backing out of either returns to the choice alert
// and the 180s clock keeps running from the request's arrival.
- (void)presentTransferRequest:(WQMVTransferRequest *)request decision:(WQMVTransferDecisionBlock)decision
{
    WQMVTransferChoiceState *state = [WQMVTransferChoiceState new];
    state.request = request;
    state.decision = decision;
    _pendingTransferChoice = state;
    // A stale destination from an earlier session must never leak in:
    // the store only installs after this request is accepted with a
    // fresh choice.
    _transferStore.installDestinationApp = nil;
    _transferStore.installDestinationIsTempFolder = NO;
    _receiveDestinationLabel = nil;
    [self showTransferDestinationChoice:state];
    // No answer within 3 minutes: auto-decline so the sender is not
    // left hanging (its reply wait times out at the same bound). The
    // timeout holds the state strongly, so the decision always fires.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (state.decided) return;
        UIViewController *ui = state.presentedUI;
        if (ui) [ui dismissViewControllerAnimated:YES completion:nil];
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_pendingTransferChoice == state) strongSelf->_pendingTransferChoice = nil;
        [state decide:NO];
    });
}

// Main thread only. The destination choice: directly into a target
// WeChat, or into the 聊天记录 temp folder.
- (void)showTransferDestinationChoice:(WQMVTransferChoiceState *)state
{
    if (state.decided) return;
    WQMVTransferRequest *request = state.request;
    UIViewController *top = WQMVTopViewController() ?: self;
    NSString *message = [NSString stringWithFormat:@"%@ 要传 %lu 个文件夹（共 %@）。\n\n选择接收位置：直接存入目标微信，或先存到聊天记录临时存放，之后手动移入微信。",
                         request.deviceName, (unsigned long)request.folders.count,
                         wq_size_text(request.totalBytes)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"收到传输请求"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    state.presentedUI = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"拒绝" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_pendingTransferChoice == state) strongSelf->_pendingTransferChoice = nil;
        [state decide:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"选择目标微信" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Let the alert finish dismissing before presenting the picker.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf || state.decided) return;
            [strongSelf showTransferDestinationPicker:state];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"聊天记录临时存放" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Let the alert finish dismissing before presenting the note.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf || state.decided) return;
            [strongSelf showTransferTempFolderNote:state];
        });
    }]];
    [top presentViewController:alert animated:YES completion:nil];
}

// Main thread only. The same picker UX as the source/target pickers:
// auto-detected WeChat apps first, plus the 全部 App search row.
// Tapping a WeChat shows the background-quit prompt before accepting
// the transfer into its Documents.
- (void)showTransferDestinationPicker:(WQMVTransferChoiceState *)state
{
    if (state.decided) return;
    __weak typeof(self) weakSelf = self;
    // Declared before the completion block so the block can reference
    // it weakly (the picker retains the completion; a strong capture
    // would be a retain cycle).
    __weak WQMVAppPickerViewController *weakPicker = nil;
    WQMVAppPickerViewController *picker =
        [[WQMVAppPickerViewController alloc] initForReceiveDestinationWithCompletion:^(WQMVApp *app) {
        __strong typeof(self) strongSelf = weakSelf;
        __strong WQMVAppPickerViewController *strongPicker = weakPicker;
        if (!strongSelf || state.decided) return;
        // Dismiss the picker first, then confirm: the prompt must not
        // stack on top of a presented picker.
        UIViewController *nav = strongPicker.navigationController ?: (UIViewController *)strongPicker;
        if (!nav) {
            [strongSelf showTransferWeChatConfirm:state app:app];
            return;
        }
        [nav dismissViewControllerAnimated:YES completion:^{
            __strong typeof(self) strongSelf2 = weakSelf;
            if (!strongSelf2 || state.decided) return;
            [strongSelf2 showTransferWeChatConfirm:state app:app];
        }];
    }];
    weakPicker = picker;
    picker.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(transferDestinationPickerCancelled:)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    state.presentedUI = nav;
    UIViewController *top = WQMVTopViewController() ?: self;
    [top presentViewController:nav animated:YES completion:nil];
}

// The picker's 取消 button: back to the destination choice; the 180s
// clock keeps running.
- (void)transferDestinationPickerCancelled:(UIBarButtonItem *)sender
{
    (void)sender;
    WQMVTransferChoiceState *state = _pendingTransferChoice;
    UIViewController *top = WQMVTopViewController();
    [top dismissViewControllerAnimated:YES completion:nil];
    if (!state || state.decided) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || state.decided) return;
        [strongSelf showTransferDestinationChoice:state];
    });
}

// Main thread only. The temp-folder option's prompt: receiving here
// means the folders still need a manual move into WeChat afterwards.
- (void)showTransferTempFolderNote:(WQMVTransferChoiceState *)state
{
    if (state.decided) return;
    UIViewController *top = WQMVTopViewController() ?: self;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"聊天记录临时存放"
                                                                   message:@"接收的文件夹将保存到聊天记录临时存放，之后需要手动移动聊天记录到微信。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    state.presentedUI = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"返回" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf || state.decided) return;
            [strongSelf showTransferDestinationChoice:state];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"接收" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || state.decided) return;
        [strongSelf acceptPendingTransfer:state toApp:nil tempFolder:YES];
    }]];
    [top presentViewController:alert animated:YES completion:nil];
}

// Main thread only. The direct-to-WeChat option's prompt: the target
// WeChat must be swiped out of the background before folders start
// installing into it, so B can quit WeChat before accepting. The
// temp-folder option has no such prompt: nothing is written into
// WeChat there.
- (void)showTransferWeChatConfirm:(WQMVTransferChoiceState *)state app:(WQMVApp *)app
{
    if (state.decided) return;
    UIViewController *top = WQMVTopViewController() ?: self;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认接收位置"
                                                                   message:[NSString stringWithFormat:@"文件夹将直接存入%@。\n\n接收前请把目标微信从后台划掉，否则接收可能不完整。", app.title]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    state.presentedUI = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"返回" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf || state.decided) return;
            [strongSelf showTransferDestinationPicker:state];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"接收" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || state.decided) return;
        [strongSelf acceptPendingTransfer:state toApp:app tempFolder:NO];
    }]];
    [top presentViewController:alert animated:YES completion:nil];
}

// Main thread only. Sets the install destination on the store BEFORE
// the decision unblocks the receiver thread, then accepts.
- (void)acceptPendingTransfer:(WQMVTransferChoiceState *)state toApp:(WQMVApp *_Nullable)app tempFolder:(BOOL)isTemp
{
    if (state.decided) return;
    _pendingTransferChoice = nil;
    if (isTemp) {
        _transferStore.installDestinationApp = nil;
        _transferStore.installDestinationIsTempFolder = YES;
        _receiveDestinationLabel = @"聊天记录临时存放";
    } else {
        _transferStore.installDestinationApp = app;
        _transferStore.installDestinationIsTempFolder = NO;
        _receiveDestinationLabel = app.title;
    }
    _receiving = YES;
    // Transfer only: keep the screen awake from accept until the
    // session ends. Restored in finishReceivingWithResults, which
    // every receive exit path funnels through.
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    // Let any dismissal finish before presenting the progress screen.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf showReceiveProgress];
    });
    [state decide:YES];
}

- (void)showReceiveProgress
{
    if (_receiveProgress) return;
    NSString *initial = _receiveDestinationLabel.length
        ? [NSString stringWithFormat:@"正在接收…\n接收到：%@", _receiveDestinationLabel]
        : @"正在接收…";
    WQMVProgressViewController *progress = [[WQMVProgressViewController alloc] initWithMessage:initial];
    progress.footerNote = @"传输中请勿退出 App，退到后台会中断传输";
    __weak typeof(self) weakSelf = self;
    progress.cancelHandler = ^{
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf->_transferReceiver cancelCurrentTransfer];
    };
    _receiveProgress = progress;
    UIViewController *top = WQMVTopViewController() ?: self;
    [top presentViewController:progress animated:YES completion:nil];
}

// Main thread only. Silent when nothing was ever received (rejected,
// or abandoned before the accept prompt was answered).
- (void)finishReceivingWithResults:(NSArray<NSDictionary *> *)results error:(NSString *_Nullable)error
{
    // Shared receive teardown: restore first so no exit path — including
    // the silent early return — can leave the screen forced awake.
    // Harmless when the flag was never set (declined requests).
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    // The session is over: drop the install destination so a stale one
    // can never leak into a later transfer. Captured first for the
    // summary below.
    BOOL toTempFolder = _transferStore.installDestinationIsTempFolder;
    NSString *destLabel = _receiveDestinationLabel;
    _transferStore.installDestinationApp = nil;
    _transferStore.installDestinationIsTempFolder = NO;
    _receiveDestinationLabel = nil;
    if (!_receiving && !results.count) return;
    _receiving = NO;
    WQMVProgressViewController *progress = _receiveProgress;
    _receiveProgress = nil;
    NSUInteger okCount = 0;
    for (NSDictionary *result in results) {
        if ([result[@"ok"] boolValue]) okCount++;
    }
    void (^showSummary)(void) = ^{
        if (!results.count && !error.length) return;
        NSString *title = nil;
        NSString *message = nil;
        if (error.length && okCount == 0) {
            title = @"接收失败";
            message = error;
        } else if (okCount == results.count) {
            title = @"接收完成";
            if (toTempFolder) {
                message = [NSString stringWithFormat:@"已接收 %lu 个文件夹，已保存到聊天记录临时存放，之后需要手动移动聊天记录到微信。",
                           (unsigned long)okCount];
            } else {
                message = [NSString stringWithFormat:@"已接收 %lu 个文件夹，已保存到%@。",
                           (unsigned long)okCount, destLabel.length ? destLabel : @"接收位置"];
            }
        } else {
            title = @"部分接收失败";
            message = [NSString stringWithFormat:@"已接收 %lu 个，失败 %lu 个。已收到的在%@里。",
                       (unsigned long)okCount, (unsigned long)(results.count - okCount),
                       destLabel.length ? destLabel : @"接收位置"];
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *top = WQMVTopViewController() ?: self;
        [top presentViewController:alert animated:YES completion:nil];
    };
    if (progress) {
        [progress dismissViewControllerAnimated:YES completion:showSummary];
    } else {
        showSummary();
    }
}

@end

#pragma mark - Update check

// The latest release of this repo decides whether an update exists: the
// tag name is the version (a leading "v" is ignored), and the release
// page is where 去更新 opens.
//
// The check runs on every cold start and from the main screen's 检查更新
// entry. The prompt is a foreground card only. Tapping 今日不再提示
// mutes the prompt for the rest of the day (device-local date).
static NSString *const kWQMVUpdateCheckURLString = @"https://api.github.com/repos/xqwzka/wq-move/releases/latest";
static NSString *const kWQMVUpdateMutedDateKey = @"WQMVUpdateMutedDate";

// Numeric component comparison: 1.10 > 1.2, 1.1 == 1.1.0.
static NSComparisonResult WQMVCompareVersions(NSString *a, NSString *b)
{
    NSArray<NSString *> *aParts = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *bParts = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(aParts.count, bParts.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger av = i < aParts.count ? [aParts[i] integerValue] : 0;
        NSInteger bv = i < bParts.count ? [bParts[i] integerValue] : 0;
        if (av < bv) return NSOrderedAscending;
        if (av > bv) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

static NSString *_Nullable WQMVLocalShortVersion(void)
{
    id version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:[NSString class]] ? version : nil;
}

// YES when the string is one or more dot-separated all-digit components
// ("1", "1.2", "1.2.3"). Anything else is not a version tag.
static BOOL WQMVIsDottedVersion(NSString *value)
{
    if (!value.length) return NO;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"."];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSString *part in parts) {
        if (!part.length) return NO;
        if ([part rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;
    }
    return YES;
}

// Fetches the latest release. Never blocks the caller; every failure yields
// nils, and the completion still runs exactly once.
static NSURLSessionDataTask *_Nullable WQMVFetchRemoteVersionInfo(void (^completion)(NSString *_Nullable version, NSString *_Nullable urlString))
{
    NSURL *url = [NSURL URLWithString:kWQMVUpdateCheckURLString];
    if (!url) {
        if (completion) completion(nil, nil);
        return nil;
    }
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 10;
    config.timeoutIntervalForResource = 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 10;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *_Nullable data, __unused NSURLResponse *response, NSError *_Nullable error) {
        NSString *version = nil;
        NSString *urlString = nil;
        if (data.length && !error) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:[NSDictionary class]]) {
                id rawTag = json[@"tag_name"];
                if ([rawTag isKindOfClass:[NSString class]]) {
                    NSString *trimmed = [rawTag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if ([trimmed hasPrefix:@"v"] || [trimmed hasPrefix:@"V"]) trimmed = [trimmed substringFromIndex:1];
                    if (WQMVIsDottedVersion(trimmed)) {
                        version = trimmed;
                        id rawURL = json[@"html_url"];
                        if ([rawURL isKindOfClass:[NSString class]] && ((NSString *)rawURL).length) urlString = rawURL;
                    }
                }
            }
        }
        if (completion) completion(version, urlString);
    }];
    [task resume];
    return task;
}

// Today's date as yyyy-MM-dd in the device-local calendar, for the
// 今日不再提示 gate.
static NSString *WQMVTodayString(void)
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:[NSDate date]];
}

static BOOL WQMVUpdateMutedToday(void)
{
    NSString *muted = [[NSUserDefaults standardUserDefaults] stringForKey:kWQMVUpdateMutedDateKey];
    return muted.length && [muted isEqualToString:WQMVTodayString()];
}

static void WQMVRecordUpdateMutedToday(void)
{
    [[NSUserDefaults standardUserDefaults] setObject:WQMVTodayString() forKey:kWQMVUpdateMutedDateKey];
}

// YES while the prompt card is on screen; guards against presenting it
// twice when the launch check and a manual tap race.
static BOOL gWQMVUpdatePromptPresented = NO;

// The update prompt is a custom card, not a UIAlertController: the
// 今日不再提示 line sits BELOW the two buttons, which an alert cannot
// express. Dimmed background, centered card, title + message, two
// side-by-side buttons, and the small tappable line under them.
@interface WQMVUpdatePromptViewController : UIViewController
- (instancetype)initWithVersion:(NSString *)version
                      urlString:(NSString *_Nullable)urlString;
@end

@implementation WQMVUpdatePromptViewController {
    NSString *_version;
    NSString *_urlString;
}

- (instancetype)initWithVersion:(NSString *)version urlString:(NSString *)urlString
{
    self = [super init];
    if (self) {
        _version = [version copy];
        _urlString = [urlString copy];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];
    UILabel *titleLabel = [UILabel new];
    titleLabel.text = @"有新版本";
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];
    UILabel *messageLabel = [UILabel new];
    messageLabel.text = [NSString stringWithFormat:@"发现新版本 %@，是否前往更新？", _version];
    messageLabel.font = [UIFont systemFontOfSize:15];
    messageLabel.textColor = [UIColor secondaryLabelColor];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:messageLabel];
    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [laterButton setTitle:@"下次再说" forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [laterButton addTarget:self action:@selector(laterTapped) forControlEvents:UIControlEventTouchUpInside];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:laterButton];
    UIButton *updateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [updateButton setTitle:@"去更新" forState:UIControlStateNormal];
    updateButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [updateButton addTarget:self action:@selector(updateTapped) forControlEvents:UIControlEventTouchUpInside];
    updateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:updateButton];
    UIButton *muteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [muteButton setTitle:@"今日不再提示" forState:UIControlStateNormal];
    muteButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [muteButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [muteButton addTarget:self action:@selector(muteTapped) forControlEvents:UIControlEventTouchUpInside];
    muteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:muteButton];
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [messageLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [messageLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [messageLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [laterButton.topAnchor constraintEqualToAnchor:messageLabel.bottomAnchor constant:18],
        [laterButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [laterButton.trailingAnchor constraintEqualToAnchor:card.centerXAnchor constant:-6],
        [laterButton.heightAnchor constraintEqualToConstant:40],
        [updateButton.topAnchor constraintEqualToAnchor:messageLabel.bottomAnchor constant:18],
        [updateButton.leadingAnchor constraintEqualToAnchor:card.centerXAnchor constant:6],
        [updateButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [updateButton.heightAnchor constraintEqualToConstant:40],
        [muteButton.topAnchor constraintEqualToAnchor:laterButton.bottomAnchor constant:4],
        [muteButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [muteButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [muteButton.heightAnchor constraintEqualToConstant:30],
    ]];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    gWQMVUpdatePromptPresented = NO;
}

- (void)laterTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateTapped
{
    NSURL *url = _urlString.length ? [NSURL URLWithString:_urlString] : nil;
    [self dismissViewControllerAnimated:YES completion:nil];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)muteTapped
{
    WQMVRecordUpdateMutedToday();
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// Presents the update prompt card. Main thread only. Silently skipped
// when another prompt or alert is already up.
static void WQMVPresentUpdatePrompt(NSString *version, NSString *urlString)
{
    if (gWQMVUpdatePromptPresented) return;
    UIViewController *top = WQMVTopViewController();
    if (!top || [top isKindOfClass:[UIAlertController class]] ||
        [top isKindOfClass:[WQMVUpdatePromptViewController class]]) return;
    gWQMVUpdatePromptPresented = YES;
    WQMVUpdatePromptViewController *prompt = [[WQMVUpdatePromptViewController alloc] initWithVersion:version
                                                                                           urlString:urlString];
    [top presentViewController:prompt animated:YES completion:nil];
}

// Cold-start check: fires only when a newer version exists and today is
// not muted. Silent on every failure; never blocks launch.
static void WQMVCheckForUpdateInForeground(void)
{
    (void)WQMVFetchRemoteVersionInfo(^(NSString *_Nullable version, NSString *_Nullable urlString) {
        if (!version) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *local = WQMVLocalShortVersion();
            if (!local || WQMVCompareVersions(version, local) != NSOrderedDescending) return;
            if (WQMVUpdateMutedToday()) return;
            WQMVPresentUpdatePrompt(version, urlString);
        });
    });
}

// Manual check from the main screen's 检查更新 entry: always reports the
// outcome, and ignores the daily mute (tapping is an explicit ask). The
// prompt card behaves identically, including 今日不再提示 recording today.
static void WQMVCheckForUpdateManually(void)
{
    (void)WQMVFetchRemoteVersionInfo(^(NSString *_Nullable version, NSString *_Nullable urlString) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *local = WQMVLocalShortVersion();
            if (version.length && local && WQMVCompareVersions(version, local) == NSOrderedDescending) {
                WQMVPresentUpdatePrompt(version, urlString);
                return;
            }
            UIViewController *top = WQMVTopViewController();
            if (!top || [top isKindOfClass:[UIAlertController class]] ||
                [top isKindOfClass:[WQMVUpdatePromptViewController class]]) return;
            NSString *message = (!version.length || !local) ? @"检查更新失败，请稍后再试" : @"已是最新版本";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [top presentViewController:alert animated:YES completion:nil];
        });
    });
}

#pragma mark - App

@interface WQMVSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WQMVSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    WQMVMainViewController *root = [WQMVMainViewController new];
    window.rootViewController = [[UINavigationController alloc] initWithRootViewController:root];
    [window makeKeyAndVisible];
    self.window = window;
    // Cold start only: background launches never connect a scene.
    WQMVCheckForUpdateInForeground();
}

@end

@interface WQMVAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WQMVAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options
{
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    config.delegateClass = [WQMVSceneDelegate class];
    return config;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Container folders get their bundle id from the LaunchServices database
        // when the identifier attribute can't be read (iOS 27.2).
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(WQMVConfirmFullScan, WQMVFullScanProgress);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WQMVAppDelegate class]));
    }
}
