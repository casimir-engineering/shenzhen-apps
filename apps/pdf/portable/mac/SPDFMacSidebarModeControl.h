#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFSidebarMode) {
    SPDFSidebarModeChapters = 0,
    SPDFSidebarModeComments = 1,
    SPDFSidebarModeSearch = 2,
    SPDFSidebarModeHistory = 3,
    SPDFSidebarModeGroups = 4,
    SPDFSidebarModeChats = 5
};

@interface SPDFSidebarNavigationControl : NSControl
@property(nonatomic, copy) NSString* documentTitle;
- (void)setCollapseTarget:(id)target action:(SEL)action;
@end

void spdf_sidebar_mode_control_configure_navigation(NSControl* control, BOOL supportsComments, BOOL hasHistory);

// Mode tags stay stable when Markdown omits the Comments segment.
// Shared selectors: native segmented controls implement these in AppKit;
// sidebar navigation owns explicit metadata without a hidden segmented cell.
@interface NSControl (SPDFSidebarSegmentAccess)
@property(nonatomic) NSInteger segmentCount;
@property(nonatomic) NSInteger selectedSegment;
- (NSString*)labelForSegment:(NSInteger)segment;
- (NSInteger)tagForSegment:(NSInteger)segment;
- (BOOL)isEnabledForSegment:(NSInteger)segment;
- (void)setLabel:(NSString*)label forSegment:(NSInteger)segment;
- (void)setTag:(NSInteger)tag forSegment:(NSInteger)segment;
- (void)setEnabled:(BOOL)enabled forSegment:(NSInteger)segment;
- (void)setWidth:(CGFloat)width forSegment:(NSInteger)segment;
@end

@interface NSControl (SPDFSidebarModes)
@property(nonatomic) NSInteger spdf_selectedSidebarMode;
- (void)spdf_setEnabled:(BOOL)enabled forSidebarMode:(NSInteger)mode;
@end

void spdf_sidebar_mode_control_configure(NSControl* control, BOOL supportsComments, BOOL hasSearch);

void spdf_sidebar_mode_control_configure_history(NSControl* control, BOOL supportsComments, BOOL hasSearch, BOOL hasHistory);

// Keep document-dependent modes in sync even while a workspace panel bypasses
// the normal Chapters / Comments / Search list builder.
void spdf_sidebar_mode_control_set_document_availability(NSControl* control, BOOL hasChapters,
                                                         BOOL hasComments);

// The sidebar's Chapters / Comments / Search control, which grows a Search
// segment while a search is live and drops it again when the search ends.
//
// AppKit clears -selectedSegment when the segment it removes is the selected
// one, and that is exactly the case that happens: the reader is looking at the
// search results when they clear the query. Everything downstream reads that
// selection -- which builder fills the list, and whether the chapter rows get
// their levels, their disclosure triangles and their expand/collapse button --
// so a selection of -1 rebuilds the chapter list flat and buttonless, with no
// segment lit, until the reader clicks a mode by hand.
//
// Resize through this rather than setting -segmentCount: the selection survives
// when its segment does, and falls back to `fallbackSegment` when it does not.
void spdf_sidebar_mode_control_set_segment_count(NSControl* control, NSInteger segmentCount,
                                                 NSInteger fallbackSegment);

NS_ASSUME_NONNULL_END
