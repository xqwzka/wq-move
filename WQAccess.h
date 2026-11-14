//
//  WQAccess.h
//  WQ Files
//
//  File access outside the sandbox through the worse_query technique by
//  Taj C (forcequit), https://github.com/forcequitOS/worse_query,
//  GPL-3.0-or-later. This reimplementation is GPL-3.0-or-later as well.
//

#import <Foundation/Foundation.h>
#import "WQLaunchServices.h"
#import <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

// Log shared with the UI.
void wq_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *wq_log_text(void);

// Picks the app group the signer actually gave us. Nil when there is none.
NSString *_Nullable wq_app_group(void);

// Asks for a sandbox extension covering path (once per path). Returns YES
// when one is held for it.
BOOL wq_grant(NSString *path);

// Directory listing; asks for access when the plain call is refused.
NSArray<NSString *> *_Nullable wq_list(NSString *dir, NSString *_Nullable *_Nullable errorText);

// Reads a whole file (up to maxBytes; 0 = no limit).
NSData *_Nullable wq_read(NSString *path, NSUInteger maxBytes, NSString *_Nullable *_Nullable errorText);

// A file's identity, size and change timestamps, for optimistic concurrency.
NSDictionary<NSString *, NSNumber *> *_Nullable wq_file_version(NSString *path);

// Overwrites a file in place (same inode, owner and xattrs). The previous
// contents are backed up first, and a failed write attempts to roll back.
// Mutation/backup/rollback use one verified regular-file descriptor and an
// advisory lock where supported. The _if_unchanged forms reject a stale expected
// version before mutation; nil keeps the legacy unconditional behavior. This is
// not an atomic transaction against uncooperative external writers or crashes.
// Backup-storage files cannot be overwritten/deleted through these generic APIs.
BOOL wq_write(NSString *path, NSData *data, NSString *_Nullable *_Nullable errorText);
BOOL wq_write_if_unchanged(NSString *path, NSData *data, NSDictionary<NSString *, NSNumber *> *_Nullable expected,
                           NSString *_Nullable *_Nullable errorText);
// Verifies saved bytes against the intended contents while the descriptor stays
// locked, returning that descriptor's version (never a later pathname sample).
// The returned snapshot still detects later external changes on the next save.
BOOL wq_write_if_unchanged_get_version(NSString *path, NSData *data,
    NSDictionary<NSString *, NSNumber *> *_Nullable expected,
    NSDictionary<NSString *, NSNumber *> *_Nullable *_Nullable savedVersion,
    NSString *_Nullable *_Nullable errorText);

// Same as wq_write / wq_create_file, but streamed from a local file (for large
// files; nothing is held in memory). A failed create leaves no partial file.
BOOL wq_write_from_file(NSString *path, NSString *source, NSString *_Nullable *_Nullable errorText);
// As wq_write_from_file; *backupUnit gets the backup folder (Backups/<stamp>)
// holding the previous contents, so a caller may remove it after success.
BOOL wq_write_from_file_with_backup(NSString *path, NSString *source, NSString *_Nullable *_Nullable backupUnit,
                                    NSString *_Nullable *_Nullable errorText);
BOOL wq_create_file_from(NSString *path, NSString *source, NSString *_Nullable *_Nullable errorText);
// Streams a regular file into a staged local path, then replaces the destination.
// Same-file aliases are refused; failed streaming leaves the destination intact.
BOOL wq_copy_to_local(NSString *path, NSString *dest, NSString *_Nullable *_Nullable errorText);

// When Unix permissions (not the sandbox) keep this app out of `path`: an
// explanation for the user; nil if the owner and mode allow it.
NSString *_Nullable wq_permission_hint(NSString *path, BOOL forWriting);

// Reads `length` bytes at `offset` (fewer at the end of the file).
NSData *_Nullable wq_read_range(NSString *path, unsigned long long offset, NSUInteger length,
                                NSString *_Nullable *_Nullable errorText);
// Overwrites bytes in place: offset -> replacement bytes. The file keeps its
// size; it is backed up first, and flush/close errors are reported.
BOOL wq_patch(NSString *path, NSDictionary<NSNumber *, NSData *> *runs, NSString *_Nullable *_Nullable errorText);
BOOL wq_patch_if_unchanged(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
                           NSDictionary<NSString *, NSNumber *> *_Nullable expected, NSString *_Nullable *_Nullable errorText);
BOOL wq_patch_if_unchanged_get_version(NSString *path, NSDictionary<NSNumber *, NSData *> *runs,
    NSDictionary<NSString *, NSNumber *> *_Nullable expected,
    NSDictionary<NSString *, NSNumber *> *_Nullable *_Nullable savedVersion,
    NSString *_Nullable *_Nullable errorText);

// Creates a new file or folder inside dir.
BOOL wq_create_file(NSString *path, NSData *data, NSString *_Nullable *_Nullable errorText);
BOOL wq_create_dir(NSString *path, NSString *_Nullable *_Nullable errorText);

// Deletes a file (backed up first) or an empty folder.
BOOL wq_delete(NSString *path, NSString *_Nullable *_Nullable errorText);
// YES for a folder that represents one backup unit: a stamp directly under
// the file backup root, or a bundle/date folder directly under the app backup
// root. Used by the backup browser's multi-selection.
BOOL wq_backup_unit_deletable(NSString *path);
// Explicit, user-confirmed removal of one backup unit. Unlike wq_delete, this
// is allowed inside a backup store and removes the whole subtree. No safety
// copy is made.
BOOL wq_delete_backup(NSString *path, NSString *_Nullable *_Nullable errorText);
BOOL wq_rename(NSString *path, NSString *newName, NSString *_Nullable *_Nullable errorText);
// Moves a file or folder into destDir (same volume), keeping its name. Never
// replaces an existing item; refuses moves into itself and into backups.
BOOL wq_move(NSString *path, NSString *destDir, NSString *_Nullable *_Nullable errorText);
// Read-only descriptor for a regular file (asks for access when refused), or -1.
int wq_open_for_reading(NSString *path);

// lstat with access retry. Returns NO if the item does not exist.
BOOL wq_stat(NSString *path, struct stat *st);

// Thread-safe cancellation for expensive filesystem scans.
@interface WQScanCancellation : NSObject
@property (atomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

// Discovers direct children of dir by brute-forcing inode numbers with
// fsgetpath (not sandbox-gated), the way KAMUI/bad_query_list do. Needs no
// token on dir. maxInode bounds the scan (0 = up to the newest id on the
// volume); progress is called off the main thread, from several threads.
// Returns absolute child paths, sorted, or nil on failure/cancellation, including
// when the dynamic bound cannot be discovered. No implicit fixed-range fallback.
// With maxInode 0, the App Data, Extensions and Internal Daemons parents are
// scanned together in one pass, reused for 10 minutes (or until
// wq_enumerate_invalidate) and saved: later scans only check the ids created
// since the saved one (a full scan runs weekly). The scan keeps running when
// its caller cancels; concurrent callers wait for that one scan.
// Forget the shared container scan (App Data, Extensions, Internal Daemons),
// so the next wq_enumerate of those scans the ids created since. Call on a
// user's refresh.
void wq_enumerate_invalidate(void);
// NO on iOS 26: there worse_query can't reach System Data, the system groups
// or the App Groups parent folder (only the individual containers).
BOOL wq_system_areas_reachable(void);
NSArray<NSString *> *_Nullable wq_enumerate(NSString *dir, int64_t maxInode,
                                            WQScanCancellation *_Nullable cancellation,
                                            void (^_Nullable progress)(int64_t done, int64_t total, NSUInteger found));

typedef NS_ENUM(NSInteger, WQMeasureResult) {
    WQMeasureResultMissing,
    WQMeasureResultKnown,
    WQMeasureResultLimited,
    WQMeasureResultCancelled,
};

// Total byte size of regular files below dir. A missing directory is Missing
// (size 0); an unreadable subtree makes the result Limited instead of silently
// undercounting. Grants access when the root cannot be listed.
WQMeasureResult wq_measure_tree(NSString *dir, WQScanCancellation *_Nullable cancellation,
                                unsigned long long *_Nullable bytes);

// Deletes every item *inside* dir (dir itself stays). No backup — for caches.
// Adds freed bytes to *freed. A missing dir counts as done; NO if dir cannot
// be read or listed, ancestry contains links (except canonical /var), the target
// changes, or some items could not be removed. Child links are not followed.
BOOL wq_purge_contents(NSString *dir, unsigned long long *freed);
// Cancellable variant for long cache cleans; returns NO when cancelled.
BOOL wq_purge_contents_cancellable(NSString *dir, unsigned long long *freed,
                                   WQScanCancellation *_Nullable cancellation);

// Copies every item inside srcDir into dstDir (replacing same-named items).
// Each child is staged/flushed before installation; old children survive failed
// copies. This is not an all-children transaction: callers still own tree rollback.
// Either side may be another app's container. Returns NO if anything failed.
BOOL wq_copy_contents(NSString *srcDir, NSString *dstDir, NSString *_Nullable *_Nullable errorText);

// MCM container identifier (bundle or group id) of a container folder.
NSString *_Nullable wq_container_label(NSString *dir);
// Extra source for wq_container_label, tried after the identifier attribute and
// the container-manager table: path (/private/var/...) -> identifier or nil.
// iOS 26: where a full scan takes far too long, the App Data and Extensions
// lists come from this provider (the LaunchServices database). storeHint is a
// database path the scan found, or nil for the remembered one.
// Full scans (every file id; minutes on a well-used device) only start after
// `confirm` returns YES; it's called on a background thread with what is being
// listed, the number of ids and a rough duration. `progress` reports a running
// full scan and its end (finished = YES). Without these hooks no full scan runs.
void wq_set_full_scan_ui(BOOL (*_Nullable confirm)(NSString *what, int64_t ids, double seconds),
                         void (*_Nullable progress)(int64_t done, int64_t total, BOOL finished));
// Stops the running full scan (the scan window's Stop button).
void wq_full_scan_stop(void);
// Whether the last listing failed because a full scan wasn't confirmed.
BOOL wq_full_scan_was_declined(void);
void wq_set_container_list_provider(NSArray<NSString *> *_Nullable (*_Nullable provider)(NSString *_Nullable storeHint));
void wq_set_container_label_resolver(NSString *_Nullable (*_Nullable resolver)(NSString *path));

// Backups of overwritten or deleted files, mirrored by original path.
NSString *wq_backup_root(void);
// App backups live in Documents/AppBackups, a sibling of file backups.
NSString *wq_app_backup_root(void);
// YES inside either backup store. Generic create/write/delete/rename must be
// refused there so a backup cannot be recursively backed up or silently
// turned into a different restore source.
BOOL wq_is_backup_storage_path(NSString *path);
NSString *_Nullable wq_backup_original_path(NSString *backupPath);

NS_ASSUME_NONNULL_END
