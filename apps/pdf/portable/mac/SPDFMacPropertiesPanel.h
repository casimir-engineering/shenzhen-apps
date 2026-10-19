#import <Cocoa/Cocoa.h>

#include "shenzhen_pdf_core.h"

// File > Properties and document context menus. Available for every file-backed
// tab, even when its contents cannot currently load. No document pointer is
// retained: text counts use an immutable text snapshot or a separate core open
// on a cancellable worker. Image metadata is inspected only on explicit open.
@interface SPDFPropertiesPanelController : NSObject
+ (void)presentForDocument:(spdf_document*)doc
                sourcePath:(NSString*)sourcePath
               workingPath:(NSString*)workingPath
                 pageIndex:(NSInteger)pageIndex
              outlineCount:(NSInteger)outlineCount
           annotationCount:(NSInteger)annotationCount
                  textInfo:(NSDictionary*)textInfo
              parentWindow:(NSWindow*)parentWindow;
@end
