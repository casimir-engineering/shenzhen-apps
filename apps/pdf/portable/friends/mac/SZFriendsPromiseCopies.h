// Shenzhen Friends drops: promised files copied out of the folder their source was given (internal).
//
// A file promise's source writes into a folder we name and keeps the right to write there: a sandboxed source holds
// an extension to that folder for as long as it runs. Checking a promised file and then sending it by path left a
// gap, because the helper reads the file later (at once for a drop on a row, up to SZFriendsPromiseLifetime later
// for a composer chip): the source could swap the checked report.pdf for a symlink to ~/Documents/tax.pdf, and the
// helper would send tax.pdf under the name report.pdf. So each promised file is opened once without following
// links, checked through that descriptor, and copied from it into a folder beside the source's that the source was
// never given. The copies are what is sent; the source's folder is removed as soon as they exist.

#import <AppKit/AppKit.h>

#import "mac/SZFriendsHost.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsPromiseCopies : NSObject
// Copies `files`, each a plain file directly inside `folder`, into a new folder beside it ("<name>.copies", 0700,
// files 0600) and returns items for the copies. nil when any file is not a plain file directly inside `folder` (a
// symlink, a FIFO, a file elsewhere) or a copy fails, with *refusedFolder YES when one was a folder; no copy is left
// behind then. `folder` itself is left for the caller.
+ (nullable NSArray<SZFriendsAttachableItem *> *)copyPromisedFiles:(NSArray<NSURL *> *)files
                                                          inFolder:(NSURL *)folder
                                                     refusedFolder:(nullable BOOL *)refusedFolder;
// The drop path: copies off the main thread, removes `folder` (the source's) at once, keeps the copies for
// SZFriendsPromiseLifetime at most, and calls `completion` once on the main thread.
+ (void)copyPromisedFiles:(NSArray<NSURL *> *)files
                 inFolder:(NSURL *)folder
               completion:(void (^)(NSArray<SZFriendsAttachableItem *> *items, BOOL refusedFolder))completion;
// Removes the copies these items point at after `delay`; call it with 0 once the helper has replied to the send
// intent that carried them, since it has copied them by then. Items that are not promise copies are left alone.
+ (void)discardCopiesForItems:(NSArray<SZFriendsAttachableItem *> *)items after:(NSTimeInterval)delay;
// The same at once for PROTOCOL.md file objects (their `path`), after a send intent carrying them succeeded.
+ (void)discardCopiesForFileObjects:(NSArray<NSDictionary *> *)files;
// YES when `url` is a promised file's copy made by this class.
+ (BOOL)isPromiseCopy:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
