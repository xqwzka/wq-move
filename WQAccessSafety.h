// Portable implementation helpers for WQAccess; no privileged access is performed here.
#ifndef WQ_ACCESS_SAFETY_H
#define WQ_ACCESS_SAFETY_H
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static inline BOOL WQSameObject(const struct stat *a, const struct stat *b)
{
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

// Only Apple's documented /var alias is allowed. Do not standardize away '..'
// before walking: every actual ancestor must be opened without following links.
static inline NSString *WQCanonicalVarPath(NSString *path)
{
    if ([path isEqualToString:@"/var"] || [path hasPrefix:@"/var/"])
        return [@"/private" stringByAppendingString:path];
    return path;
}

static inline int WQOpenDirectoryNoLinksFlags(NSString *path, int flags)
{
    path = WQCanonicalVarPath(path);
    if (![path hasPrefix:@"/"] || [path rangeOfString:@"\0"].location != NSNotFound) { errno = EINVAL; return -1; }
    // Ancestors need traversal, not enumeration. A file/folder-specific sandbox
    // extension need not grant read-directory rights on all container parents.
    int fd = open("/", O_SEARCH | O_CLOEXEC);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        if ([part isEqualToString:@"."] || [part isEqualToString:@".."]) { close(fd); errno = EINVAL; return -1; }
        int next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        int err = errno;
        close(fd);
        if (next < 0) { errno = err; return -1; }
        fd = next;
    }
    if (flags == O_SEARCH) return fd;
    int result = openat(fd, ".", flags | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int err = errno;
    close(fd);
    if (result < 0) errno = err;
    return result;
}

static inline int WQOpenDirectoryNoLinks(NSString *path)
{
    return WQOpenDirectoryNoLinksFlags(path, O_RDONLY);
}

static inline BOOL WQSyncDirectory(int fd)
{
    int readable = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (readable < 0) return NO;
    BOOL ok = fsync(readable) == 0;
    int err = errno;
    if (close(readable) != 0 && ok) { ok = NO; err = errno; }
    if (!ok) errno = err;
    return ok;
}

static inline int WQOpenRegularAt(int parent, const char *name, int flags, mode_t mode)
{
    // Never allow truncation before the file type has been verified.
    if (flags & O_TRUNC) { errno = EINVAL; return -1; }
    struct stat entry;
    if (fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(entry.st_mode)) { errno = EINVAL; return -1; }
    } else if (errno != ENOENT || !(flags & O_CREAT)) return -1;
    int fd = openat(parent, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode);
    if (fd < 0) return -1;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        int err = errno;
        if (!S_ISREG(st.st_mode)) err = EINVAL;
        close(fd); errno = err; return -1;
    }
    return fd;
}

static inline BOOL WQWriteBytes(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    size_t done = 0;
    while (done < data.length) {
        ssize_t n = write(fd, bytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (n == 0) errno = EIO; return NO; }
        done += (size_t)n;
    }
    return fsync(fd) == 0;
}

// A durable intent file precedes the rename. The preserved directory itself is
// never removed. Recovery accepts only our exact symlink or the original inode.
//
// Durability: this runs for every access grant (a Cache Cleaner scan makes
// over a thousand), so only the marker's contents are flushed. That flush is
// what recovery relies on: a marker that can't be read while the preserved
// directory exists must fail closed, so its contents have to reach the disk
// before Caches is renamed. The directory operations themselves need no flush:
// after an app crash or kill they are already in place, and APFS commits
// changes to one directory in order, so a power loss leaves one of the states
// WQCacheSwapRecover handles.
static const char *const WQCacheMarker = ".wq-caches-swap.plist";
static const char *const WQCacheMarkerTemp = ".wq-caches-swap.plist.tmp";
static const char *const WQCacheSaved = ".wq-caches-preserved";

// An invalid marker means Begin never completed the marker write, so no swap
// should have started. It is safe to discard only when Caches is still a real
// directory and no preserved directory exists. Otherwise fail closed.
static inline BOOL WQCacheInvalidMarkerCanBeDiscarded(int library)
{
    struct stat saved, caches;
    if (fstatat(library, WQCacheSaved, &saved, AT_SYMLINK_NOFOLLOW) == 0) { errno = EEXIST; return NO; }
    if (errno != ENOENT) return NO;
    if (fstatat(library, "Caches", &caches, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    if (!S_ISDIR(caches.st_mode)) { errno = EINVAL; return NO; }
    if (unlinkat(library, WQCacheMarker, 0) != 0) return NO;
    return fsync(library) == 0;
}

static inline BOOL WQCacheSwapRecover(int library)
{
    int marker = WQOpenRegularAt(library, WQCacheMarker, O_RDONLY, 0);
    if (marker < 0) {
        if (errno != ENOENT) return NO;
        struct stat saved;
        if (fstatat(library, WQCacheSaved, &saved, AT_SYMLINK_NOFOLLOW) == 0) { errno = EEXIST; return NO; }
        return errno == ENOENT;
    }
    struct stat ms;
    if (fstat(marker, &ms) != 0 || ms.st_size <= 0 || ms.st_size > 65536) {
        close(marker);
        errno = EINVAL;
        return WQCacheInvalidMarkerCanBeDiscarded(library);
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)ms.st_size];
    size_t done = 0;
    while (done < data.length) {
        ssize_t n = read(marker, (uint8_t *)data.mutableBytes + done, data.length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            close(marker);
            errno = EIO;
            return WQCacheInvalidMarkerCanBeDiscarded(library);
        }
        done += (size_t)n;
    }
    close(marker);
    id record = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"Format"] isEqual:@1] ||
        ![record[@"Device"] isKindOfClass:NSNumber.class] || ![record[@"Inode"] isKindOfClass:NSNumber.class] ||
        ![record[@"Target"] isKindOfClass:NSString.class]) {
        errno = EINVAL;
        return WQCacheInvalidMarkerCanBeDiscarded(library);
    }
    struct stat original = {0}, current = {0};
    original.st_dev = [record[@"Device"] intValue];
    original.st_ino = [record[@"Inode"] unsignedLongLongValue];
    BOOL savedExists = fstatat(library, WQCacheSaved, &original, AT_SYMLINK_NOFOLLOW) == 0;
    if (!savedExists && errno != ENOENT) return NO;
    struct stat expected = {0};
    expected.st_dev = [record[@"Device"] intValue];
    expected.st_ino = [record[@"Inode"] unsignedLongLongValue];
    if (savedExists && (!S_ISDIR(original.st_mode) || !WQSameObject(&original, &expected))) { errno = EINVAL; return NO; }
    BOOL cachesExists = fstatat(library, "Caches", &current, AT_SYMLINK_NOFOLLOW) == 0;
    if (!cachesExists && errno != ENOENT) return NO;
    if (savedExists) {
        if (cachesExists) {
            char link[65536];
            ssize_t n = S_ISLNK(current.st_mode) ? readlinkat(library, "Caches", link, sizeof(link) - 1) : -1;
            if (n < 0) { errno = EEXIST; return NO; }
            link[n] = 0;
            if (![record[@"Target"] isEqualToString:[NSString stringWithUTF8String:link]]) { errno = EEXIST; return NO; }
            if (unlinkat(library, "Caches", 0) != 0) return NO;
        }
        if (renameatx_np(library, WQCacheSaved, library, "Caches", RENAME_EXCL) != 0) return NO;
    } else if (!cachesExists || !S_ISDIR(current.st_mode) || !WQSameObject(&current, &expected)) {
        errno = EINVAL; return NO;
    }
    return unlinkat(library, WQCacheMarker, 0) == 0;
}

// Normal startup performs no writes. Only an existing recovery marker or saved
// directory opens the same cross-process lock used by token issuance.
static inline BOOL WQRecoverCacheSwapAtPath(NSString *libraryPath)
{
    int library = WQOpenDirectoryNoLinks(libraryPath);
    if (library < 0) return errno == ENOENT;
    struct stat st;
    BOOL marker = fstatat(library, WQCacheMarker, &st, AT_SYMLINK_NOFOLLOW) == 0;
    int markerError = marker ? 0 : errno;
    BOOL saved = fstatat(library, WQCacheSaved, &st, AT_SYMLINK_NOFOLLOW) == 0;
    int savedError = saved ? 0 : errno;
    if ((!marker && markerError != ENOENT) || (!saved && savedError != ENOENT)) { close(library); return NO; }
    if (!marker && !saved) { close(library); return YES; }
    int lock = WQOpenRegularAt(library, ".wq-caches-lock", O_RDWR | O_CREAT, 0600);
    BOOL ok = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 && WQCacheSwapRecover(library);
    int error = errno;
    if (lock >= 0) close(lock);
    close(library);
    if (!ok) errno = error;
    return ok;
}

static inline BOOL WQCacheSwapBegin(int library, NSString *target)
{
    if (!WQCacheSwapRecover(library)) return NO;
    struct stat st;
    if (fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT || mkdirat(library, "Caches", 0755) != 0 ||
            fstatat(library, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0) return NO;
    }
    if (!S_ISDIR(st.st_mode)) { errno = EINVAL; return NO; }
    NSDictionary *record = @{ @"Format": @1, @"Device": @(st.st_dev), @"Inode": @(st.st_ino), @"Target": target };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) { errno = EINVAL; return NO; }
    // A failed marker write must never leave a partial marker behind: write a
    // temporary sibling, flush it, then atomically rename it into place.
    unlinkat(library, WQCacheMarkerTemp, 0);
    int marker = WQOpenRegularAt(library, WQCacheMarkerTemp, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (marker < 0) return NO;
    BOOL durable = WQWriteBytes(marker, data);   // flushes the marker's contents
    if (close(marker) != 0) durable = NO;
    if (!durable) {
        unlinkat(library, WQCacheMarkerTemp, 0);
        return NO;
    }
    if (renameatx_np(library, WQCacheMarkerTemp, library, WQCacheMarker, RENAME_EXCL) != 0) {
        unlinkat(library, WQCacheMarkerTemp, 0);
        return NO;
    }
    if (renameatx_np(library, "Caches", library, WQCacheSaved, RENAME_EXCL) != 0) return NO;
    return symlinkat(target.fileSystemRepresentation, library, "Caches") == 0;
}

static inline BOOL WQAbsolutePathGrammar(NSString *path)
{
    if (![path hasPrefix:@"/"] || path.length < 2 || [path rangeOfString:@"\0"].location != NSNotFound) return NO;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *part = parts[i];
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    }
    return YES;
}

static inline int WQCreateDirectoriesNoLinksMode(NSString *path, mode_t mode)
{
    path = WQCanonicalVarPath(path);
    if (!WQAbsolutePathGrammar(path)) { errno = EINVAL; return -1; }
    int fd = open("/", O_SEARCH | O_CLOEXEC);
    if (fd < 0) return -1;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        int next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(fd, part.fileSystemRepresentation, mode) != 0 && errno != EEXIST) { int err = errno; close(fd); errno = err; return -1; }
            if (!WQSyncDirectory(fd)) { int err = errno; close(fd); errno = err; return -1; }
            next = openat(fd, part.fileSystemRepresentation, O_SEARCH | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        }
        int err = errno;
        close(fd);
        if (next < 0) { errno = err; return -1; }
        fd = next;
    }
    int result = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int err = errno;
    close(fd);
    if (result < 0) errno = err;
    return result;
}

static inline int WQCreateDirectoriesNoLinks(NSString *path)
{
    return WQCreateDirectoriesNoLinksMode(path, 0700);
}

static inline BOOL WQBackupStampValid(NSString *stamp)
{
    if (stamp.length < 15) return NO;
    static NSCache<NSString *, NSNumber *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 1024;
    });
    NSNumber *known = [cache objectForKey:stamp];
    if (known) return known.boolValue;

    // Recognize the historical second/millisecond stamps and the current
    // millisecond-counter format. No arbitrary directory can become a restore.
    NSString *pattern = @"^[0-9]{8}-[0-9]{6}(-[0-9]{3}(-[1-9][0-9]*)?)?$";
    NSRange match = [stamp rangeOfString:pattern options:NSRegularExpressionSearch];
    if (match.location != 0 || match.length != stamp.length) return NO;
    NSArray *parts = [stamp componentsSeparatedByString:@"-"];
    if (parts.count == 4) {
        uint64_t number = 0;
        for (NSUInteger i = 0; i < [parts[3] length]; i++) {
            unsigned digit = [parts[3] characterAtIndex:i] - '0';
            if (number > (UINT64_MAX - digit) / 10) return NO;
            number = number * 10 + digit;
        }
    }
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    fmt.lenient = NO;
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *datePart = [stamp substringToIndex:15];
    NSDate *date = [fmt dateFromString:datePart];
    BOOL valid = date && [[fmt stringFromDate:date] isEqualToString:datePart];
    [cache setObject:@(valid) forKey:stamp];
    return valid;
}
#endif
