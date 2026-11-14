//
//  WQMVTransfer.m
//  WQMove
//
//  See WQMVTransfer.h for the wire format. Plaintext LAN transfer, test
//  version only. All socket I/O is blocking and runs on background
//  queues; nothing here ever touches the main thread except the
//  Bonjour publish/browse calls (documented on each entry point).
//

#import "WQMVTransfer.h"
#import "WQAccess.h"
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <stdatomic.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

static NSString *const kWQMVTransferServiceType = @"_wqmove._tcp";
static NSString *const kWQMVTransferMagic = @"WQMV";
static const NSInteger kWQMVTransferVersion = 2;
static const NSUInteger kWQMVTransferConnectionCount = 4;
static const NSUInteger kWQMVTransferMaxFrameBytes = 1024 * 1024;
static const size_t kWQMVTransferChunkBytes = 128 * 1024;
static const NSInteger kWQMVTransferMaxDepth = 64;

NSString *WQMVTransferServiceType(void)
{
    return kWQMVTransferServiceType;
}

NSString *WQMVTransferOwnDeviceID(void)
{
    static NSString *ownID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *stored = [defaults stringForKey:@"WQMVTransferDeviceID"];
        if (!stored.length) {
            stored = NSUUID.UUID.UUIDString;
            [defaults setObject:stored forKey:@"WQMVTransferDeviceID"];
        }
        ownID = [stored copy];
    });
    return ownID;
}

#pragma mark - Small socket + JSON helpers (background threads only)

static BOOL WQMVTransferWriteAll(int fd, const void *buffer, size_t length)
{
    const uint8_t *p = (const uint8_t *)buffer;
    size_t left = length;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) {
            errno = EIO;
            return NO;
        }
        p += (size_t)n;
        left -= (size_t)n;
    }
    return YES;
}

// YES when exactly `length` bytes were read; NO on EOF or error.
static BOOL WQMVTransferReadExact(int fd, void *buffer, size_t length)
{
    uint8_t *p = (uint8_t *)buffer;
    size_t left = length;
    while (left > 0) {
        ssize_t n = read(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO; // EOF
        p += (size_t)n;
        left -= (size_t)n;
    }
    return YES;
}

static void WQMVTransferSetSocketTimeouts(int fd, long recvSeconds, long sendSeconds)
{
    struct timeval recvTimeout = { .tv_sec = recvSeconds, .tv_usec = 0 };
    struct timeval sendTimeout = { .tv_sec = sendSeconds, .tv_usec = 0 };
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, sizeof(recvTimeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof(sendTimeout));
    int noSigPipe = 1;
    // Without this, writing to a closed socket kills the app with SIGPIPE.
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
}

typedef NS_ENUM(NSInteger, WQMVTransferFrameRead) {
    WQMVTransferFrameReadOK,
    WQMVTransferFrameReadEnd, // zero-length frame: end-of-stream marker
    WQMVTransferFrameReadFailed,
};

static BOOL WQMVTransferWriteFrame(int fd, NSDictionary *json)
{
    NSError *error = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (!payload) return NO;
    uint32_t length = htonl((uint32_t)payload.length);
    return WQMVTransferWriteAll(fd, &length, sizeof(length)) &&
           WQMVTransferWriteAll(fd, payload.bytes, payload.length);
}

// Reads one length-prefixed JSON frame. Returns End for a zero-length
// frame (payload left nil). Failed covers EOF, oversize frames and
// malformed JSON.
static WQMVTransferFrameRead WQMVTransferReadFrame(int fd, NSDictionary *_Nullable *_Nullable outJSON)
{
    if (outJSON) *outJSON = nil;
    uint32_t rawLength = 0;
    if (!WQMVTransferReadExact(fd, &rawLength, sizeof(rawLength))) return WQMVTransferFrameReadFailed;
    uint32_t length = ntohl(rawLength);
    if (length == 0) return WQMVTransferFrameReadEnd;
    if (length > kWQMVTransferMaxFrameBytes) return WQMVTransferFrameReadFailed;
    NSMutableData *payload = [NSMutableData dataWithLength:length];
    if (!WQMVTransferReadExact(fd, payload.mutableBytes, length)) return WQMVTransferFrameReadFailed;
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) return WQMVTransferFrameReadFailed;
    if (outJSON) *outJSON = (NSDictionary *)object;
    return WQMVTransferFrameReadOK;
}

static BOOL WQMVTransferJSONString(NSDictionary *json, NSString *key, NSString *_Nullable *_Nullable out)
{
    id value = json[key];
    if (![value isKindOfClass:[NSString class]]) return NO;
    if (out) *out = (NSString *)value;
    return YES;
}

static BOOL WQMVTransferJSONUnsigned(NSDictionary *json, NSString *key, unsigned long long *out)
{
    id value = json[key];
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (out) *out = [(NSNumber *)value unsignedLongLongValue];
    return YES;
}

static BOOL WQMVTransferJSONBool(NSDictionary *json, NSString *key, BOOL *out)
{
    id value = json[key];
    if (![value isKindOfClass:[NSNumber class]]) return NO;
    if (out) *out = [(NSNumber *)value boolValue];
    return YES;
}

// A relative path is safe only when every component is a plain name:
// no empty components, no "." or "..", no leading slash. Sender-built
// paths always satisfy this; the check keeps a bad or hostile peer
// from writing outside the staging area.
static BOOL WQMVTransferIsSafeRelativePath(NSString *relPath)
{
    if (!relPath.length) return NO;
    if ([relPath hasPrefix:@"/"]) return NO;
    if ([relPath rangeOfString:@"\0"].location != NSNotFound) return NO;
    NSArray<NSString *> *parts = [relPath componentsSeparatedByString:@"/"];
    for (NSString *part in parts) {
        if (!part.length) return NO;
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    }
    return YES;
}

static BOOL WQMVTransferIsSingleComponent(NSString *name)
{
    return name.length && [name rangeOfString:@"/"].location == NSNotFound &&
           ![name isEqualToString:@"."] && ![name isEqualToString:@".."];
}

#pragma mark - Model objects

@implementation WQMVTransferFolderInfo
@end

@implementation WQMVTransferRequest
@end

@implementation WQMVTransferPeer
@end

#pragma mark - Discovery

@interface WQMVTransferBrowser () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

@implementation WQMVTransferBrowser {
    void (^_update)(NSArray<WQMVTransferPeer *> *peers);
    NSNetServiceBrowser *_Nullable _browser;
    NSMutableDictionary<NSString *, NSNetService *> *_resolving;
    NSMutableArray<WQMVTransferPeer *> *_peers;
}

- (instancetype)initWithUpdate:(void (^)(NSArray<WQMVTransferPeer *> *peers))update
{
    self = [super init];
    if (self) {
        _update = [update copy];
        _resolving = [NSMutableDictionary dictionary];
        _peers = [NSMutableArray array];
    }
    return self;
}

- (NSArray<WQMVTransferPeer *> *)peers
{
    return [_peers copy];
}

- (void)start
{
    [self stop];
    _browser = [NSNetServiceBrowser new];
    _browser.delegate = self;
    [_browser scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_browser searchForServicesOfType:@"_wqmove._tcp." inDomain:@"local."];
}

- (void)stop
{
    if (_browser) {
        [_browser stop];
        [_browser removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        _browser.delegate = nil;
        _browser = nil;
    }
    for (NSNetService *service in [_resolving allValues]) {
        [service stop];
        service.delegate = nil;
    }
    [_resolving removeAllObjects];
    [_peers removeAllObjects];
}

- (void)reportPeers
{
    if (_update) _update([_peers copy]);
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    (void)browser;
    (void)moreComing;
    if (_resolving[service.name]) return;
    for (WQMVTransferPeer *peer in _peers) {
        if ([peer.name isEqualToString:service.name]) return;
    }
    _resolving[service.name] = service;
    service.delegate = self;
    [service scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
         didRemoveService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    (void)browser;
    (void)moreComing;
    NSNetService *resolving = _resolving[service.name];
    if (resolving) {
        [resolving stop];
        resolving.delegate = nil;
        [_resolving removeObjectForKey:service.name];
    }
    NSUInteger before = _peers.count;
    NSMutableArray<WQMVTransferPeer *> *kept = [NSMutableArray array];
    for (WQMVTransferPeer *peer in _peers) {
        if (![peer.name isEqualToString:service.name]) [kept addObject:peer];
    }
    [_peers setArray:kept];
    if (_peers.count != before) [self reportPeers];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
    (void)browser;
    (void)errorDict;
    [_peers removeAllObjects];
    [self reportPeers];
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
    [_resolving removeObjectForKey:service.name];
    [service removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    service.delegate = nil;
    if (!service.addresses.count) return;
    // Never list ourselves: the TXT id is per-install and survives
    // duplicate device names.
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:[service TXTRecordData]];
    NSData *idData = txt[@"id"];
    NSString *peerID = idData ? [[NSString alloc] initWithData:idData encoding:NSUTF8StringEncoding] : nil;
    if (peerID.length && [peerID isEqualToString:WQMVTransferOwnDeviceID()]) return;
    NSData *modelData = txt[@"model"];
    NSString *model = modelData ? [[NSString alloc] initWithData:modelData encoding:NSUTF8StringEncoding] : nil;
    WQMVTransferPeer *peer = [WQMVTransferPeer new];
    peer.name = service.name;
    peer.service = service;
    peer.model = model;
    for (WQMVTransferPeer *existing in _peers) {
        if ([existing.name isEqualToString:peer.name]) return;
    }
    [_peers addObject:peer];
    [_peers sortUsingComparator:^NSComparisonResult(WQMVTransferPeer *a, WQMVTransferPeer *b) {
        return [a.name compare:b.name];
    }];
    [self reportPeers];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
    (void)errorDict;
    [_resolving removeObjectForKey:service.name];
    [service removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    service.delegate = nil;
}

@end

#pragma mark - Receiver

// One accepted transfer session: shared state for the control connection
// and up to 3 join connections. All mutable fields are guarded by `lock`,
// except `installLock`, which serializes folder installs (the store's
// install path resolves the Files container and moves folders aside
// into a timestamped backup folder; running two installs at once could
// race that shared state). File writes stay parallel: only installs
// are serialized.
@interface WQMVTransferSession : NSObject
@property (nonatomic, strong) id<WQMVTransferReceiverStore> store;
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, strong) WQMVTransferRequest *request;
@property (nonatomic, copy) NSDictionary<NSString *, WQMVTransferFolderInfo *> *manifest;
@property (nonatomic, copy) NSString *tempDir;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSLock *installLock;
@property (nonatomic, copy, nullable) WQMVTransferProgressBlock progressHandler;
@property (nonatomic, copy, nullable) WQMVTransferCompletionBlock completionHandler;
// Guarded by lock:
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *dirsByFolder;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *filesByFolder;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *bytesByFolder;
@property (nonatomic, strong) NSMutableSet<NSString *> *settledFolders;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *results;
@property (nonatomic) unsigned long long totalReceived;
@property (nonatomic, copy, nullable) NSString *fatalError;
@property (nonatomic) NSUInteger expectedConnections;
@property (nonatomic) BOOL joinsCompleteReceived;
@property (nonatomic) NSUInteger doneConnections;
@property (nonatomic) NSUInteger activeConnections;
@property (nonatomic) BOOL finalized;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *fds;
@property (nonatomic) int controlFd;
- (instancetype)initWithStore:(id<WQMVTransferReceiverStore>)store
                      request:(WQMVTransferRequest *)request
                      tempDir:(NSString *)tempDir;
- (void)shutdownAllFds;
@end

@implementation WQMVTransferSession

- (instancetype)initWithStore:(id<WQMVTransferReceiverStore>)store
                      request:(WQMVTransferRequest *)request
                      tempDir:(NSString *)tempDir
{
    self = [super init];
    if (self) {
        _store = store;
        _request = request;
        _sessionID = [request.sessionID copy];
        _tempDir = [tempDir copy];
        _lock = [NSLock new];
        _installLock = [NSLock new];
        NSMutableDictionary<NSString *, WQMVTransferFolderInfo *> *byName = [NSMutableDictionary dictionary];
        for (WQMVTransferFolderInfo *info in request.folders) byName[info.name] = info;
        _manifest = [byName copy];
        _dirsByFolder = [NSMutableDictionary dictionary];
        _filesByFolder = [NSMutableDictionary dictionary];
        _bytesByFolder = [NSMutableDictionary dictionary];
        _settledFolders = [NSMutableSet set];
        _results = [NSMutableArray array];
        _fds = [NSMutableArray array];
        _controlFd = -1;
    }
    return self;
}

- (void)shutdownAllFds
{
    [self.lock lock];
    NSArray<NSNumber *> *fds = [self.fds copy];
    [self.lock unlock];
    for (NSNumber *fd in fds) {
        if (fd.intValue >= 0) (void)shutdown(fd.intValue, SHUT_RDWR);
    }
}

@end

@interface WQMVTransferReceiver () <NSNetServiceDelegate>
@end

@implementation WQMVTransferReceiver {
    __weak id<WQMVTransferReceiverStore> _store;
    NSNetService *_Nullable _publishedService;
    dispatch_source_t _Nullable _acceptSource;
    int _listenFd;
    atomic_bool _busy;
    atomic_bool _cancelled;
    atomic_int _currentFd;
    NSLock *_stateLock;
    WQMVTransferSession *_Nullable _session;
}

- (instancetype)initWithStore:(id<WQMVTransferReceiverStore>)store
{
    self = [super init];
    if (self) {
        _store = store;
        _listenFd = -1;
        _stateLock = [NSLock new];
        atomic_init(&_busy, false);
        atomic_init(&_cancelled, false);
        atomic_init(&_currentFd, -1);
    }
    return self;
}

- (id<WQMVTransferReceiverStore>)store
{
    return _store;
}

- (void)setStore:(id<WQMVTransferReceiverStore>)store
{
    _store = store;
}

- (BOOL)busy
{
    return atomic_load(&_busy);
}

- (void)start
{
    if (_publishedService || _acceptSource) return; // already started
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int reuse = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int noSigPipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = 0; // ephemeral; the published port is read back below
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        close(fd);
        return;
    }
    socklen_t addrLen = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &addrLen) != 0) {
        close(fd);
        return;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    _listenFd = fd;

    __weak typeof(self) weakSelf = self;
    dispatch_queue_t acceptQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, acceptQueue);
    dispatch_source_set_event_handler(source, ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf acceptPending];
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });
    _acceptSource = source;
    dispatch_resume(source);

    NSString *deviceName = UIDevice.currentDevice.name;
    NSNetService *service = [[NSNetService alloc] initWithDomain:@"local."
                                                            type:@"_wqmove._tcp."
                                                            name:deviceName.length ? deviceName : @"iPhone"
                                                            port:ntohs(addr.sin_port)];
    NSDictionary *txt = @{
        @"version": [@"2" dataUsingEncoding:NSUTF8StringEncoding],
        @"id": [WQMVTransferOwnDeviceID() dataUsingEncoding:NSUTF8StringEncoding],
        @"model": [UIDevice.currentDevice.model dataUsingEncoding:NSUTF8StringEncoding],
    };
    [service setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:txt]];
    service.delegate = self;
    [service scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [service publish];
    _publishedService = service;

    // Stale staging from interrupted transfers is removed on a
    // background queue; it never blocks publishing.
    __weak id<WQMVTransferReceiverStore> weakStore = _store;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [weakStore cleanupStaleStaging];
    });
}

- (void)stop
{
    [self cancelCurrentTransfer];
    if (_publishedService) {
        [_publishedService stop];
        [_publishedService removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        _publishedService.delegate = nil;
        _publishedService = nil;
    }
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    _listenFd = -1;
}

- (void)cancelCurrentTransfer
{
    atomic_store(&_cancelled, true);
    int fd = atomic_load(&_currentFd);
    if (fd >= 0) (void)shutdown(fd, SHUT_RDWR);
    [_stateLock lock];
    WQMVTransferSession *session = _session;
    [_stateLock unlock];
    [session shutdownAllFds];
}

- (void)acceptPending
{
    for (;;) {
        struct sockaddr_in peerAddr;
        socklen_t peerLen = sizeof(peerAddr);
        int fd = accept(_listenFd, (struct sockaddr *)&peerAddr, &peerLen);
        if (fd < 0) return; // EAGAIN when drained; other errors also end this round
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) (void)fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
        WQMVTransferSetSocketTimeouts(fd, 120, 60);
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (strongSelf) [strongSelf handleConnection:fd];
            else close(fd);
        });
    }
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
    (void)sender;
    (void)errorDict;
    // Publishing failed (e.g. local-network permission denied). There is
    // no retry: the next foreground entry starts the service again.
}

- (BOOL)parseRequestJSON:(NSDictionary *)json request:(WQMVTransferRequest **)outRequest
{
    NSString *magic = nil;
    unsigned long long version = 0;
    NSString *deviceName = nil;
    NSString *sessionID = nil;
    if (!WQMVTransferJSONString(json, @"magic", &magic) || ![magic isEqualToString:kWQMVTransferMagic]) return NO;
    if (!WQMVTransferJSONUnsigned(json, @"version", &version) || version != (unsigned long long)kWQMVTransferVersion) return NO;
    if (!WQMVTransferJSONString(json, @"deviceName", &deviceName) || !deviceName.length) return NO;
    if (!WQMVTransferJSONString(json, @"session", &sessionID) || !sessionID.length) return NO;
    id foldersValue = json[@"folders"];
    if (![foldersValue isKindOfClass:[NSArray class]]) return NO;
    unsigned long long totalBytes = 0;
    unsigned long long totalFiles = 0;
    if (!WQMVTransferJSONUnsigned(json, @"totalBytes", &totalBytes)) return NO;
    if (!WQMVTransferJSONUnsigned(json, @"totalFiles", &totalFiles)) return NO;
    NSMutableArray<WQMVTransferFolderInfo *> *folders = [NSMutableArray array];
    NSMutableSet<NSString *> *seenNames = [NSMutableSet set];
    unsigned long long sumBytes = 0;
    unsigned long long sumFiles = 0;
    for (id entry in (NSArray *)foldersValue) {
        if (![entry isKindOfClass:[NSDictionary class]]) return NO;
        NSDictionary *folderJSON = (NSDictionary *)entry;
        NSString *name = nil;
        unsigned long long fileCount = 0;
        unsigned long long folderBytes = 0;
        unsigned long long skipped = 0;
        unsigned long long dirCount = 0;
        if (!WQMVTransferJSONString(folderJSON, @"name", &name) || !WQMVTransferIsSingleComponent(name)) return NO;
        if ([seenNames containsObject:name]) return NO;
        [seenNames addObject:name];
        if (!WQMVTransferJSONUnsigned(folderJSON, @"fileCount", &fileCount)) return NO;
        if (!WQMVTransferJSONUnsigned(folderJSON, @"totalBytes", &folderBytes)) return NO;
        if (!WQMVTransferJSONUnsigned(folderJSON, @"dirCount", &dirCount) || dirCount < 1) return NO;
        (void)WQMVTransferJSONUnsigned(folderJSON, @"skipped", &skipped);
        WQMVTransferFolderInfo *info = [WQMVTransferFolderInfo new];
        info.name = name;
        info.fileCount = fileCount;
        info.totalBytes = folderBytes;
        info.dirCount = dirCount;
        info.skippedCount = (NSUInteger)skipped;
        [folders addObject:info];
        sumBytes += folderBytes;
        sumFiles += fileCount;
    }
    if (!folders.count) return NO;
    if (sumBytes != totalBytes || sumFiles != totalFiles) return NO;
    WQMVTransferRequest *request = [WQMVTransferRequest new];
    request.deviceName = deviceName;
    request.sessionID = sessionID;
    request.folders = folders;
    request.totalBytes = totalBytes;
    request.totalFiles = totalFiles;
    if (outRequest) *outRequest = request;
    return YES;
}

- (void)handleConnection:(int)fd
{
    NSDictionary *firstJSON = nil;
    WQMVTransferFrameRead read = WQMVTransferReadFrame(fd, &firstJSON);
    if (read != WQMVTransferFrameReadOK || !firstJSON) {
        close(fd);
        return;
    }
    // Join frames carry `join`; request frames carry `folders`. A frame
    // with neither is dropped by the request parser below.
    if (firstJSON[@"join"]) {
        [self handleJoin:fd joinJSON:firstJSON];
        return;
    }
    WQMVTransferRequest *request = nil;
    if (![self parseRequestJSON:firstJSON request:&request]) {
        close(fd);
        return;
    }
    // One transfer at a time. A second peer gets an explicit rejection
    // instead of a dropped connection.
    BOOL expected = false;
    if (!atomic_compare_exchange_strong(&_busy, &expected, true)) {
        (void)WQMVTransferWriteFrame(fd, @{@"accepted": @NO, @"reason": @"对方正在接收另一笔传输"});
        close(fd);
        return;
    }
    atomic_store(&_cancelled, false);
    atomic_store(&_currentFd, fd);
    WQMVTransferRequestBlock requestHandler = self.requestHandler;
    __block BOOL accepted = NO;
    if (requestHandler) {
        dispatch_semaphore_t answered = dispatch_semaphore_create(0);
        requestHandler(request, ^(BOOL accept) {
            accepted = accept;
            dispatch_semaphore_signal(answered);
        });
        (void)dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    }
    if (atomic_load(&_cancelled)) {
        [self endDeclinedConnection:fd error:@"已取消"];
        return;
    }
    if (!accepted) {
        (void)WQMVTransferWriteFrame(fd, @{@"accepted": @NO, @"reason": @"对方拒绝了接收"});
        [self endDeclinedConnection:fd error:nil];
        return;
    }
    // The session (staging root + temp dir) is created BEFORE the accept
    // reply, so join connections arriving right after it always find a
    // live session to attach to.
    NSString *beginError = nil;
    WQMVTransferSession *session = [self beginSessionForRequest:request controlFd:fd error:&beginError];
    if (!session) {
        NSString *reason = beginError.length ? beginError : @"建不了暂存文件夹";
        (void)WQMVTransferWriteFrame(fd, @{@"accepted": @NO, @"reason": reason});
        [self endDeclinedConnection:fd error:reason];
        return;
    }
    if (!WQMVTransferWriteFrame(fd, @{@"accepted": @YES, @"reason": @""})) {
        [self connectionDidEnd:session sawEntry:NO sawDone:NO error:@"连接已断开"];
        return;
    }
    [self receiveEntriesOnFd:fd session:session connIndex:0 isControl:YES];
}

// Ends a connection that never became a session (declined, cancelled
// during the decision, or staging setup failed). Mirrors the old
// single-connection teardown: the completion block fires only with an
// error, never for a plain decline.
- (void)endDeclinedConnection:(int)fd error:(NSString *_Nullable)error
{
    atomic_store(&_currentFd, -1);
    close(fd);
    atomic_store(&_busy, false);
    WQMVTransferCompletionBlock completion = self.completionHandler;
    if (completion && error) completion(@[], error);
}

- (WQMVTransferSession *_Nullable)beginSessionForRequest:(WQMVTransferRequest *)request
                                               controlFd:(int)fd
                                                   error:(NSString *_Nullable *_Nullable)outError
{
    id<WQMVTransferReceiverStore> store = self.store;
    NSString *storeError = nil;
    NSString *stagingRoot = [store createStagingDirectoryWithError:&storeError];
    if (!stagingRoot) {
        if (outError) *outError = storeError.length ? storeError : @"建不了暂存文件夹";
        return nil;
    }
    // Sandbox temp dir for the session; each connection writes its own
    // uniquely named temp files here, one file at a time per connection.
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [@"wqmv-recv-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError *tempError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:&tempError]) {
        [store finishStaging];
        if (outError) *outError = @"建不了临时文件夹";
        return nil;
    }
    WQMVTransferSession *session = [[WQMVTransferSession alloc] initWithStore:store request:request tempDir:tempDir];
    session.progressHandler = self.progressHandler;
    session.completionHandler = self.completionHandler;
    [session.lock lock];
    session.controlFd = fd;
    [session.fds addObject:@(fd)];
    session.activeConnections = 1;
    [session.lock unlock];
    [_stateLock lock];
    _session = session;
    [_stateLock unlock];
    return session;
}

- (void)handleJoin:(int)fd joinJSON:(NSDictionary *)json
{
    NSString *magic = nil;
    unsigned long long version = 0;
    NSString *joinID = nil;
    BOOL valid = WQMVTransferJSONString(json, @"magic", &magic) &&
                 [magic isEqualToString:kWQMVTransferMagic] &&
                 WQMVTransferJSONUnsigned(json, @"version", &version) &&
                 version == (unsigned long long)kWQMVTransferVersion &&
                 WQMVTransferJSONString(json, @"join", &joinID) && joinID.length > 0;
    WQMVTransferSession *session = nil;
    NSUInteger connIndex = 0;
    if (valid) {
        [_stateLock lock];
        WQMVTransferSession *current = _session;
        [_stateLock unlock];
        if (current && [current.sessionID isEqualToString:joinID]) {
            [current.lock lock];
            BOOL attachable = !current.finalized && current.fatalError == nil &&
                              !atomic_load(&_cancelled) &&
                              current.fds.count < kWQMVTransferConnectionCount;
            if (attachable) {
                connIndex = current.fds.count;
                [current.fds addObject:@(fd)];
                current.activeConnections++;
                session = current;
            }
            [current.lock unlock];
        }
    }
    if (!session) {
        (void)WQMVTransferWriteFrame(fd, @{@"joined": @NO});
        close(fd);
        return;
    }
    if (!WQMVTransferWriteFrame(fd, @{@"joined": @YES})) {
        // The reply was lost: unregister so the session never waits on
        // this fd.
        [session.lock lock];
        [session.fds removeObject:@(fd)];
        if (session.activeConnections > 0) session.activeConnections--;
        [session.lock unlock];
        close(fd);
        [self maybeFinalizeSession:session];
        return;
    }
    [self receiveEntriesOnFd:fd session:session connIndex:connIndex isControl:NO];
}

// Updates the per-folder counters for one received entry. When the
// folder becomes exactly complete (directories, files and bytes all
// match the manifest), the folder is marked settled under the same lock
// and its name is returned for installation outside the lock, so each
// folder installs exactly once. Sets *overflow when the entry would
// push a counter past the manifest.
- (NSString *_Nullable)noteEntryReceived:(WQMVTransferSession *)session
                                  folder:(NSString *)folder
                                   isDir:(BOOL)isDir
                                    size:(unsigned long long)size
                                overflow:(BOOL *)overflow
{
    if (overflow) *overflow = NO;
    WQMVTransferFolderInfo *info = session.manifest[folder];
    if (!info) {
        if (overflow) *overflow = YES;
        return nil;
    }
    [session.lock lock];
    unsigned long long dirs = [session.dirsByFolder[folder] unsignedLongLongValue] + (isDir ? 1 : 0);
    unsigned long long files = [session.filesByFolder[folder] unsignedLongLongValue] + (isDir ? 0 : 1);
    unsigned long long bytes = [session.bytesByFolder[folder] unsignedLongLongValue] + (isDir ? 0 : size);
    if (dirs > info.dirCount || files > info.fileCount || bytes > info.totalBytes) {
        [session.lock unlock];
        if (overflow) *overflow = YES;
        return nil;
    }
    session.dirsByFolder[folder] = @(dirs);
    session.filesByFolder[folder] = @(files);
    session.bytesByFolder[folder] = @(bytes);
    if (!isDir) session.totalReceived += size;
    NSString *toInstall = nil;
    if (dirs == info.dirCount && files == info.fileCount && bytes == info.totalBytes &&
        ![session.settledFolders containsObject:folder]) {
        [session.settledFolders addObject:folder];
        toInstall = folder;
    }
    [session.lock unlock];
    return toInstall;
}

// Installs one settled folder (serialized against other installs) and
// records its result. A failed install discards the staged folder.
- (void)installSettledFolder:(WQMVTransferSession *)session folder:(NSString *)folder
{
    [session.installLock lock];
    NSDictionary *installed = [session.store installStagedFolder:folder];
    if (![installed[@"ok"] boolValue]) [session.store discardStagedFolder:folder];
    [session.installLock unlock];
    NSMutableDictionary *withFolder = [installed mutableCopy];
    withFolder[@"folder"] = folder;
    [session.lock lock];
    [session.results addObject:withFolder];
    [session.lock unlock];
}

- (void)receiveEntriesOnFd:(int)fd
                   session:(WQMVTransferSession *)session
                 connIndex:(NSUInteger)connIndex
                 isControl:(BOOL)isControl
{
    id<WQMVTransferReceiverStore> store = session.store;
    WQMVTransferRequest *request = session.request;
    NSDictionary<NSString *, WQMVTransferFolderInfo *> *manifest = session.manifest;
    BOOL sawEntry = NO;
    BOOL sawDone = NO;
    NSString *_Nullable loopError = nil;
    NSUInteger tempIndex = 0;

    if (isControl) {
        // The first frame on the control connection states how many
        // connections the sender actually opened. Anything else here
        // means the peer is not speaking version 2.
        NSDictionary *joinsJSON = nil;
        WQMVTransferFrameRead read = WQMVTransferReadFrame(fd, &joinsJSON);
        BOOL joinsOK = NO;
        unsigned long long connections = 0;
        if (read == WQMVTransferFrameReadOK && joinsJSON) {
            BOOL flag = NO;
            joinsOK = WQMVTransferJSONBool(joinsJSON, @"joinsComplete", &flag) && flag &&
                      WQMVTransferJSONUnsigned(joinsJSON, @"connections", &connections) &&
                      connections >= 1 && connections <= kWQMVTransferConnectionCount;
        }
        if (!joinsOK) {
            loopError = atomic_load(&_cancelled) ? @"已取消" : @"连接中断";
            [self connectionDidEnd:session sawEntry:NO sawDone:NO error:loopError];
            return;
        }
        [session.lock lock];
        session.expectedConnections = (NSUInteger)connections;
        session.joinsCompleteReceived = YES;
        [session.lock unlock];
    }

    while (!loopError && !sawDone) {
        if (atomic_load(&_cancelled)) {
            loopError = @"已取消";
            break;
        }
        [session.lock lock];
        BOOL sessionFatal = session.fatalError != nil;
        [session.lock unlock];
        if (sessionFatal) break; // another connection failed; exit quietly, the drain finalizes
        NSDictionary *header = nil;
        WQMVTransferFrameRead read = WQMVTransferReadFrame(fd, &header);
        if (read != WQMVTransferFrameReadOK || !header) {
            loopError = atomic_load(&_cancelled) ? @"已取消" : @"连接中断";
            break;
        }
        BOOL done = NO;
        (void)WQMVTransferJSONBool(header, @"done", &done);
        if (done) {
            sawDone = YES;
            break;
        }
        NSString *folder = nil;
        NSString *relPath = nil;
        unsigned long long size = 0;
        BOOL isDir = NO;
        if (!WQMVTransferJSONString(header, @"folder", &folder) ||
            !WQMVTransferJSONString(header, @"relPath", &relPath) ||
            !WQMVTransferJSONUnsigned(header, @"size", &size) ||
            !WQMVTransferJSONBool(header, @"isDir", &isDir)) {
            loopError = @"收到无法识别的数据";
            break;
        }
        WQMVTransferFolderInfo *info = manifest[folder];
        if (!info || !WQMVTransferIsSafeRelativePath(relPath)) {
            loopError = @"收到无法识别的数据";
            break;
        }
        // relPath must stay inside its own folder.
        if (![relPath isEqualToString:folder] &&
            ![relPath hasPrefix:[folder stringByAppendingString:@"/"]]) {
            loopError = @"收到无法识别的数据";
            break;
        }
        if (isDir && size != 0) {
            loopError = @"收到无法识别的数据";
            break;
        }
        sawEntry = YES;
        if (isDir) {
            NSString *dirError = nil;
            if (![store createStagingDirectoriesForRelativePath:relPath error:&dirError]) {
                loopError = dirError.length ? dirError : @"建不了文件夹";
                break;
            }
            BOOL overflow = NO;
            NSString *toInstall = [self noteEntryReceived:session folder:folder isDir:YES size:0 overflow:&overflow];
            if (overflow) {
                loopError = @"收到的数据超过了请求的大小";
                break;
            }
            if (toInstall) [self installSettledFolder:session folder:toInstall];
            continue;
        }
        [session.lock lock];
        unsigned long long folderBytes = [session.bytesByFolder[folder] unsignedLongLongValue];
        [session.lock unlock];
        if (folderBytes + size > info.totalBytes) {
            loopError = @"收到的数据超过了请求的大小";
            break;
        }
        // Stream exactly `size` bytes into a sandbox temp file. The temp
        // name includes the connection index, so connections sharing one
        // temp dir can never collide.
        NSString *tempPath = [session.tempDir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"f%lu-%05lu", (unsigned long)connIndex, (unsigned long)tempIndex++]];
        int outFd = open(tempPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (outFd < 0) {
            loopError = @"写不了临时文件";
            break;
        }
        unsigned long long remaining = size;
        BOOL fileOK = YES;
        uint8_t *buffer = (uint8_t *)malloc(kWQMVTransferChunkBytes);
        if (!buffer) {
            close(outFd);
            loopError = @"内存不足";
            break;
        }
        while (remaining > 0) {
            if (atomic_load(&_cancelled)) {
                fileOK = NO;
                loopError = @"已取消";
                break;
            }
            size_t want = remaining > kWQMVTransferChunkBytes ? kWQMVTransferChunkBytes : (size_t)remaining;
            if (!WQMVTransferReadExact(fd, buffer, want)) {
                fileOK = NO;
                if (!loopError) loopError = @"连接中断";
                break;
            }
            if (!WQMVTransferWriteAll(outFd, buffer, want)) {
                fileOK = NO;
                if (!loopError) loopError = @"写不了临时文件";
                break;
            }
            remaining -= want;
        }
        free(buffer);
        if (close(outFd) != 0 && fileOK) {
            fileOK = NO;
            if (!loopError) loopError = @"写不了临时文件";
        }
        if (!fileOK) {
            (void)unlink(tempPath.fileSystemRepresentation);
            break;
        }
        NSString *fileError = nil;
        if (![store storeReceivedFileFromTempPath:tempPath relativePath:relPath error:&fileError]) {
            (void)unlink(tempPath.fileSystemRepresentation);
            loopError = fileError.length ? fileError : @"保存文件失败";
            break;
        }
        (void)unlink(tempPath.fileSystemRepresentation);
        BOOL overflow = NO;
        NSString *toInstall = [self noteEntryReceived:session folder:folder isDir:NO size:size overflow:&overflow];
        if (overflow) {
            loopError = @"收到的数据超过了请求的大小";
            break;
        }
        if (toInstall) [self installSettledFolder:session folder:toInstall];
        [session.lock lock];
        unsigned long long doneBytes = session.totalReceived;
        [session.lock unlock];
        WQMVTransferProgressBlock progress = session.progressHandler;
        if (progress) {
            NSUInteger folderIndex = [request.folders indexOfObject:info];
            if (folderIndex == NSNotFound) folderIndex = 0;
            progress(doneBytes, request.totalBytes, folderIndex, request.folders.count, folder);
        }
    }

    [self connectionDidEnd:session sawEntry:sawEntry sawDone:sawDone error:loopError];
}

// Called exactly once per connection when its read loop exits. The
// first error wins and shuts every connection down; the barrier closes
// when all connections reported done, or when a fatal error has drained
// every connection.
- (void)connectionDidEnd:(WQMVTransferSession *)session
                sawEntry:(BOOL)sawEntry
                 sawDone:(BOOL)sawDone
                   error:(NSString *_Nullable)error
{
    BOOL firstFatal = NO;
    [session.lock lock];
    if (error.length && session.fatalError == nil) {
        session.fatalError = error;
        firstFatal = YES;
    }
    if (sawDone) session.doneConnections++;
    // A connection that delivered nothing, hit no error and went away
    // after the sender confirmed the connection count is an abandoned
    // join: it never counts toward the barrier.
    if (!sawEntry && !sawDone && !error.length && session.fatalError == nil &&
        !atomic_load(&_cancelled) && session.joinsCompleteReceived &&
        session.expectedConnections > 0) {
        session.expectedConnections--;
    }
    if (session.activeConnections > 0) session.activeConnections--;
    [session.lock unlock];
    if (firstFatal) [session shutdownAllFds];
    [self maybeFinalizeSession:session];
}

- (void)maybeFinalizeSession:(WQMVTransferSession *)session
{
    [session.lock lock];
    if (session.finalized) {
        [session.lock unlock];
        return;
    }
    BOOL fatalDone = session.fatalError != nil && session.activeConnections == 0;
    BOOL cleanDone = session.fatalError == nil && session.joinsCompleteReceived &&
                     session.expectedConnections > 0 &&
                     session.doneConnections == session.expectedConnections;
    if (!fatalDone && !cleanDone) {
        [session.lock unlock];
        return;
    }
    session.finalized = YES;
    NSString *fatalError = session.fatalError;
    [session.lock unlock];
    [self finalizeSession:session fatalError:fatalError];
}

- (void)finalizeSession:(WQMVTransferSession *)session fatalError:(NSString *_Nullable)fatalError
{
    id<WQMVTransferReceiverStore> store = session.store;
    // Settle folders never eagerly installed: complete ones install,
    // everything else is discarded and reported failed. No connection
    // loop is running any more, so the counters are stable here.
    [session.lock lock];
    NSArray<WQMVTransferFolderInfo *> *folders = [session.request.folders copy];
    NSSet<NSString *> *settled = [session.settledFolders copy];
    NSDictionary<NSString *, NSNumber *> *dirs = [session.dirsByFolder copy];
    NSDictionary<NSString *, NSNumber *> *files = [session.filesByFolder copy];
    NSDictionary<NSString *, NSNumber *> *bytes = [session.bytesByFolder copy];
    [session.lock unlock];
    for (WQMVTransferFolderInfo *info in folders) {
        if ([settled containsObject:info.name]) continue;
        BOOL complete = [dirs[info.name] unsignedLongLongValue] == info.dirCount &&
                        [files[info.name] unsignedLongLongValue] == info.fileCount &&
                        [bytes[info.name] unsignedLongLongValue] == info.totalBytes;
        NSDictionary *result = nil;
        if (complete && !fatalError) {
            [session.installLock lock];
            NSDictionary *installed = [store installStagedFolder:info.name];
            if (![installed[@"ok"] boolValue]) [store discardStagedFolder:info.name];
            [session.installLock unlock];
            NSMutableDictionary *withFolder = [installed mutableCopy];
            withFolder[@"folder"] = info.name;
            result = withFolder;
        } else {
            [session.installLock lock];
            [store discardStagedFolder:info.name];
            [session.installLock unlock];
            result = @{@"folder": info.name, @"ok": @NO,
                       @"reason": fatalError.length ? fatalError : @"收到的字节数与发送方不一致",
                       @"backupName": [NSNull null]};
        }
        [session.lock lock];
        [session.results addObject:result];
        [session.settledFolders addObject:info.name];
        [session.lock unlock];
    }
    [store finishStaging];
    [NSFileManager.defaultManager removeItemAtPath:session.tempDir error:nil];
    [session.lock lock];
    NSArray<NSDictionary *> *results = [session.results copy];
    int controlFd = session.controlFd;
    NSArray<NSNumber *> *fds = [session.fds copy];
    [session.lock unlock];
    if (!fatalError) {
        (void)WQMVTransferWriteFrame(controlFd, @{@"results": results});
    }
    for (NSNumber *fd in fds) {
        if (fd.intValue >= 0) close(fd.intValue);
    }
    atomic_store(&_currentFd, -1);
    [_stateLock lock];
    if (_session == session) _session = nil;
    [_stateLock unlock];
    atomic_store(&_busy, false);
    WQMVTransferCompletionBlock completion = session.completionHandler;
    if (completion && results) completion(results, fatalError);
    else if (completion && fatalError) completion(@[], fatalError);
}

@end

#pragma mark - Sender

@interface WQMVTransferEntry : NSObject
@property (nonatomic, copy) NSString *folder;
@property (nonatomic, copy) NSString *relPath; // includes the folder name prefix
@property (nonatomic, copy, nullable) NSString *absPath; // files only
@property (nonatomic) unsigned long long size;
@property (nonatomic) BOOL isDir;
@end

@implementation WQMVTransferEntry
@end

@implementation WQMVTransferFolderSource
@end

// Shared send queue for the parallel workers: entries are pulled under
// the lock, each exactly once. Progress and failure state live here so
// the workers never touch the sender's ivars concurrently.
@interface WQMVTransferSendState : NSObject
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, copy) NSArray<WQMVTransferEntry *> *entries;
@property (nonatomic) NSUInteger nextIndex;
@property (nonatomic) unsigned long long sentBytes;
@property (nonatomic) CFAbsoluteTime lastProgress;
@property (nonatomic, copy, nullable) NSString *fatalError;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *remainingByFolder;
@property (nonatomic, strong) NSMutableSet<NSString *> *fullyWrittenFolders;
- (instancetype)initWithEntries:(NSArray<WQMVTransferEntry *> *)entries;
- (WQMVTransferEntry *_Nullable)nextEntry;
@end

@implementation WQMVTransferSendState

- (instancetype)initWithEntries:(NSArray<WQMVTransferEntry *> *)entries
{
    self = [super init];
    if (self) {
        _lock = [NSLock new];
        _entries = [entries copy];
        _remainingByFolder = [NSMutableDictionary dictionary];
        _fullyWrittenFolders = [NSMutableSet set];
        for (WQMVTransferEntry *entry in entries) {
            _remainingByFolder[entry.folder] = @([_remainingByFolder[entry.folder] unsignedIntegerValue] + 1);
        }
    }
    return self;
}

- (WQMVTransferEntry *_Nullable)nextEntry
{
    [self.lock lock];
    WQMVTransferEntry *entry = nil;
    if (self.nextIndex < self.entries.count) entry = self.entries[self.nextIndex++];
    [self.lock unlock];
    return entry;
}

@end

@implementation WQMVTransferSender {
    WQMVTransferPeer *_peer;
    NSArray<WQMVTransferFolderSource *> *_folders;
    atomic_bool _cancelled;
    NSLock *_fdsLock;
    NSMutableArray<NSNumber *> *_socketFds;
}

- (instancetype)initWithPeer:(WQMVTransferPeer *)peer
                     folders:(NSArray<WQMVTransferFolderSource *> *)folders
{
    self = [super init];
    if (self) {
        _peer = peer;
        _folders = [folders copy];
        atomic_init(&_cancelled, false);
        _fdsLock = [NSLock new];
        _socketFds = [NSMutableArray array];
    }
    return self;
}

- (void)cancel
{
    atomic_store(&_cancelled, true);
    [_fdsLock lock];
    NSArray<NSNumber *> *fds = [_socketFds copy];
    [_fdsLock unlock];
    for (NSNumber *fd in fds) {
        if (fd.intValue >= 0) (void)shutdown(fd.intValue, SHUT_RDWR);
    }
}

- (void)rememberSocketFd:(int)fd
{
    [_fdsLock lock];
    [_socketFds addObject:@(fd)];
    [_fdsLock unlock];
}

- (void)forgetSocketFd:(int)fd
{
    [_fdsLock lock];
    [_socketFds removeObject:@(fd)];
    [_fdsLock unlock];
}


// Recursive traversal with wq_list/wq_stat. Directories are emitted
// before their contents (pre-order). Names are sorted for a
// deterministic traversal order; runWithCompletion re-sorts all entries
// into the shared send queue (directories first, then files largest
// first). Symlinks and other non-regular files are counted as skipped
// and never followed. Returns NO when the tree cannot be listed at all.
- (BOOL)collectFolder:(WQMVTransferFolderSource *)source
              entries:(NSMutableArray<WQMVTransferEntry *> *)entries
                 info:(WQMVTransferFolderInfo *)info
{
    WQMVTransferEntry *root = [WQMVTransferEntry new];
    root.folder = source.name;
    root.relPath = source.name;
    root.size = 0;
    root.isDir = YES;
    [entries addObject:root];
    info.dirCount = 1; // the folder root itself
    return [self walkDirectory:source.rootPath
                     relPrefix:source.name
                        folder:source.name
                       entries:entries
                          info:info
                         depth:0];
}

- (BOOL)walkDirectory:(NSString *)absDir
            relPrefix:(NSString *)relPrefix
               folder:(NSString *)folder
              entries:(NSMutableArray<WQMVTransferEntry *> *)entries
                 info:(WQMVTransferFolderInfo *)info
                depth:(NSInteger)depth
{
    if (depth > kWQMVTransferMaxDepth) return NO;
    NSString *error = nil;
    NSArray<NSString *> *names = wq_list(absDir, &error);
    if (!names) return NO;
    NSArray<NSString *> *sorted = [names sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sorted) {
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
        NSString *full = [absDir stringByAppendingPathComponent:name];
        NSString *relPath = [relPrefix stringByAppendingPathComponent:name];
        struct stat st;
        if (!wq_stat(full, &st)) {
            info.skippedCount++;
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            WQMVTransferEntry *entry = [WQMVTransferEntry new];
            entry.folder = folder;
            entry.relPath = relPath;
            entry.size = 0;
            entry.isDir = YES;
            [entries addObject:entry];
            info.dirCount++;
            if (![self walkDirectory:full relPrefix:relPath folder:folder entries:entries info:info depth:depth + 1]) {
                return NO;
            }
        } else if (S_ISREG(st.st_mode)) {
            WQMVTransferEntry *entry = [WQMVTransferEntry new];
            entry.folder = folder;
            entry.relPath = relPath;
            entry.absPath = full;
            entry.size = (unsigned long long)st.st_size;
            entry.isDir = NO;
            [entries addObject:entry];
            info.fileCount++;
            info.totalBytes += (unsigned long long)st.st_size;
        } else {
            // Symlinks, sockets, devices: never followed, never sent.
            info.skippedCount++;
        }
    }
    return YES;
}

- (int)connectToPeer
{
    NSArray<NSData *> *addresses = _peer.service.addresses;
    for (NSData *address in addresses) {
        if (address.length < sizeof(struct sockaddr)) continue;
        const struct sockaddr *sockAddr = (const struct sockaddr *)address.bytes;
        int fd = socket(sockAddr->sa_family, SOCK_STREAM, 0);
        if (fd < 0) continue;
        int noSigPipe = 1;
        (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, sockAddr, (socklen_t)address.length);
        if (rc != 0 && errno == EINPROGRESS) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(fd, &writeSet);
            struct timeval timeout = { .tv_sec = 10, .tv_usec = 0 };
            int ready = select(fd + 1, NULL, &writeSet, NULL, &timeout);
            if (ready > 0) {
                int soError = 0;
                socklen_t soErrorLen = sizeof(soError);
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 && soError == 0) {
                    rc = 0;
                } else {
                    rc = -1;
                }
            } else {
                rc = -1;
            }
        }
        if (rc != 0) {
            close(fd);
            continue;
        }
        if (flags >= 0) (void)fcntl(fd, F_SETFL, flags);
        WQMVTransferSetSocketTimeouts(fd, 180, 120);
        return fd;
    }
    return -1;
}

// Opens one extra connection and joins the session the control
// connection already opened. Returns the fd, or -1 when the join fails
// (the transfer continues with fewer connections).
- (int)connectJoinToPeer:(NSString *)sessionID
{
    int fd = [self connectToPeer];
    if (fd < 0) return -1;
    // The join handshake must fail fast: a peer that accepted the
    // control connection answers at once; a hung join must not stall
    // the start of the stream.
    WQMVTransferSetSocketTimeouts(fd, 10, 10);
    BOOL joined = NO;
    if (WQMVTransferWriteFrame(fd, @{@"magic": kWQMVTransferMagic,
                                     @"version": @(kWQMVTransferVersion),
                                     @"join": sessionID})) {
        NSDictionary *reply = nil;
        if (WQMVTransferReadFrame(fd, &reply) == WQMVTransferFrameReadOK && reply) {
            (void)WQMVTransferJSONBool(reply, @"joined", &joined);
        }
    }
    if (!joined) {
        close(fd);
        return -1;
    }
    WQMVTransferSetSocketTimeouts(fd, 180, 120);
    return fd;
}

// Adds streamed bytes to the shared progress total, reporting at most
// every 0.25 s (the same throttle as the old single-stream sender).
- (void)noteBytesSent:(unsigned long long)count
                entry:(WQMVTransferEntry *)entry
                state:(WQMVTransferSendState *)state
                total:(unsigned long long)totalBytes
             manifest:(NSArray<WQMVTransferFolderInfo *> *)manifest
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    unsigned long long sent = 0;
    BOOL report = NO;
    [state.lock lock];
    state.sentBytes += count;
    if (now - state.lastProgress >= 0.25) {
        state.lastProgress = now;
        sent = state.sentBytes;
        report = YES;
    }
    [state.lock unlock];
    if (report) [self reportProgressSent:sent total:totalBytes manifest:manifest folder:entry.folder];
}

// Marks one entry fully written: the folder joins `fullyWrittenFolders`
// when its last entry is written, which the fallback message uses when
// the receiver never confirms.
- (void)noteEntrySent:(WQMVTransferEntry *)entry
                state:(WQMVTransferSendState *)state
                total:(unsigned long long)totalBytes
             manifest:(NSArray<WQMVTransferFolderInfo *> *)manifest
       reportProgress:(BOOL)reportProgress
{
    unsigned long long sent = 0;
    [state.lock lock];
    NSUInteger remaining = [state.remainingByFolder[entry.folder] unsignedIntegerValue];
    if (remaining > 0) remaining--;
    state.remainingByFolder[entry.folder] = @(remaining);
    if (remaining == 0) [state.fullyWrittenFolders addObject:entry.folder];
    sent = state.sentBytes;
    [state.lock unlock];
    if (reportProgress) [self reportProgressSent:sent total:totalBytes manifest:manifest folder:entry.folder];
}

// Streams one queue entry on one connection. Returns YES when the entry
// was fully written. On NO, *error carries a new fatal error, or nil
// when the worker stopped only because another worker already failed
// or the transfer was cancelled (nothing new to report). Each file is
// opened BEFORE its header is sent, so a file that cannot be read aborts
// the transfer instead of leaving the receiver waiting for bytes that
// never come.
- (BOOL)streamEntry:(WQMVTransferEntry *)entry
                 fd:(int)fd
              state:(WQMVTransferSendState *)state
              total:(unsigned long long)totalBytes
           manifest:(NSArray<WQMVTransferFolderInfo *> *)manifest
              error:(NSString *_Nullable *_Nullable)outError
{
    if (outError) *outError = nil;
    [state.lock lock];
    BOOL stopped = atomic_load(&_cancelled) || state.fatalError != nil;
    [state.lock unlock];
    if (stopped) return NO;
    if (entry.isDir) {
        NSDictionary *header = @{@"folder": entry.folder, @"relPath": entry.relPath,
                                 @"size": @0, @"isDir": @YES};
        if (!WQMVTransferWriteFrame(fd, header)) {
            if (outError) *outError = atomic_load(&_cancelled) ? @"已取消" : @"连接中断";
            return NO;
        }
        [self noteEntrySent:entry state:state total:totalBytes manifest:manifest reportProgress:NO];
        return YES;
    }
    int inFd = wq_open_for_reading(entry.absPath);
    if (inFd < 0) {
        if (outError) *outError = @"读不到文件";
        return NO;
    }
    NSDictionary *header = @{@"folder": entry.folder, @"relPath": entry.relPath,
                             @"size": @(entry.size), @"isDir": @NO};
    BOOL ok = WQMVTransferWriteFrame(fd, header);
    NSString *_Nullable failure = nil;
    uint8_t *buffer = NULL;
    if (ok) {
        buffer = (uint8_t *)malloc(kWQMVTransferChunkBytes);
        ok = buffer != NULL;
        if (!ok) failure = @"内存不足";
    }
    unsigned long long remaining = entry.size;
    while (ok && remaining > 0) {
        [state.lock lock];
        BOOL peerFailed = state.fatalError != nil;
        [state.lock unlock];
        if (atomic_load(&_cancelled)) {
            ok = NO;
            failure = @"已取消";
            break;
        }
        if (peerFailed) {
            ok = NO;
            break; // failure stays nil: another worker owns the error
        }
        size_t want = remaining > kWQMVTransferChunkBytes ? kWQMVTransferChunkBytes : (size_t)remaining;
        ssize_t n = read(inFd, buffer, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            ok = NO;
            failure = @"读不到文件";
            break;
        }
        if (n == 0) {
            // The file shrank while being read; the receiver would
            // wait forever for the declared bytes, so abort.
            ok = NO;
            failure = @"文件在传输中变了";
            break;
        }
        if (!WQMVTransferWriteAll(fd, buffer, (size_t)n)) {
            ok = NO;
            failure = atomic_load(&_cancelled) ? @"已取消" : @"连接中断";
            break;
        }
        remaining -= (unsigned long long)n;
        [self noteBytesSent:(unsigned long long)n entry:entry state:state total:totalBytes manifest:manifest];
    }
    if (buffer) free(buffer);
    close(inFd);
    if (!ok) {
        if (outError) *outError = failure;
        return NO;
    }
    [self noteEntrySent:entry state:state total:totalBytes manifest:manifest reportProgress:YES];
    return YES;
}

- (void)startWithCompletion:(WQMVTransferCompletionBlock)completion
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf runWithCompletion:completion];
    });
}

- (void)runWithCompletion:(WQMVTransferCompletionBlock)completion
{
    // Phase 1: traverse every selected folder on this background queue.
    // A folder whose tree cannot be listed is excluded from the request
    // and reported failed; the others still go.
    NSMutableArray<WQMVTransferFolderInfo *> *manifest = [NSMutableArray array];
    NSMutableArray<WQMVTransferEntry *> *entries = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *prepareFailures = [NSMutableDictionary dictionary];
    for (WQMVTransferFolderSource *source in _folders) {
        if (atomic_load(&_cancelled)) break;
        WQMVTransferFolderInfo *info = [WQMVTransferFolderInfo new];
        info.name = source.name;
        NSMutableArray<WQMVTransferEntry *> *folderEntries = [NSMutableArray array];
        if ([self collectFolder:source entries:folderEntries info:info]) {
            [manifest addObject:info];
            [entries addObjectsFromArray:folderEntries];
        } else {
            prepareFailures[source.name] = @"读不到这个文件夹";
        }
    }
    if (atomic_load(&_cancelled)) {
        completion([self cancelledResultsForFolders:_folders], @"已取消");
        return;
    }
    if (!manifest.count) {
        NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
        for (WQMVTransferFolderSource *source in _folders) {
            [results addObject:@{@"folder": source.name, @"ok": @NO,
                                 @"reason": prepareFailures[source.name] ?: @"读不到这个文件夹",
                                 @"backupName": [NSNull null], @"skipped": @0}];
        }
        completion(results, nil);
        return;
    }
    unsigned long long totalBytes = 0;
    unsigned long long totalFiles = 0;
    NSMutableArray<NSDictionary *> *folderJSON = [NSMutableArray array];
    for (WQMVTransferFolderInfo *info in manifest) {
        totalBytes += info.totalBytes;
        totalFiles += info.fileCount;
        [folderJSON addObject:@{@"name": info.name,
                                @"fileCount": @(info.fileCount),
                                @"totalBytes": @(info.totalBytes),
                                @"skipped": @(info.skippedCount),
                                @"dirCount": @(info.dirCount)}];
    }
    // Shared queue order: directories first (all folders), then files
    // largest first, so no worker idles on one big video while the
    // others finish; ties break by path for a deterministic order.
    NSArray<WQMVTransferEntry *> *queue = [entries sortedArrayUsingComparator:^NSComparisonResult(WQMVTransferEntry *a, WQMVTransferEntry *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        if (!a.isDir && a.size != b.size) return a.size > b.size ? NSOrderedAscending : NSOrderedDescending;
        return [a.relPath compare:b.relPath];
    }];

    // Phase 2: connect and send the request on connection 1.
    NSString *sessionID = NSUUID.UUID.UUIDString;
    int controlFd = [self connectToPeer];
    if (controlFd < 0) {
        completion([self failedResultsForManifest:manifest
                                            reason:@"连不上对方设备，请重新选一次设备"
                                 prepareFailures:prepareFailures], nil);
        return;
    }
    [self rememberSocketFd:controlFd];
    NSDictionary *request = @{@"magic": kWQMVTransferMagic,
                              @"version": @(kWQMVTransferVersion),
                              @"session": sessionID,
                              @"deviceName": UIDevice.currentDevice.name ?: @"iPhone",
                              @"folders": folderJSON,
                              @"totalBytes": @(totalBytes),
                              @"totalFiles": @(totalFiles)};
    NSString *_Nullable fatalError = nil;
    if (!WQMVTransferWriteFrame(controlFd, request)) {
        fatalError = @"连接中断";
    }
    NSDictionary *reply = nil;
    if (!fatalError) {
        if (WQMVTransferReadFrame(controlFd, &reply) != WQMVTransferFrameReadOK || !reply) {
            fatalError = atomic_load(&_cancelled) ? @"已取消" : @"连接中断";
        }
    }
    BOOL accepted = NO;
    NSString *rejectReason = nil;
    if (!fatalError) {
        if (!WQMVTransferJSONBool(reply, @"accepted", &accepted)) {
            fatalError = @"收到无法识别的回复";
        } else if (!accepted) {
            (void)WQMVTransferJSONString(reply, @"reason", &rejectReason);
        }
    }
    if (!fatalError && !accepted) {
        close(controlFd);
        [self forgetSocketFd:controlFd];
        completion([self failedResultsForManifest:manifest
                                            reason:rejectReason.length ? rejectReason : @"对方拒绝了接收"
                                 prepareFailures:prepareFailures], nil);
        return;
    }

    NSMutableArray<NSNumber *> *fds = nil;
    WQMVTransferSendState *state = nil;
    NSArray<NSDictionary *> *results = nil;
    if (!fatalError) {
        // Phase 2b: open the join connections. A failed join is
        // skipped: the transfer continues with the connections that
        // succeeded (at least the control connection).
        fds = [NSMutableArray arrayWithObject:@(controlFd)];
        for (NSUInteger i = 1; i < kWQMVTransferConnectionCount; i++) {
            if (atomic_load(&_cancelled)) break;
            int joinFd = [self connectJoinToPeer:sessionID];
            if (joinFd < 0) continue;
            [self rememberSocketFd:joinFd];
            [fds addObject:@(joinFd)];
        }
        if (atomic_load(&_cancelled)) {
            fatalError = @"已取消";
        } else if (!WQMVTransferWriteFrame(controlFd, @{@"joinsComplete": @YES, @"connections": @(fds.count)})) {
            fatalError = @"连接中断";
        }
    }
    if (!fatalError) {
        // Phase 3: one worker per connection, pulling entries from the
        // shared queue until it is empty. Each worker reports done on
        // its own connection only when it exhausted the queue cleanly;
        // a failed worker sends nothing and the receiver finalizes on
        // the broken stream.
        state = [[WQMVTransferSendState alloc] initWithEntries:queue];
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t workQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        for (NSNumber *fdNumber in fds) {
            int fd = fdNumber.intValue;
            dispatch_group_async(group, workQueue, ^{
                for (;;) {
                    WQMVTransferEntry *entry = [state nextEntry];
                    if (!entry) break;
                    NSString *entryError = nil;
                    if (![self streamEntry:entry fd:fd state:state total:totalBytes manifest:manifest error:&entryError]) {
                        if (entryError) {
                            [state.lock lock];
                            if (!state.fatalError) state.fatalError = entryError;
                            [state.lock unlock];
                        }
                        break;
                    }
                }
                [state.lock lock];
                BOOL clean = !atomic_load(&_cancelled) && state.fatalError == nil;
                [state.lock unlock];
                if (clean) {
                    if (!WQMVTransferWriteFrame(fd, @{@"done": @YES})) {
                        [state.lock lock];
                        if (!state.fatalError) state.fatalError = @"连接中断";
                        [state.lock unlock];
                    }
                }
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        [state.lock lock];
        fatalError = state.fatalError;
        [state.lock unlock];
        if (!fatalError && atomic_load(&_cancelled)) fatalError = @"已取消";
    }

    // Phase 4: the receiver's per-folder results arrive on the control
    // connection after every connection reported done.
    if (!fatalError) {
        NSDictionary *resultJSON = nil;
        if (WQMVTransferReadFrame(controlFd, &resultJSON) == WQMVTransferFrameReadOK && resultJSON) {
            id resultValue = resultJSON[@"results"];
            if ([resultValue isKindOfClass:[NSArray class]]) {
                results = [self validatedResults:(NSArray *)resultValue manifest:manifest];
            }
        }
        if (!results) {
            fatalError = @"未收到接收方确认";
        }
    }
    NSArray<NSNumber *> *fdsToClose = fds ?: @[@(controlFd)];
    for (NSNumber *fdNumber in fdsToClose) {
        close(fdNumber.intValue);
        [self forgetSocketFd:fdNumber.intValue];
    }

    if (!results) {
        // The transfer broke before the receiver confirmed anything.
        // Folders fully written may or may not be installed over there;
        // say so honestly instead of claiming success or failure.
        NSSet<NSString *> *fullyWrittenFolders = state.fullyWrittenFolders ?: [NSSet set];
        NSMutableArray<NSDictionary *> *fallback = [NSMutableArray array];
        for (WQMVTransferFolderInfo *info in manifest) {
            NSString *reason = nil;
            if ([fullyWrittenFolders containsObject:info.name]) {
                reason = [NSString stringWithFormat:@"%@，请在对方手机上查看接收结果",
                          fatalError.length ? fatalError : @"传输中断"];
            } else {
                reason = fatalError.length ? fatalError : @"传输中断";
            }
            [fallback addObject:@{@"folder": info.name, @"ok": @NO, @"reason": reason,
                                  @"backupName": [NSNull null], @"skipped": @(info.skippedCount)}];
        }
        for (NSString *name in prepareFailures) {
            [fallback addObject:@{@"folder": name, @"ok": @NO, @"reason": prepareFailures[name],
                                  @"backupName": [NSNull null], @"skipped": @0}];
        }
        // Keep the original selection order in the status page.
        NSMutableArray<NSDictionary *> *ordered = [NSMutableArray array];
        for (WQMVTransferFolderSource *source in _folders) {
            for (NSDictionary *result in fallback) {
                if ([result[@"folder"] isEqualToString:source.name]) [ordered addObject:result];
            }
        }
        completion(ordered, nil);
        return;
    }
    // Merge prepare failures and skipped counts into the confirmed results.
    NSMutableArray<NSDictionary *> *merged = [NSMutableArray array];
    for (WQMVTransferFolderSource *source in _folders) {
        NSDictionary *confirmed = nil;
        for (NSDictionary *result in results) {
            if ([result[@"folder"] isEqualToString:source.name]) {
                confirmed = result;
                break;
            }
        }
        if (confirmed) {
            NSMutableDictionary *withSkipped = [confirmed mutableCopy];
            for (WQMVTransferFolderInfo *info in manifest) {
                if ([info.name isEqualToString:source.name]) {
                    withSkipped[@"skipped"] = @(info.skippedCount);
                    break;
                }
            }
            [merged addObject:withSkipped];
        } else {
            [merged addObject:@{@"folder": source.name, @"ok": @NO,
                                @"reason": prepareFailures[source.name] ?: @"未收到接收方确认",
                                @"backupName": [NSNull null], @"skipped": @0}];
        }
    }
    completion(merged, nil);
}

- (void)reportProgressSent:(unsigned long long)sent
                     total:(unsigned long long)total
                  manifest:(NSArray<WQMVTransferFolderInfo *> *)manifest
                    folder:(NSString *)folder
{
    WQMVTransferProgressBlock progress = self.progressHandler;
    if (!progress) return;
    NSUInteger index = 0;
    for (NSUInteger i = 0; i < manifest.count; i++) {
        if ([manifest[i].name isEqualToString:folder]) {
            index = i;
            break;
        }
    }
    progress(sent, total, index, manifest.count, folder);
}

- (NSArray<NSDictionary *> *)validatedResults:(NSArray *)raw
                                     manifest:(NSArray<WQMVTransferFolderInfo *> *)manifest
{
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (WQMVTransferFolderInfo *info in manifest) [known addObject:info.name];
    for (id entry in raw) {
        if (![entry isKindOfClass:[NSDictionary class]]) return nil;
        NSDictionary *dict = (NSDictionary *)entry;
        NSString *folder = nil;
        BOOL ok = NO;
        if (!WQMVTransferJSONString(dict, @"folder", &folder) || ![known containsObject:folder]) return nil;
        if (!WQMVTransferJSONBool(dict, @"ok", &ok)) return nil;
        NSString *reason = nil;
        (void)WQMVTransferJSONString(dict, @"reason", &reason);
        NSString *backupName = nil;
        (void)WQMVTransferJSONString(dict, @"backupName", &backupName);
        [results addObject:@{@"folder": folder, @"ok": @(ok),
                             @"reason": reason ?: @"",
                             @"backupName": backupName ?: [NSNull null]}];
    }
    if (results.count != manifest.count) return nil;
    return results;
}

- (NSArray<NSDictionary *> *)failedResultsForManifest:(NSArray<WQMVTransferFolderInfo *> *)manifest
                                               reason:(NSString *)reason
                                    prepareFailures:(NSDictionary<NSString *, NSString *> *)prepareFailures
{
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    for (WQMVTransferFolderSource *source in _folders) {
        NSString *prepareReason = prepareFailures[source.name];
        if (prepareReason) {
            [results addObject:@{@"folder": source.name, @"ok": @NO, @"reason": prepareReason,
                                 @"backupName": [NSNull null], @"skipped": @0}];
        } else {
            NSUInteger skipped = 0;
            for (WQMVTransferFolderInfo *info in manifest) {
                if ([info.name isEqualToString:source.name]) {
                    skipped = info.skippedCount;
                    break;
                }
            }
            [results addObject:@{@"folder": source.name, @"ok": @NO, @"reason": reason,
                                 @"backupName": [NSNull null], @"skipped": @(skipped)}];
        }
    }
    return results;
}

- (NSArray<NSDictionary *> *)cancelledResultsForFolders:(NSArray<WQMVTransferFolderSource *> *)folders
{
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    for (WQMVTransferFolderSource *source in folders) {
        [results addObject:@{@"folder": source.name, @"ok": @NO, @"reason": @"已取消",
                             @"backupName": [NSNull null], @"skipped": @0}];
    }
    return results;
}

@end
