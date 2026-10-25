// Shenzhen Friends drops: what a drag carries, decided once for every drop target (internal).
//
// Rows, the open conversation, the composer and the Friends button all accept the same things: the host's own
// items (a reader tab: its file and the exact revision on screen), file URLs from Finder or Shenzhen Files, and
// file promises. Folders, links and special files are refused while dragging, before any intent (PROTOCOL.md
// § Intents, files; § Static strings, drop_not_a_file): the helper sends only regular files.

#import <AppKit/AppKit.h>

#import "mac/SZFriendsHost.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsDropVerdict) {
    SZFriendsDropVerdictNone = 0,     // nothing Friends can send
    SZFriendsDropVerdictAccept,       // files, promises or host items, all of them regular files
    SZFriendsDropVerdictRefuseFolder, // at least one folder, or a link to one: "Folders can't be sent yet"
    SZFriendsDropVerdictRefuseNotAFile, // no folder, but a symbolic link or a FIFO, socket or device: drop_not_a_file
};

// The static string a refusing target shows (drop_folders_refused, drop_not_a_file); nil for any other verdict.
FOUNDATION_EXPORT NSString *_Nullable SZFriendsDropRefusalKey(SZFriendsDropVerdict verdict);

@interface SZFriendsDrops : NSObject
+ (NSArray<NSPasteboardType> *)draggedTypesForHost:(nullable id<SZFriendsHost>)host;
// Cheap enough for every draggingEntered: the host's own types are resolved only by +readItemsFromPasteboard:. While
// dragging they are judged by the files the host names (-friendsDraggedFileURLsFromPasteboard:) as file URLs are,
// or, when the host does not implement it, accepted by their presence alone.
+ (SZFriendsDropVerdict)verdictForPasteboard:(NSPasteboard *)pasteboard host:(nullable id<SZFriendsHost>)host;
// How many files the drop carries ("Send 2 files to…"); 0 when the verdict is not Accept.
+ (NSUInteger)fileCountForPasteboard:(NSPasteboard *)pasteboard host:(nullable id<SZFriendsHost>)host;
// Resolves the drop into items. File promises are received into a new folder (+promiseFolderInDirectory:) inside
// `promiseDirectory` (NSTemporaryDirectory() when nil); the items are copies made where the source cannot write
// (SZFriendsPromiseCopies.h), kept SZFriendsPromiseLifetime at most. `completion` runs
// once on the main thread; `refusedFolder` is YES when a promised file turned out to be a folder, and then `items`
// is empty: one bad file sends none.
+ (void)readItemsFromPasteboard:(NSPasteboard *)pasteboard
                           host:(nullable id<SZFriendsHost>)host
               promiseDirectory:(nullable NSString *)promiseDirectory
                     completion:(void (^)(NSArray<SZFriendsAttachableItem *> *items, BOOL refusedFolder))completion;

// Files the person chose in an open panel (Attach files), judged as dropped file URLs are, and as items when every
// one is a regular file; nil otherwise, with the verdict that refused them.
+ (nullable NSArray<SZFriendsAttachableItem *> *)itemsForChosenFiles:(NSArray<NSURL *> *)urls
                                                             verdict:(SZFriendsDropVerdict *)verdict;

// A new private folder for one drop's promised files, in "Shenzhen Friends drops" inside `promiseDirectory`
// (NSTemporaryDirectory() when nil). Folders of earlier drops older than SZFriendsPromiseLifetime are removed first,
// so a reader that quit before its timer fired leaves nothing behind for long.
+ (nullable NSURL *)promiseFolderInDirectory:(nullable NSString *)promiseDirectory;
// The files a promise source wrote, as items; nil when any is not a plain file directly inside `folder` (a symlink,
// a device, something elsewhere), with *refusedFolder YES when it was a folder. The source writes into a folder we
// gave it, so a symlink there could point at any file the reader can read and send it under the link's name.
+ (nullable NSArray<SZFriendsAttachableItem *> *)itemsForPromisedFiles:(NSArray<NSURL *> *)files
                                                              inFolder:(NSURL *)folder
                                                         refusedFolder:(BOOL *)refusedFolder;
// Removes a folder made by +promiseFolderInDirectory: after `delay` seconds.
+ (void)discardPromiseFolder:(NSURL *)folder after:(NSTimeInterval)delay;
@end

// How long a drop's promised files are kept. The helper copies each file when the send intent reaches it, at once
// for a drop on a row, the conversation or the button; a file waiting as a composer chip needs it until Send.
FOUNDATION_EXPORT const NSTimeInterval SZFriendsPromiseLifetime;

// The visual a drop target shows while a drag is over it.
typedef NS_ENUM(NSInteger, SZFriendsDropHighlight) {
    SZFriendsDropHighlightNone = 0,
    SZFriendsDropHighlightAccept,
    SZFriendsDropHighlightRefuse,
};
// What a target that takes files shows for a verdict: Accept, Refuse for either refusal, None otherwise.
FOUNDATION_EXPORT SZFriendsDropHighlight SZFriendsDropHighlightForVerdict(SZFriendsDropVerdict verdict);

NS_ASSUME_NONNULL_END
