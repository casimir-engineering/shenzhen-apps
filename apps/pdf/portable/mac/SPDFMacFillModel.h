#pragma once
// Fill & Sign on the Mac (docs/plans/fill-and-sign.md, UI): the small value objects the controller, the overlay, the
// editor and the palette share. Everything here is created on first use of Fill & Sign; nothing runs at launch.
//
// Rects are page space, as in the core: points, top-left origin, y down, rotation applied.
#import <Cocoa/Cocoa.h>

#include "spdf_fill_items.h"
#include "spdf_fill_snap.h"
#include "spdf_form.h"

@class SPDFMacSignature;

typedef NS_ENUM(NSInteger, SPDFFillTool) {
    SPDFFillToolText = 0,      // the smart default: fields, lines, boxes, small squares
    SPDFFillToolMark = 1,      // every click places a check or a cross
    SPDFFillToolSignature = 2  // a picked-up signature follows the pointer
};

static inline NSRect SPDFFillRectFromCore(spdf_rect r) { return NSMakeRect(r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0); }
static inline spdf_rect SPDFFillRectToCore(NSRect r) {
    spdf_rect out = {(float)NSMinX(r), (float)NSMinY(r), (float)NSMaxX(r), (float)NSMaxY(r)};
    return out;
}

// One widget of the PDF's own form.
@interface SPDFFillField : NSObject
@property(nonatomic) NSInteger page;
@property(nonatomic) int objectNumber;
@property(nonatomic) int groupID;
@property(nonatomic) NSRect rect;
@property(nonatomic) spdf_field_type type;
@property(nonatomic) unsigned flags;
@property(nonatomic) int maxLen;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* label;
@property(nonatomic, copy) NSString* value;  // text/choice value; checkbox/radio: this widget's on-state name
@property(nonatomic, copy) NSArray<NSString*>* options;
@property(nonatomic, readonly) BOOL readOnly;  // read-only or already signed: clicks do nothing
@property(nonatomic, readonly) BOOL hidden;
@property(nonatomic, readonly) BOOL isOn;
@property(nonatomic, readonly) BOOL filled;
+ (NSArray<SPDFFillField*>*)fieldsFromWidgets:(const spdf_form_widgets*)widgets;
@end

// One thing we placed: typed text, a mark, a signature or initials.
@interface SPDFFillItem : NSObject
@property(nonatomic) spdf_fill_kind kind;
@property(nonatomic) NSInteger page;
@property(nonatomic) NSRect rect;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic, copy) NSString* nm;
@property(nonatomic, copy) NSString* group;  // comb cells share it; otherwise equal to nm
@property(nonatomic) NSInteger cell;         // comb cell number, or -1
@property(nonatomic, copy) NSString* text;
@property(nonatomic, readonly) BOOL isMark;
@property(nonatomic, readonly) BOOL isSignature;
+ (NSArray<SPDFFillItem*>*)itemsFromCore:(const spdf_fill_items*)items;
@end

// Owns one page's snap geometry (freed with the object).
@interface SPDFFillSnapPage : NSObject
@property(nonatomic, readonly) const spdf_snap_geometry* geometry;
- (instancetype)initTakingGeometry:(spdf_snap_geometry)geometry;
@end

// Per tab: whether Fill & Sign is showing, the tool, the form summary, undo.
@interface SPDFFillSession : NSObject
@property(nonatomic) BOOL on;
@property(nonatomic) BOOL dismissed;          // Done was pressed: the form does not turn it back on by itself
@property(nonatomic) BOOL hasSummary;
@property(nonatomic) spdf_form_summary summary;
@property(nonatomic, copy) NSString* summaryStamp;  // path, size and date the summary was read for
@property(nonatomic) SPDFFillTool tool;
@property(nonatomic) BOOL markCross;          // the mark the Mark tool places (check unless the cross was chosen)
@property(nonatomic, strong) SPDFMacSignature* pickedSignature;
@property(nonatomic, strong, readonly) NSUndoManager* undoManager;
@property(nonatomic) BOOL signedNoticeAccepted;
@property(nonatomic) BOOL protectedForEdits;   // Collection/writable copy checks done for this burst of edits
@property(nonatomic, copy) NSString* protectedPath;
@property(nonatomic, readonly) BOOL isForm;    // the PDF has fields to fill
@end

// A uuid without dashes, lower case: the /NM suffix and signature ids.
NSString* SPDFFillNewIdentifier(void);
// The signature id inside an /NM (spdf-fill-sig-<id>-<uuid>), or nil.
NSString* SPDFFillSignatureIDFromName(NSString* nm);
