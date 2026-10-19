// Shared by the page-display suite's files: the instrumented reader and the
// run-loop helpers. See SPDFMacPageDisplayTests.mm.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacViewportRenderPriority.h"

@interface ShenzhenMacDelegate (PageDisplayAccess)
- (SPDFDocumentTab*)newTabForPath:(NSString*)path;
- (void)applicationDidFinishLaunching:(NSNotification*)notification;
- (void)rebuildSidebar;
- (spdf_document*)workerDocumentForPath:(NSString*)path
                             sourcePath:(NSString*)sourcePath
                                  error:(char*)err
                            errorLength:(size_t)errLen;
- (SPDFRenderedPage*)renderedPageAtIndex:(NSInteger)pageIndex document:(spdf_document*)doc zoom:(CGFloat)zoom
                            displayScale:(CGFloat)displayScale renderToken:(spdf_render_token*)renderToken
                                   error:(char*)err errorLength:(size_t)errLen;
@end

@interface PageDisplayReader : ShenzhenMacDelegate
@property NSUInteger sidebarRebuilds;
@property NSMutableArray<NSArray*>* completedRenders; // [page, scale] of each finished full-page render
- (NSWindow*)testWindow;
- (NSInteger)currentPage;
- (CGFloat)currentZoom;
- (BOOL)allQueuesIdle;
- (NSOperationQueue*)backgroundQueue;
- (void)holdBackgroundQueue:(BOOL)hold;
- (void)holdRenderQueue:(BOOL)hold;
- (NSNumber*)queuedPageForOperation:(NSOperation*)operation;
- (NSOperation*)queuedOperationForPage:(NSNumber*)page;
- (BOOL)pageIsQueued:(NSNumber*)page;
- (BOOL)renderQueueHolds:(NSOperation*)operation;
- (NSUInteger)completedRendersOfPage:(NSInteger)page;
- (void)scrollViewportToPage:(NSInteger)page;
- (NSArray<NSDictionary*>*)sidebarItemsCopy;
- (int)activeCommentCount;
- (int)activeOutlineCount;
@end

extern NSUInteger gPageDisplayFailures;
void PageDisplayCheck(BOOL ok, NSString* what);
void PageDisplayPump(void);
void PageDisplayRunFor(NSTimeInterval seconds);
BOOL PageDisplayRunUntil(NSTimeInterval timeout, BOOL (^done)(void));
NSString* PageDisplayWriteDrawingSet(NSString* dir, NSString* name, NSInteger pages, NSInteger curves);
NSInteger PageDisplayAddTab(PageDisplayReader* reader, NSString* path, NSInteger page);
void PageDisplaySidebarChecks(PageDisplayReader* reader, NSString* root);
