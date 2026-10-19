#import <Cocoa/Cocoa.h>
#import "SPDFMacCollectionWindow.h"

@interface SPDFMacCollectionHistoryController : NSViewController <NSTableViewDataSource,NSTableViewDelegate,NSMenuDelegate>
@property(nonatomic) BOOL showsDocumentTitle;
@property(nonatomic, copy) void (^restoreLinkHandler)(NSString* previousPath, NSString* restoredPath);
@property(nonatomic, copy) void (^manageHandler)(NSString* documentID);
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store documentID:(NSString*)documentID
                         open:(SPDFCollectionOpenHandler)open;
- (void)reload;
- (void)cancelPendingPreviews;
@end
