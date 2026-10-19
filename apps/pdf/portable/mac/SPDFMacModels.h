#import <Cocoa/Cocoa.h>
#import "SPDFMacSidebarModeControl.h"

#include "shenzhen_pdf_core.h"

@class SPDFMacMarkdownSession;
@class SPDFTabGroup;

typedef NS_ENUM(NSInteger, SPDFFitMode) {
    SPDFFitModeCustom = 0,
    SPDFFitModeActual,
    SPDFFitModeWidth,
    SPDFFitModeHeight,
    SPDFFitModePage
};

@interface SPDFRenderedPage : NSObject
@property(nonatomic) NSInteger pageIndex;
@property(nonatomic) CGFloat pageWidth;
@property(nonatomic) CGFloat pageHeight;
@property(nonatomic) CGFloat imagePointWidth;
@property(nonatomic) CGFloat imagePointHeight;
@property(nonatomic) CGFloat imageZoom;
@property(nonatomic) CGFloat imageScale;
// Reading theme the pixels were rendered under. The cache is keyed on it the
// way it is keyed on zoom: a toggle re-renders rather than recoloring at paint
// time, which is the mistake that made Okular ship a speed warning next to its
// own color options.
@property(nonatomic) BOOL imageDarkTheme;
// Whether the dark render kept image colors. Only meaningful with
// imageDarkTheme; a page rendered under the other choice is stale.
@property(nonatomic) BOOL imagePreservesImageColors;
@property(nonatomic, strong) NSImage* image;
@property(nonatomic) CGFloat baseImagePointWidth;
@property(nonatomic) CGFloat baseImagePointHeight;
@property(nonatomic) CGFloat baseImageZoom;
@property(nonatomic) CGFloat baseImageScale;
@property(nonatomic, strong) NSImage* baseImage;
@property(nonatomic) CGFloat highQualityImagePointWidth;
@property(nonatomic) CGFloat highQualityImagePointHeight;
@property(nonatomic) CGFloat highQualityImageZoom;
@property(nonatomic) CGFloat highQualityImageScale;
@property(nonatomic, strong) NSImage* highQualityImage;
@property(nonatomic) CGFloat minimapImageZoom;
@property(nonatomic) CGFloat minimapImageScale;
@property(nonatomic, strong) NSImage* minimapImage;
@property(nonatomic) NSRect viewportImagePageRect;
@property(nonatomic) CGFloat viewportImageZoom;
@property(nonatomic) CGFloat viewportImageScale;
@property(nonatomic, strong) NSImage* viewportImage;
@property(nonatomic) NSRect zoomSeedPageRect;
@property(nonatomic) CGFloat zoomSeedZoom;
@property(nonatomic) CGFloat zoomSeedScale;
@property(nonatomic, strong) NSImage* zoomSeedImage;
@property(nonatomic, copy) NSArray<NSValue*>* highlights;
@property(nonatomic, copy) NSArray<NSValue*>* selectionRects;
@end

@interface SPDFDocumentTab : NSObject
@property(nonatomic) NSTimeInterval lastViewedAt;
@property(nonatomic, strong) SPDFTabGroup* group;
@property(nonatomic, copy) NSString* collectionHistoryDocumentID;
@property(nonatomic, copy) NSString* collectionVersionLabel;
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSString* title;
@property(nonatomic) NSInteger pageIndex;
@property(nonatomic) CGFloat zoom;
@property(nonatomic) CGFloat customZoom;
@property(nonatomic) SPDFFitMode fitMode;
@property(nonatomic) NSPoint scrollOrigin;
@property(nonatomic) BOOL hasScrollOrigin;
@property(nonatomic, copy) NSString* searchText;
@property(nonatomic) BOOL searchRegex;
@property(nonatomic) BOOL searchRegexMultiline;
@property(nonatomic) NSInteger findMatchIndex;
@property(nonatomic) BOOL showSidebar;
@property(nonatomic) BOOL showMinimap;
@property(nonatomic) BOOL hasMinimapPreference;
// With the dark reading theme on, leave this document's photographs and
// figures in their own colors. Per document, default YES: one datasheet can
// keep its color-coded figures while another is recolored whole. Persisted as
// "preservesImageColors"; a tab restored from a session without the key takes
// the launch default.
@property(nonatomic) BOOL preservesImageColors;
@property(nonatomic) BOOL missingFile;
@property(nonatomic, copy) NSString* missingMessage;
@property(nonatomic) NSRange markdownSelectionRange;
// Markdown paper orientation for THIS tab: NO = A4 portrait (the default),
// YES = A4 landscape, which the rotate commands switch by re-flowing the
// document onto turned paper. Persisted as "markdownLandscape".
@property(nonatomic) BOOL markdownLandscape;
@property(nonatomic, copy) NSString* markdownAnchor;
@property(nonatomic, strong) SPDFMacMarkdownSession* cachedMarkdownSession;
@property(nonatomic, copy) NSString* cachedMarkdownFileIdentity;
// Read-only shadow copy: when the SOURCE (path) is read-only we render a
// private temp copy so opening never reads the source (no macOS prompt).
// path stays the SOURCE everywhere the user perceives the file; workingPath is
// the render/read copy (nil for writable files). copiedSource* record the
// source stat the copy reflects, so an unchanged source reopens the copy with
// no content read on relaunch.
@property(nonatomic) BOOL readOnly;
// Derived from the durable clipboard source path; restored with the existing YAML path.
@property(nonatomic, readonly) BOOL unsavedPastedImage;
@property(nonatomic, copy) NSString* workingPath;
@property(nonatomic, copy) NSDictionary* readOnlyCopyBinding;
@property(nonatomic) unsigned long long copiedSourceFileSize;
@property(nonatomic, strong) NSDate* copiedSourceModificationDate;
@property(nonatomic) spdf_document* cachedDocument;
@property(nonatomic, strong) NSMutableArray<SPDFRenderedPage*>* cachedRenderedPages;
@property(nonatomic, strong) NSDate* cachedModificationDate;
@property(nonatomic) unsigned long long cachedFileSize;
@property(nonatomic) spdf_outline cachedOutline;
@property(nonatomic) spdf_comments cachedComments;
@property(nonatomic) BOOL cachedOutlineLoaded;
@property(nonatomic) BOOL cachedCommentsLoaded;
- (void)clearCachedRuntime;
- (void)replaceCachedOutline:(spdf_outline)outline loaded:(BOOL)loaded;
- (void)replaceCachedComments:(spdf_comments)comments loaded:(BOOL)loaded;
@end

@interface SPDFWorkerDocument : NSObject
@property(nonatomic) spdf_document* document;
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSString* cacheKey;
@end

SPDFDocumentTab* spdf_copy_document_tab(SPDFDocumentTab* source);
NSDictionary* spdf_dictionary_from_tab(SPDFDocumentTab* tab, NSInteger sourceWindowNumber);
SPDFDocumentTab* spdf_tab_from_dictionary(NSDictionary* item);

// The file a tab detach hands its reading position over in, named from the
// document's path so the launching and launched processes agree without an
// argument passing between them. See SPDFMacTabDetach.h.
NSString* spdf_mac_detach_handoff_name(NSString* path);

// Which saved window the reader was last looking at.
//
// A session holds one entry per window, and only one process activates at
// launch -- so the window that entry belongs to is the one that comes back
// focused. Picking windows.firstObject made that whichever window happened to
// be written first, which is not what the reader left in front. Each entry
// carries the time it last became key ("focusedAt"); the latest one wins, and a
// session written before that key existed (all zero) still resolves to index 0,
// exactly as before. Returns NSNotFound for an empty list.
NSUInteger spdf_session_focused_window_index(NSArray* windows);
