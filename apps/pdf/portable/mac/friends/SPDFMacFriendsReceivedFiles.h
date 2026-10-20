// Received files go to Collection (portable/friends/PROTOCOL.md § Views, received): every document Friends saves
// on this computer (from a friend, a download link or another of the person's computers) is captured into Collection
// with reason "Received", the way an opened document is, without opening a tab. Only while Collection is on; off or
// not yet chosen, nothing is captured. Each file is taken once (SPDFMacCollectionStore claimReceivedFiles:), and
// files received before ShenzhenPDF first heard of received files are left alone.

#import <Foundation/Foundation.h>
#import "mac/SZFriendsHelperLink.h"

@class SPDFMacCollectionStore;

NS_ASSUME_NONNULL_BEGIN

// The helper capability that says received files are published to a folder and listed in the `received` view.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsReceivedFolderCapability; // "received.folder"

@interface SPDFMacFriendsReceivedFiles : NSObject
// `isDocument`: whether ShenzhenPDF opens the file at a path (the reader's SPDFReadableDocumentPath).
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store
                   isDocument:(BOOL (^)(NSString* path))isDocument NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Call whenever the link's state changes (and once after it starts): subscribes to `received` the first time the
// link is ready with a helper that has the capability. The link renews the subscription itself after reconnects.
- (void)followLink:(SZFriendsHelperLink*)link;
- (void)stop;
// One `received` snapshot's data. Main thread.
- (void)takeSnapshot:(NSDictionary<NSString*, id>*)data;
// Tests: each capture's outcome (main thread), and when a snapshot has been fully handled.
@property(nonatomic, copy, nullable) void (^captured)(NSString* path, NSDictionary* _Nullable document,
                                                       NSError* _Nullable error);
@property(nonatomic, copy, nullable) void (^snapshotHandled)(NSArray<NSString*>* capturedPaths);
@end

NS_ASSUME_NONNULL_END
