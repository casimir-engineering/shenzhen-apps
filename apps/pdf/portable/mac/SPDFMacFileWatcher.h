#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Watches a single file on disk and invokes a debounced callback on the main
 * thread when that file appears to change (write/extend/rename/delete).
 *
 * Mechanism (most robust first):
 *   1. FSEvents stream on the file's *parent directory*, keyed to the filename.
 *      This survives atomic saves (write-temp + rename / replaceItemAtURL),
 *      which invalidate any fd opened on the original inode.
 *   2. A GCD vnode dispatch source on an open fd of the file, catching in-place
 *      writes/extends quickly. Re-armed across renames by the FSEvents path.
 *   3. A low-frequency polling timer fallback, installed only if both of the
 *      above fail to start.
 *
 * The watcher only signals "something happened near this file"; the owner is
 * responsible for the authoritative mtime/size comparison against its cache and
 * for deciding whether to reload. Callbacks are coalesced (debounced) so a
 * file mid-write fires the handler at most once per quiet window.
 */
@interface SPDFMacFileWatcher : NSObject

/* The path currently being watched, or nil when idle. */
@property(nonatomic, readonly, copy, nullable) NSString* watchedPath;

/* Point the watcher at a new path, tearing down any previous watch first.
 * Passing nil (or an empty string) stops watching entirely. Safe to call
 * repeatedly with the same path (no-op when unchanged and still healthy). */
- (void)watchPath:(nullable NSString*)path;

/* Same as -watchPath:, but when pollOnly is YES the watcher uses ONLY the
 * stat-based polling timer — it never opens an FSEvents stream nor an O_EVTONLY
 * vnode fd on the file. Used for read-only sources (e.g. files from another
 * app's container), where opening/streaming the source at every launch can
 * re-trigger the macOS "access data from other apps" prompt. The path is still
 * watched (for change detection), just via metadata polling only. */
- (void)watchPath:(nullable NSString*)path pollOnly:(BOOL)pollOnly;

/* Stop watching and release all OS resources (fds / sources / streams). */
- (void)stop;

/* Invoked on the main thread after a debounce window once a change is detected
 * near the watched file. The argument is the path that was being watched when
 * the event fired; the handler should re-check it is still current. */
@property(nonatomic, copy, nullable) void (^changeHandler)(NSString* path);

@end

NS_ASSUME_NONNULL_END
