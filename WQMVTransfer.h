//
//  WQMVTransfer.h
//  WQMove
//
//  Device-to-device transfer over the local network (test version,
//  plaintext, LAN only). Discovery is Bonjour (NSNetService); the data
//  plane is plain BSD sockets with a small length-prefixed JSON framing.
//  No new framework is linked: NSNetService lives in Foundation and the
//  sockets are POSIX, matching this codebase's fd-based style.
//
//  Wire format (version 2; both sides must run this build):
//  Frame: 4-byte big-endian length N, then N bytes of JSON payload.
//    Request (sender -> receiver, connection 1):
//      {magic:"WQMV", version:2, session:<UUID>, deviceName,
//       folders:[{name, fileCount, totalBytes, skipped, dirCount}],
//       totalBytes, totalFiles}
//      dirCount counts directory entries including the folder root.
//    Reply (receiver -> sender):
//      {accepted:BOOL, reason}
//    Join (sender -> receiver, connections 2-4):
//      {magic:"WQMV", version:2, join:<session>}
//    Join reply (receiver -> sender):
//      {joined:BOOL}
//    Joins complete (sender -> receiver, connection 1, before streaming):
//      {joinsComplete:true, connections:K} (K = connections that joined)
//    File entry (sender -> receiver, any connection):
//      header frame {folder, relPath, size, isDir} followed by exactly
//      `size` raw bytes (not part of the length-prefixed frame). Empty
//      directories are entries with isDir=true and size=0. relPath is
//      relative to the staging root and always starts with the folder
//      name; the folder root itself is sent as a directory entry.
//      Entries are whole files: a file is never split across
//      connections. Each connection sends {done:true} when it has
//      streamed everything it pulled from the shared queue.
//    Result (receiver -> sender on connection 1, after every
//      connection reported done):
//      {results:[{folder, ok, reason, backupName}]}
//  There are no per-file acknowledgements: the sender streams and the
//  receiver validates byte counts per file and in total. A folder is
//  installed only when fully received and validated.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One folder in a transfer request / result set.
@interface WQMVTransferFolderInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long fileCount; // regular files only
@property (nonatomic) unsigned long long totalBytes; // regular files only
@property (nonatomic) NSUInteger skippedCount; // non-regular items skipped by the sender
@property (nonatomic) unsigned long long dirCount; // directory entries, including the folder root
@end

@interface WQMVTransferRequest : NSObject
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) NSString *sessionID; // sender-minted UUID; join connections present it
@property (nonatomic, copy) NSArray<WQMVTransferFolderInfo *> *folders;
@property (nonatomic) unsigned long long totalBytes;
@property (nonatomic) unsigned long long totalFiles;
@end

// A discovered peer. Only resolved peers are exposed: `service.addresses`
// is populated and the TXT record has been read.
@interface WQMVTransferPeer : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSNetService *service;
@property (nonatomic, copy, nullable) NSString *model;
@end

// Persistent per-install identifier, published in the TXT record so a
// device never lists itself. Created once, kept in NSUserDefaults.
NSString *WQMVTransferOwnDeviceID(void);

// Service type without the trailing dot, for NSBonjourServices checks.
NSString *WQMVTransferServiceType(void);

#pragma mark - Discovery

// Browses for peers while started. The update block is called on the
// main thread whenever the resolved peer list changes. Create, start
// and stop on the main thread.
@interface WQMVTransferBrowser : NSObject
- (instancetype)initWithUpdate:(void (^)(NSArray<WQMVTransferPeer *> *peers))update;
- (void)start;
- (void)stop;
@property (nonatomic, copy, readonly) NSArray<WQMVTransferPeer *> *peers;
@end

#pragma mark - Receiver storage

// Filesystem side of receiving, implemented by the app (main.m) because
// only it knows the Files-container resolvers. All methods are called
// on the receiver's background queues. One transfer at a time: the store
// keeps the current staging root internally between createStagingDirectory
// and finishStaging. Directory creation and file stores may be called
// concurrently from up to 4 connections; folder installs are serialized
// by the receiver, so installStagedFolder/discardStagedFolder are never
// called for two folders at once.
@protocol WQMVTransferReceiverStore <NSObject>

// Create a fresh staging root for one transfer (under .receiving in
// the Files container, never inside the install destination). Returns
// the absolute path, or nil + error.
- (nullable NSString *)createStagingDirectoryWithError:(NSString *_Nullable *_Nullable)error;

// Create directories (parents included) for a relative path inside the
// staging root, e.g. "<folder>/sub/dir".
- (BOOL)createStagingDirectoriesForRelativePath:(NSString *)relativePath
                                          error:(NSString *_Nullable *_Nullable)error;

// Install one fully received file from a sandbox temp path into the
// staging tree at the given relative path (parents created as needed).
- (BOOL)storeReceivedFileFromTempPath:(NSString *)tempPath
                         relativePath:(NSString *)relativePath
                                error:(NSString *_Nullable *_Nullable)error;

// Install one complete staged folder into the destination the user
// chose for this transfer (a WeChat's Documents, or the 聊天记录 temp
// folder). A same-named folder already there is first moved aside into
// a timestamped folder under 被覆盖的聊天记录, exactly like a local
// move. Returns a result dictionary: @{@"ok": NSNumber,
// @"reason": NSString-or-NSNull, @"backupName": NSString-or-NSNull}.
- (NSDictionary *)installStagedFolder:(NSString *)folderName;

// Discard one staged folder (failed or incomplete). Never touches the
// install destination.
- (void)discardStagedFolder:(NSString *)folderName;

// Remove the staging root for this transfer (after all folders were
// installed or discarded).
- (void)finishStaging;

// Remove staging dirs left behind by earlier interrupted transfers.
// Only ever touches the staging parent directory.
- (void)cleanupStaleStaging;

@end

#pragma mark - Receiver

typedef void (^WQMVTransferDecisionBlock)(BOOL accept);
typedef void (^WQMVTransferRequestBlock)(WQMVTransferRequest *request,
                                         WQMVTransferDecisionBlock decision);
typedef void (^WQMVTransferProgressBlock)(unsigned long long done,
                                          unsigned long long total,
                                          NSUInteger folderIndex,
                                          NSUInteger folderCount,
                                          NSString *folderName);
typedef void (^WQMVTransferCompletionBlock)(NSArray<NSDictionary *> *results,
                                            NSString *_Nullable error);

// Publishes this device and accepts one transfer at a time. One session
// uses up to 4 parallel connections (see the wire format above); the
// request handler still runs once per session and must call its decision
// block exactly once. All handler blocks are invoked on background
// queues; UI code must hop to the main thread. start/stop must be called
// on the main thread.
@interface WQMVTransferReceiver : NSObject
- (instancetype)initWithStore:(id<WQMVTransferReceiverStore>)store;
@property (nonatomic, weak, nullable) id<WQMVTransferReceiverStore> store;
@property (nonatomic, copy, nullable) WQMVTransferRequestBlock requestHandler;
@property (nonatomic, copy, nullable) WQMVTransferProgressBlock progressHandler;
@property (nonatomic, copy, nullable) WQMVTransferCompletionBlock completionHandler;
- (void)start;
- (void)stop;
- (void)cancelCurrentTransfer;
@property (nonatomic, readonly) BOOL busy;
@end

#pragma mark - Sender

@interface WQMVTransferFolderSource : NSObject
@property (nonatomic, copy) NSString *name; // folder name (single component)
@property (nonatomic, copy) NSString *rootPath; // absolute path of the folder itself
@end

// Connects to one peer and streams folders over up to 4 parallel
// connections sharing one file queue. Progress and completion
// blocks are invoked on a background queue. The sender only reads the
// sources; it never modifies them.
@interface WQMVTransferSender : NSObject
- (instancetype)initWithPeer:(WQMVTransferPeer *)peer
                     folders:(NSArray<WQMVTransferFolderSource *> *)folders;
@property (nonatomic, copy, nullable) WQMVTransferProgressBlock progressHandler;
- (void)startWithCompletion:(WQMVTransferCompletionBlock)completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
