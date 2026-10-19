#import <Foundation/Foundation.h>

// Pure helpers behind the document-view pointer feedback (I-beam over
// selectable text, pointing hand over links) and the click-vs-drag decision
// that lets link text be drag-selected without activating the link.
// No AppKit/core dependencies so they stay unit-testable in isolation.

typedef NS_ENUM(NSInteger, SPDFCursorRegionKind) {
    SPDFCursorRegionNone = 0,  // gutter / empty page area -> arrow
    SPDFCursorRegionText = 1,  // selectable text -> I-beam
    SPDFCursorRegionLink = 2,  // clickable link -> pointing hand
};

// Resolve a page-space point against the page's cached rects. Links win over
// text (a link IS text; the hand communicates the stronger affordance).
// linkPadding expands each link rect on all sides before testing, matching
// the 2pt slop spdf_link_at_point applies to text-URL hit-testing.
SPDFCursorRegionKind spdf_cursor_region_at_point(NSPoint pagePoint, NSArray<NSValue*>* linkRects,
                                                 NSArray<NSValue*>* textRects, CGFloat linkPadding);

// Click-vs-drag decision for link activation (browser semantics): mouse-down
// on a link starts a gesture; if the pointer ever travels beyond the
// threshold, or any drag produces a non-empty text selection, the gesture is
// a selection drag and release must NOT activate the link - even if the
// pointer returns to the press point before release. Only a press-and-release
// that stays within the threshold with no selection counts as a click.
extern const CGFloat kSPDFLinkClickDragThreshold;  // view points

typedef struct SPDFLinkClickGesture {
    NSPoint pressPoint;           // view-space press location
    BOOL active;                  // a press started the gesture
    BOOL draggedBeyondThreshold;  // sticky: set once, never cleared by moving back
    BOOL selectionCreated;        // sticky: some drag produced a non-empty selection
} SPDFLinkClickGesture;

SPDFLinkClickGesture spdf_link_click_gesture_begin(NSPoint pressViewPoint);
void spdf_link_click_gesture_drag(SPDFLinkClickGesture* gesture, NSPoint viewPoint, BOOL selectionNonEmpty);
BOOL spdf_link_click_gesture_activates_on_release(const SPDFLinkClickGesture* gesture);
