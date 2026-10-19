#import <Cocoa/Cocoa.h>
@class SPDFMacCollectionStore;
typedef void (^SPDFCollectionOpenHandler)(NSString* path, BOOL archived);
typedef void (^SPDFCollectionNavigateHandler)(NSDictionary* document, NSDictionary* version,
                                             NSUInteger page, NSString* query, BOOL history);
@interface SPDFMacCollectionWindow : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, copy) SPDFCollectionNavigateHandler navigateHandler;
@property(nonatomic, copy) void (^returnHandler)(void);
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store open:(SPDFCollectionOpenHandler)open;
- (void)showDocumentID:(NSString*)documentID query:(NSString*)query;
@end
// Pass a Collection ID for hash matching, or an absolute missing path for filename candidates.
void SPDFMacLocateCollectionOriginal(SPDFMacCollectionStore* store, NSString* documentID,
                                    NSWindow* parent, void (^preview)(NSString* path),
                                    void (^completion)(NSString* path));
