// Shenzhen Friends views tests: shared support (fake host, dragging info, transports, renders, hit tests).

#import <AppKit/AppKit.h>

#import "mac/SZFriendsDropdownInternal.h"
#import "mac/SZFriendsLinkTransport.h"

#include "client/fake/szfriends_fake_helper.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFTestFailures;
extern NSString *SZFTestFixturesDir;
extern NSString *SZFTestRendersDir;

#define SZFExpect(condition, ...)                                                                                  \
    do {                                                                                                           \
        if (!(condition)) {                                                                                        \
            SZFTestFailures++;                                                                                     \
            fprintf(stderr, "%s:%d: expected %s: %s\n", __FILE__, __LINE__, #condition,                            \
                    [[NSString stringWithFormat:__VA_ARGS__] UTF8String]);                                         \
        }                                                                                                          \
    } while (0)

// The host adapter as the views see it: records every call, never touches Finder, the reader or the network.
@interface SZFTestHost : NSObject <SZFriendsHost>
@property(nonatomic, strong, nullable) NSView *installedButton;
@property(nonatomic, strong) NSMutableArray<NSURL *> *openedFiles;
@property(nonatomic, strong) NSMutableArray<NSURL *> *revealedFiles;
@property(nonatomic, copy) NSArray<SZFriendsAttachableItem *> *attachableItems;
@property(nonatomic, strong) NSMutableArray<NSString *> *attachQueries;
@property(nonatomic, strong, nullable) id<SZFriendsServices> services;
@property(nonatomic) BOOL vetoDrags;
@property(nonatomic) NSUInteger itemsReads; // calls to -friendsItemsFromPasteboard: (the reader hashes files there)
// Appearance tokens built the way ShenzhenPDF's adapter builds them (its Collection palette), not the defaults.
@property(nonatomic) BOOL readerTokens;
@end

extern NSPasteboardType const SZFTestTabPasteboardType;

// The host's `/` assistant as the views see it: records each command and leaves it running until the test answers.
// It has the optional words (commandNote, the proposal's Edit and status) unless `plain` is set.
@interface SZFTestAssistant : NSObject <SZFriendsAssistant>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *calls; // {command, conversation_id, attachments}
@property(nonatomic, copy, nullable) void (^progress)(NSString *status);
@property(nonatomic, copy, nullable) void (^completion)(SZFriendsAssistantResult *_Nullable, NSError *_Nullable);
@property(nonatomic) NSUInteger cancels;
@property(nonatomic) BOOL plain; // responds to none of the optional words, as a host written before them
@end

// A proposed message as a host returns it: its `send` records each call and keeps `done` for the test to answer.
@interface SZFTestProposal : NSObject
@property(nonatomic, strong) SZFriendsAssistantResult *result;
@property(nonatomic) NSUInteger sends;
@property(nonatomic, copy, nullable) void (^done)(NSError *_Nullable error);
@end
SZFTestProposal *SZFTestProposalWithText(NSString *text, NSArray<SZFriendsAttachableItem *> *attachments);
// Answers the last `send` as the host would; a failure (not a crash) when the views never called it.
void SZFTestAnswerProposal(SZFTestProposal *proposal, NSError *_Nullable error);

// A host with the optional parts: the `/` assistant and Markdown rendering. Its renderer draws a chat-scale subset of
// Markdown (headings, lists, emphasis, code, links, tables, $math$ and a mermaid flowchart) the way the contract in
// SZFriendsHost.h asks: tables and diagrams as attachments at their natural width, sources marked for copying.
@interface SZFTestAssistantHost : SZFTestHost
@property(nonatomic, strong, nullable) SZFTestAssistant *assistant;
@property(nonatomic) BOOL refusesMarkdown;                     // answers nil, as a host without a renderer may
@property(nonatomic, strong) NSMutableArray<NSString *> *renders; // "<width>|<dark>" per call
// Replaces the stand-in renderer when set (a test's own attachments).
@property(nonatomic, copy, nullable) NSAttributedString * (^renderer)(NSString *markdown, CGFloat width);
// Render passes (SZFriendsHost.h): begins and ends seen, renders asked outside one, and a stand-in allowance of
// `passBudget` renders per pass, after which it answers nil as a host whose time is spent.
@property(nonatomic) NSUInteger passBegins;
@property(nonatomic) NSUInteger passEnds;
@property(nonatomic) NSUInteger rendersOutsidePass;
@property(nonatomic) NSUInteger passBudget; // NSUIntegerMax (the default): no limit
@property(nonatomic) BOOL nestedPass;       // a begin arrived inside a pass
@property(nonatomic) NSTimeInterval renderCost; // seconds each rendering it answers takes, as a real host's would
@property(nonatomic, strong) NSMutableArray<NSString *> *renderedSources; // Markdown answered with a rendering
@end
NSAttributedString *SZFTestRenderMarkdown(NSString *markdown, CGFloat width, BOOL dark);

// A drag as the destination sees it.
@interface SZFTestDraggingInfo : NSObject <NSDraggingInfo>
- (instancetype)initWithPasteboard:(NSPasteboard *)pasteboard;
@end

// A transport whose helper is the test: records intents, lets the test deliver frames and change the state.
@interface SZFTestTransport : NSObject <SZFriendsLinkTransport>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *sent; // {type, id, fields}
- (void)deliver:(NSDictionary *)frame;
- (void)setLinkState:(SZFriendsLinkState)state;
@end

// The protocol area's fake helper on a temporary SZFRIENDS_STATE_DIR, talked to through the real client library.
@interface SZFTestFakeHelper : NSObject
- (nullable instancetype)initWithStateDirectory:(NSString *)directory;
@property(nonatomic, readonly) szfriends_fake_helper *fake;
// Client frames the fake received, parsed, hello included.
- (NSArray<NSDictionary *> *)frames;
- (NSArray<NSDictionary *> *)framesOfType:(NSString *)type;
- (void)stop;
@end

// The views' timers, fired by the test instead of waiting four seconds, and the presses the views read: a time on
// the event clock and a click count, so a test decides whether two clicks were a double-click.
@interface SZFTestClock : NSObject
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *blocks;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *delays;
@property(nonatomic) NSTimeInterval now;
@property(nonatomic) NSInteger clickCount;
// Accessibility notifications posted, as "name" or "name: announcement".
@property(nonatomic, strong) NSMutableArray<NSString *> *spoken;
@property(nonatomic, strong) NSMutableArray *notifiedElements;
@end
// Points the context's timers, presses and accessibility notifications at `clock`.
void SZFTestInstallClock(SZFriendsContext *context, SZFTestClock *clock);
// Presses `button` `delay` seconds after the clock's last press, as click `clickCount` of a run of clicks.
void SZFTestClickAfter(SZFTestClock *clock, NSButton *button, NSTimeInterval delay, NSInteger clickCount);

// Runs the main run loop until `condition` holds or `timeout` (at most 10 s) passes; returns the condition.
BOOL SZFTestWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void));
void SZFTestSpin(NSTimeInterval seconds);

// fixtures/snapshots/<name>.json -> data, with each file preview moved into the test state directory
// (SZFTestLocalThumbnails), so the views load a real picture and never the person's own Friends data.
NSDictionary *SZFTestSnapshot(NSString *name);
NSDictionary *SZFTestFrame(NSString *path); // fixtures/<path>.json, whole frame

// File previews (SZFriendsViewsTestThumbnails.m). The thumbnails directory of the current SZFRIENDS_STATE_DIR, made
// if needed; a PNG of `width` x `height` pixels (a page when portrait, a drawing when landscape); `data` with every
// transfer's thumbnail.path moved into that directory and its PNG written; and a wait (at most 5 s) until no preview
// under `root` is still loading.
NSString *_Nullable SZFTestThumbnailDirectory(void);
BOOL SZFTestWritePreviewPNG(NSString *path, NSInteger width, NSInteger height);
NSDictionary *SZFTestLocalThumbnails(NSDictionary *data);
BOOL SZFTestWaitForPreviews(NSView *root);

// A link over a test transport that is Ready and has the welcome fixture's strings.
SZFriendsHelperLink *SZFTestReadyLink(SZFTestTransport *_Nullable *_Nullable transportOut);
SZFriendsContext *SZFTestContext(SZFTestHost *host, SZFriendsHelperLink *link);

// Every visible SZFriendsButton and NSSwitch under `root`.
NSArray<NSView *> *SZFTestHitTargets(NSView *root);
// Checks that a hit test at every device-pixel centre along the target's edges and at its centre, at 1x and 2x,
// lands on the target (or inside it). Returns the number of points that missed.
NSUInteger SZFTestMissedHits(NSView *target, NSView *root);

// Lays `view` out at `size` in a borderless window that is never ordered on screen, with the given appearance.
NSWindow *SZFTestHostWindow(NSView *view, NSSize size, NSAppearanceName appearance);
// Writes an offscreen PNG of `view` at `scale` into SZFTestRendersDir/<name>.png; returns its path or nil.
NSString *_Nullable SZFTestRender(NSView *view, NSString *name, CGFloat scale);

// `color` as 0xRRGGBB in sRGB under the named appearance.
uint32_t SZFTestResolved(NSColor *color, NSAppearanceName appearance);
// The view drawn offscreen at 1x in sRGB over the default background, in its window's appearance; rows run top-down.
NSBitmapImageRep *SZFTestBitmap(NSView *view);
uint32_t SZFTestBitmapPixel(NSBitmapImageRep *rep, NSInteger x, NSInteger y); // 0xRRGGBB
// 0xRRGGBB at `point` in the view's own coordinates (one render per call).
uint32_t SZFTestPixelAt(NSView *view, NSPoint point);
// YES when two 0xRRGGBB colours differ by at most `tolerance` in every channel.
BOOL SZFTestSameColor(uint32_t a, uint32_t b, int tolerance);

// All subviews of class `cls` under `root`, depth first.
NSArray *SZFTestSubviews(NSView *root, Class cls);
NSEvent *SZFTestKeyEvent(NSString *characters, unsigned short keyCode, NSEventModifierFlags flags);

// Mentions (SZFriendsViewsMentionTests.m). A navigator that records the conversations a view opens; Daniel's
// conversation with mentions (conversation-daniel-mentions.json) on a Ready test link, laid out in a 400 x 640 window
// that never reaches the screen; the list as a client that declared `mentions` gets it (friends with an ID
// mentionable, a request and a blocked person not); and a click on the link at the first `words` in an item's bubble,
// through the text view's own -clickedOnLink:atIndex:, YES when the words were found.
@class SZFriendsConversationPage;
@interface SZFTestNavigator : NSObject <SZFriendsNavigator>
@property(nonatomic, strong) NSMutableArray<NSString *> *opened;
@end
SZFriendsConversationPage *SZFTestMentionPage(SZFTestHost *host, SZFTestNavigator *navigator,
                                              SZFTestTransport *_Nullable *_Nullable transportOut,
                                              NSWindow *_Nullable *_Nonnull windowOut, NSAppearanceName appearance);
NSDictionary *SZFTestMentionList(void);
BOOL SZFTestClickWords(SZFriendsConversationPage *page, NSString *itemID, NSString *words, id link);

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN

// A presenter that records instead of showing an NSPopover, so no window reaches the screen.
@interface SZFTestPresenter : NSObject <SZFriendsDropdownPresenter>
@property(nonatomic) NSUInteger presentCount;
@property(nonatomic) NSSize lastSize;
@end

// Test groups, one file each.
void SZFTestLinkRouting(void);
void SZFTestFixtureConstruction(void);
void SZFTestHitTesting(void);
void SZFTestDropdownSession(NSString *stateDirectory);
void SZFTestDrops(NSString *stateDirectory);
void SZFTestSettingsAndServices(NSString *stateDirectory);
void SZFTestRenders(void);
void SZFTestControls(void);
void SZFTestRowActions(void);
void SZFTestAssistantMarkers(void);
void SZFTestChrome(void);
void SZFTestArmedActions(void);
void SZFTestDragFeedback(void);
void SZFTestReusedRows(void);
void SZFTestMarkdownBubbles(void);
void SZFTestLinkMenus(void);
void SZFTestAssistantCommands(void);
void SZFTestAssistantProposals(void);
void SZFTestMarkdownPasses(void);
void SZFTestAssistantRenders(void);
void SZFTestFakeHelperCleanup(void);
void SZFTestInvisibleCharacters(void);
void SZFTestPlainText(void);
void SZFTestMentions(void);
void SZFTestMentionCards(void);
void SZFTestFilePreviews(void);
void SZFTestDropRefusals(void);
void SZFTestAvatarPhotos(void);
void SZFTestFriendLinks(void);
void SZFTestRouteIcons(void);
void SZFTestOnlineStates(void);
void SZFTestDevices(void);
void SZFTestPopoverLayout(void);

NS_ASSUME_NONNULL_END
