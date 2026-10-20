// friends-ui-e2e: ShenzhenPDF's real Friends dropdown driven like a person drives it, against real helpers.
//
// Each run starts real Friends helper processes (the production helper's objects with the two-helper harness's main,
// friends/tests/e2e/SZFriendsE2EHelperMain.m) in a temporary home of its own: file key store (never the Keychain),
// a random loopback-only Bonjour type, its own socket, no host check-in. In this process it builds what the reader
// builds: SPDFMacFriendsHost with a stand-in for the reader's bridge, SZFriendsHelperLink, and the
// SZFriendsDropdownController whose Friends button sits in a real window's title bar and opens a real NSPopover.
// It then clicks, types (the field editor's insertText:), presses Return and Escape (keyDown events through the
// window), waits for the helper's next snapshot, and checks the live view tree: what is visible, what it says,
// what is enabled, that everything lies inside the popover, and that no text is cut. Every step leaves a PNG of the
// popover in the output folder. No fixture is involved anywhere on this path.
//
// The second person in the two-person flows is another real helper in its own home, driven through the C client
// library as the two-helper harness drives it (friends/tests/e2e/SZFriendsE2EHarness.h).
//
// Every flow runs in light and dark, at the normal dropdown (400 pt, a tall window) and the narrowest (320 pt, a
// short window). Every window stays off every screen (left of and below them all) and none takes focus from other
// apps: the person at the Mac sees nothing of the run.

#import <AppKit/AppKit.h>

// The two-helper harness is Objective-C, compiled on its own; its functions have C names.
#ifdef __cplusplus
extern "C" {
#endif
#import "SZFriendsE2EHarness.h"
#ifdef __cplusplus
}
#endif
#import "mac/SZFriendsDropdownInternal.h"
#import "mac/SZFriendsHelperLink.h"
#import "mac/SZFriendsHost.h"
#import "SPDFMacFriendsHost.h"

NS_ASSUME_NONNULL_BEGIN

// One of the four looks every flow runs in.
@interface UIVariant : NSObject
@property(nonatomic, copy) NSString* name;           // "light-normal"
@property(nonatomic, copy) NSAppearanceName appearance;
@property(nonatomic) CGFloat dropdownWidth;           // 400, or 320 at the narrowest
@property(nonatomic) CGFloat windowHeight;            // the window the dropdown hangs from
@end

// The reader's side of the host adapter, recording what Friends asks of it instead of opening Finder or documents.
@interface UIBridge : NSObject <SPDFMacFriendsReaderBridge>
@property(nonatomic) CGFloat dropdownWidth;
@property(nonatomic, strong, nullable) NSView* installed;
@property(nonatomic, strong) NSMutableArray<NSString*>* opened;
@property(nonatomic, strong) NSMutableArray<NSURL*>* revealed;
@end

// One person's ShenzhenPDF: a real helper process, the reader's host, the link, and the dropdown in a window.
@interface UIRig : NSObject
@property(nonatomic, strong) UIVariant* variant;
@property(nonatomic, strong) SZFE2EHelper* helper;
@property(nonatomic, strong) UIBridge* bridge;
@property(nonatomic, strong) SPDFMacFriendsHost* host;
@property(nonatomic, strong) SZFriendsHelperLink* link;
@property(nonatomic, strong) SZFriendsDropdownController* dropdown;
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, copy) NSString* shotsDirectory;
@property(nonatomic, copy) NSString* flow;
@property(nonatomic) NSInteger step;
@property(nonatomic, strong) NSMutableArray<NSURL*>* openedURLs; // System Settings links pressed
// Menus the views opened (a row's right-click menu, a link's menu), recorded instead of popped up on a screen.
@property(nonatomic, strong) NSMutableArray<NSMenu*>* menus;
// The helper's snapshots as an observer subscription on the same link sees them: how many came, and the last.
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* snapshotCounts;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* snapshots;
@property(nonatomic, readonly) SZFriendsDropdownContent* content;
@property(nonatomic, readonly) SZFriendsListPage* listPage;
@property(nonatomic, readonly, nullable) NSWindow* popoverWindow;
@end

extern int UIFailures;
extern NSMutableArray<NSString*>* UIFlowResults;
void UIFail(UIRig* _Nullable rig, const char* file, int line, const char* condition, NSString* detail);
// Records a failure (with a screenshot and what the popover shows) and returns NO from the enclosing flow.
#define EXPECT(rig, cond, ...)                                                                                      \
    do {                                                                                                            \
        if (!(cond)) {                                                                                              \
            UIFail(rig, __FILE__, __LINE__, #cond, [NSString stringWithFormat:@"" __VA_ARGS__]);                   \
            return NO;                                                                                              \
        }                                                                                                           \
    } while (0)

#pragma mark - Off every screen

// Installed before the first window: keeps every window of this process off every screen (UIOffscreenOrigin), and
// UIWait takes off (and fails the run for) any window found on one.
void UIKeepWindowsOffscreen(void);
NSPoint UIOffscreenOrigin(NSSize size);
BOOL UIOnAnyScreen(NSRect frame);

#pragma mark - Waiting

// Runs the main run loop (the link's dispatch sources, AppKit's drawing) and every harness client until `condition`
// holds or `seconds` pass; returns condition().
BOOL UIWait(NSTimeInterval seconds, BOOL (^condition)(void));
void UISpin(NSTimeInterval seconds);
// Waits for the observer's next snapshot of `view` after `count` (UISnapshotCount before the action).
NSInteger UISnapshotCount(UIRig* rig, NSString* view);
BOOL UIWaitNextSnapshot(UIRig* rig, NSString* view, NSInteger count, NSTimeInterval seconds);
// Subscribes the observer to `view` (list is subscribed from the start).
void UIObserve(UIRig* rig, NSString* view);

#pragma mark - The view tree

NSArray<NSView*>* UIAllViews(NSView* root);
// Shown on screen: not hidden here or above, not transparent, not empty, and inside every clip view above it.
BOOL UIVisible(NSView* view);
// The visible view whose words (a label's text, a button's title, an accessibility label, a text view's string)
// contain `text`, searched under `root`; nil when none.
NSView* _Nullable UIFindText(NSView* root, NSString* text);
// The visible button whose title (or accessibility label) is exactly `title`.
NSButton* _Nullable UIFindButton(NSView* root, NSString* title);
// Scrolls with wheel events, as a person would, until `view` is wholly in sight; NO when it cannot be.
BOOL UIScrollIntoView(NSView* view);
// The view saying `text` under `root`, scrolled into sight: what a person looks for below the fold.
NSView* _Nullable UIReveal(NSView* root, NSString* text);
// Every visible word under `root`, one line per view: what a failure prints.
NSString* UIDescribe(NSView* root);
// Problems with what the popover shows: views outside it, cut labels or buttons; empty when there are none.
NSArray<NSString*>* UILayoutProblems(UIRig* rig);

#pragma mark - Colours as drawn

// The sRGB colour at `point` in `view`, as the PNGs draw the popover (cacheDisplayInRect:), and as the window's own
// layers composited it (what reaches the screen, without capturing the screen; `savePath` keeps that rendering).
BOOL UISampleCached(UIRig* rig, NSView* view, NSPoint point, double rgb[_Nonnull 3]);
BOOL UISampleWindowLayers(UIRig* rig, NSView* view, NSPoint point, double rgb[_Nonnull 3],
                          NSString* _Nullable savePath);
double UIContrast(const double a[_Nonnull 3], const double b[_Nonnull 3]); // WCAG ratio, 1 to 21
// Where the next screenshot of this step goes (<shots>/<variant>/<flow>/<NN>-<name>.png).
NSString* UIShotPathFor(UIRig* rig, NSString* name);

#pragma mark - Doing things

BOOL UIClick(NSView* view, NSString* _Nullable* _Nullable why);
// Inserts `text` through the first responder's field editor (or text view), as typing does.
BOOL UIType(NSWindow* window, NSString* text);
// Selects all in the field editor and deletes it.
BOOL UIClearField(NSWindow* window);
void UIKey(NSWindow* window, unsigned short keyCode, NSString* characters);
void UIPressReturn(NSWindow* window);
void UIPressEscape(NSWindow* window);

#pragma mark - Rigs

// The temporary home every helper and the reader state of this run live in.
extern NSString* UIRoot;
extern NSString* UIShotsRoot;
extern NSString* UIHelperExecutable;
extern NSString* UIManifest;

// The helpers' test computer name and system (SZFRIENDS_E2E_DEVICE_NAME, _SYSTEM): no screen shows this Mac's own.
NSDictionary<NSString*, NSString*>* UIDeviceEnvironment(NSString* person);
// This Mac's own name or macOS version where `root` shows it, or nil; every screenshot checks it.
NSString* _Nullable UIRealComputerShown(NSView* root);
UIRig* _Nullable UIStartRig(SZFE2EWorld* world, UIVariant* variant, NSString* name,
                            NSDictionary<NSString*, NSString*>* _Nullable environment);
void UIStopRig(UIRig* rig);
BOOL UIOpenDropdown(UIRig* rig);
BOOL UICloseDropdown(UIRig* rig);
// Saves the popover (or `window` when given) as <shots>/<variant>/<flow>/<NN>-<name>.png after checking its layout.
BOOL UIShot(UIRig* rig, NSString* name);
BOOL UIShotWindow(UIRig* rig, NSWindow* window, NSString* name);
void UIBeginFlow(UIRig* rig, NSString* flow);

#pragma mark - Flows

typedef BOOL (*UIFlow)(SZFE2EWorld* world, UIVariant* variant);
// One line of the run's summary (and of flows.tsv beside the screenshots).
void UIRecord(UIVariant* variant, NSString* flow, BOOL passed);
BOOL UIFlowSolo(SZFE2EWorld* world, UIVariant* variant);
BOOL UIFlowPermission(SZFE2EWorld* world, UIVariant* variant);
BOOL UIFlowTwoPeople(SZFE2EWorld* world, UIVariant* variant);

NS_ASSUME_NONNULL_END
