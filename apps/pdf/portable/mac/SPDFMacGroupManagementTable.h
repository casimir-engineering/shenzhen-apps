#pragma once
#import <Cocoa/Cocoa.h>
@interface SPDFGroupManagementTable : NSTableView
@property(nonatomic) BOOL draggedDuringPress;
- (void)beginDocumentDragScrolling;
- (void)endDocumentDragScrolling;
- (NSPoint)documentDragWindowPoint;
@end
NSView* SPDFGroupDocumentBadge(NSString* path);
