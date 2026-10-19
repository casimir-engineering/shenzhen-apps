// Shenzhen Friends views tests: shared support.

#import "SZFriendsViewsTestSupport.h"

#include <unistd.h>

int SZFTestFailures = 0;
NSString *SZFTestFixturesDir = @"";
NSString *SZFTestRendersDir = @"";
NSPasteboardType const SZFTestTabPasteboardType = @"com.example.friends-views-tests.tab";

@implementation SZFTestHost

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _openedFiles = [NSMutableArray array];
    _revealedFiles = [NSMutableArray array];
    _attachQueries = [NSMutableArray array];
    _attachableItems = @[];
    return self;
}

- (NSString *)friendsAppID {
    return @"com.example.friends-views-tests";
}
- (NSString *)friendsAppName {
    return @"ShenzhenPDF";
}
- (NSString *)friendsAppVersion {
    return @"0.0.1";
}
- (NSString *)friendsRevealInName {
    return @"Finder";
}
// Empty: the client library never spawns anything; the fake helper is already listening.
- (NSString *)friendsHelperPath {
    return @"";
}
- (void)friendsInstallButton:(NSView *)button {
    self.installedButton = button;
}
- (void)friendsRemoveButton:(NSView *)button {
    if (self.installedButton == button) self.installedButton = nil;
}
- (NSArray<NSPasteboardType> *)friendsExtraPasteboardTypes {
    return @[ SZFTestTabPasteboardType ];
}
// A "reader tab": its file and the exact revision on screen.
- (NSArray<SZFriendsAttachableItem *> *)friendsItemsFromPasteboard:(NSPasteboard *)pasteboard {
    self.itemsReads += 1;
    NSString *path = [pasteboard stringForType:SZFTestTabPasteboardType];
    if (!path.length) return @[];
    SZFriendsAttachableItem *item = [SZFriendsAttachableItem new];
    item.title = path.lastPathComponent;
    item.kindLabel = @"PDF";
    item.fileURL = [NSURL fileURLWithPath:path];
    item.revision = @{@"source" : @"com.example.friends-views-tests", @"document_id" : @"d_1", @"revision_id" : @"r_1",
                      @"size" : @1};
    return @[ item ];
}
- (void)friendsAttachableItemsMatching:(NSString *)query
                            completion:(void (^)(NSArray<SZFriendsAttachableItem *> *))completion {
    [self.attachQueries addObject:query];
    NSMutableArray *matches = [NSMutableArray array];
    for (SZFriendsAttachableItem *item in self.attachableItems)
        if (!query.length || [item.title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound)
            [matches addObject:item];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(matches); });
}
- (NSString *)friendsAttachPlaceholder {
    return @"Search open and Collection documents";
}
- (NSSet<NSString *> *)friendsFormatsOpenedInPlace {
    return [NSSet setWithObjects:@"pdf", @"md", nil];
}
- (void)friendsOpenReceivedFileAtURL:(NSURL *)fileURL {
    [self.openedFiles addObject:fileURL];
}
- (void)friendsRevealFileAtURL:(NSURL *)fileURL {
    [self.revealedFiles addObject:fileURL];
}
- (SZFriendsAppearance *)friendsAppearance {
    SZFriendsAppearance *appearance = [SZFriendsAppearance new];
    if (!self.readerTokens) return appearance;
    // As ShenzhenPDF's host adapter builds its appearance: named dynamic colours from the reader's Collection palette.
    NSDictionary<NSString *, NSArray<NSNumber *> *> *palette = @{
        @"window" : @[ @0xffffff, @0x292b2e ], @"text" : @[ @0x26282b, @0xeceef1 ],
        @"secondary" : @[ @0x61666d, @0xb3b7be ], @"line" : @[ @0xdddfdf, @0x414448 ],
        @"selected" : @[ @0xdbe5f0, @0x374b61 ], @"accent" : @[ @0x286398, @0xa1c9ed ],
        @"control" : @[ @0xf6f6f5, @0x232426 ], @"hover" : @[ @0xe8ebed, @0x393d42 ],
    };
    NSColor * (^token)(NSString *) = ^NSColor *(NSString *name) {
        NSArray<NSNumber *> *pair = palette[name];
        return [NSColor colorWithName:[@"Collection." stringByAppendingString:name]
                      dynamicProvider:^NSColor *(NSAppearance *current) {
                          BOOL dark = [[current bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                                                     NSAppearanceNameDarkAqua ]]
                              isEqualToString:NSAppearanceNameDarkAqua];
                          unsigned rgb = pair[dark ? 1 : 0].unsignedIntValue;
                          return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                                                      blue:(rgb & 255) / 255.0 alpha:1];
                      }];
    };
    appearance.backgroundColor = token(@"window");
    appearance.primaryTextColor = token(@"text");
    appearance.secondaryTextColor = token(@"secondary");
    appearance.separatorColor = token(@"line");
    appearance.selectionColor = token(@"selected");
    appearance.accentColor = token(@"accent");
    appearance.controlColor = token(@"control");
    appearance.hoverColor = token(@"hover");
    return appearance;
}
- (void)friendsServicesDidBecomeAvailable:(id<SZFriendsServices>)services {
    self.services = services;
}
- (void)friendsServicesDidBecomeUnavailable {
    self.services = nil;
}
- (BOOL)friendsButtonAcceptsDrag:(id<NSDraggingInfo>)draggingInfo {
    (void)draggingInfo;
    return !self.vetoDrags;
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@implementation SZFTestDraggingInfo {
    NSPasteboard *_pasteboard;
}
@synthesize draggingFormation = _draggingFormation;
@synthesize animatesToDestination = _animatesToDestination;
@synthesize numberOfValidItemsForDrop = _numberOfValidItemsForDrop;
- (instancetype)initWithPasteboard:(NSPasteboard *)pasteboard {
    if (!(self = [super init])) return nil;
    _pasteboard = pasteboard;
    return self;
}
- (NSWindow *)draggingDestinationWindow {
    return nil;
}
- (NSDragOperation)draggingSourceOperationMask {
    return NSDragOperationCopy | NSDragOperationGeneric;
}
- (NSPoint)draggingLocation {
    return NSZeroPoint;
}
- (NSPoint)draggedImageLocation {
    return NSZeroPoint;
}
- (NSImage *)draggedImage {
    return nil;
}
- (NSPasteboard *)draggingPasteboard {
    return _pasteboard;
}
- (id)draggingSource {
    return nil;
}
- (NSInteger)draggingSequenceNumber {
    return 1;
}
- (void)slideDraggedImageTo:(NSPoint)screenPoint {
    (void)screenPoint;
}
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination {
    (void)dropDestination;
    return @[];
}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts
                                  forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block {
    (void)enumOpts, (void)view, (void)classArray, (void)searchOptions, (void)block;
}
- (NSSpringLoadingHighlight)springLoadingHighlight {
    return NSSpringLoadingHighlightNone;
}
- (void)resetSpringLoading {
}
@end
#pragma clang diagnostic pop

@implementation SZFTestTransport {
    NSInteger _nextID;
    SZFriendsLinkState _state;
}
@synthesize delegate = _delegate;
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _sent = [NSMutableArray array];
    return self;
}
- (void)start {
}
- (void)stopDisablingFriends:(BOOL)disabling {
    (void)disabling;
}
- (NSString *)sendIntent:(NSString *)type fields:(NSDictionary *)fields errorCode:(NSString **)errorCode {
    if (_state != SZFriendsLinkStateReady) {
        *errorCode = @"not_ready";
        return nil;
    }
    NSString *frameID = [NSString stringWithFormat:@"%ld", (long)++_nextID];
    [self.sent addObject:@{@"type" : type, @"id" : frameID, @"fields" : fields ?: @{}}];
    return frameID;
}
- (void)deliver:(NSDictionary *)frame {
    [self.delegate transportDidReceiveFrame:frame];
}
- (void)setLinkState:(SZFriendsLinkState)state {
    _state = state;
    [self.delegate transportDidChangeState:state
                                statusText:state == SZFriendsLinkStateReady ? nil : @"Reconnecting…"];
}
@end

@implementation SZFTestFakeHelper {
    szfriends_fake_helper *_fake;
    NSString *_stateDirectory;
}
- (instancetype)initWithStateDirectory:(NSString *)directory {
    if (!(self = [super init])) return nil;
    _stateDirectory = [directory copy];
    szfriends_fake_helper_config config = {0};
    config.state_dir = directory.fileSystemRepresentation;
    config.fixtures_dir = SZFTestFixturesDir.fileSystemRepresentation;
    if (szfriends_fake_helper_start(&config, &_fake) != SZFRIENDS_OK) return nil;
    return self;
}
- (szfriends_fake_helper *)fake {
    return _fake;
}
- (NSArray<NSDictionary *> *)frames {
    NSMutableArray *frames = [NSMutableArray array];
    if (!_fake) return frames;
    size_t count = szfriends_fake_helper_frame_count(_fake);
    for (size_t i = 0; i < count; i++) {
        char *text = szfriends_fake_helper_copy_frame(_fake, i);
        if (!text) continue;
        NSData *data = [NSData dataWithBytes:text length:strlen(text)];
        free(text);
        id frame = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([frame isKindOfClass:NSDictionary.class]) [frames addObject:frame];
    }
    return frames;
}
- (NSArray<NSDictionary *> *)framesOfType:(NSString *)type {
    return [self.frames filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"type == %@", type]];
}
- (void)stop {
    if (_fake) szfriends_fake_helper_stop(_fake);
    _fake = NULL;
    // A state directory too deep for sun_path put the socket in a per-user szfriends-<hash> directory, outside the
    // suite's temporary root: every run left one behind. rmdir, so only an empty one of ours ever goes.
    char path[SZFRIENDS_PATH_CAP];
    bool fallback = false;
    if (_stateDirectory && szfriends_socket_path(_stateDirectory.fileSystemRepresentation, path, sizeof path,
                                                 &fallback) == SZFRIENDS_OK && fallback) {
        NSString *directory = @(path).stringByDeletingLastPathComponent;
        if ([directory.lastPathComponent hasPrefix:@"szfriends-"]) rmdir(directory.fileSystemRepresentation);
    }
}
- (void)dealloc {
    [self stop];
}
@end

BOOL SZFTestWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10)];
    while (!condition()) {
        if ([deadline timeIntervalSinceNow] <= 0) return NO;
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

void SZFTestSpin(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

NSDictionary *SZFTestFrame(NSString *path) {
    NSString *file = [[SZFTestFixturesDir stringByAppendingPathComponent:path] stringByAppendingPathExtension:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:file];
    id frame = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![frame isKindOfClass:NSDictionary.class]) {
        SZFTestFailures++;
        fprintf(stderr, "missing fixture %s\n", file.UTF8String);
        return @{};
    }
    return frame;
}

NSDictionary *SZFTestSnapshot(NSString *name) {
    NSDictionary *data = SZFTestFrame([@"snapshots" stringByAppendingPathComponent:name])[@"data"];
    return [data isKindOfClass:NSDictionary.class] ? SZFTestLocalThumbnails(data) : @{};
}

SZFriendsHelperLink *SZFTestReadyLink(SZFTestTransport **transportOut) {
    SZFTestTransport *transport = [SZFTestTransport new];
    SZFriendsHelperLink *link = [[SZFriendsHelperLink alloc] initWithHost:nil transport:transport];
    [transport setLinkState:SZFriendsLinkStateReady];
    [transport deliver:SZFTestFrame(@"frames/welcome")];
    if (transportOut) *transportOut = transport;
    return link;
}

SZFriendsContext *SZFTestContext(SZFTestHost *host, SZFriendsHelperLink *link) {
    SZFriendsContext *context = [[SZFriendsContext alloc] initWithHost:host link:link];
    context.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    context.openURL = ^(NSURL *url) { (void)url; };
    // A popped-up menu runs its own loop until it closes; a test that clicks a link records the menu itself.
    context.presentMenu = ^(NSMenu *menu, NSView *view, NSPoint point) { (void)menu, (void)view, (void)point; };
    return context;
}

static BOOL SZFTestVisible(NSView *view) {
    for (NSView *ancestor = view; ancestor; ancestor = ancestor.superview)
        if (ancestor.hidden || ancestor.alphaValue == 0) return NO;
    return NSWidth(view.frame) > 0 && NSHeight(view.frame) > 0;
}

NSArray *SZFTestSubviews(NSView *root, Class cls) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSView *child in root.subviews) {
        if ([child isKindOfClass:cls]) [found addObject:child];
        [found addObjectsFromArray:SZFTestSubviews(child, cls)];
    }
    return found;
}

NSArray<NSView *> *SZFTestHitTargets(NSView *root) {
    NSMutableArray *targets = [NSMutableArray array];
    for (NSView *view in [SZFTestSubviews(root, SZFriendsButton.class) arrayByAddingObjectsFromArray:
                                                                          SZFTestSubviews(root, NSSwitch.class)])
        if (SZFTestVisible(view)) [targets addObject:view];
    return targets;
}

NSUInteger SZFTestMissedHits(NSView *target, NSView *root) {
    [target scrollRectToVisible:target.bounds];
    NSUInteger missed = 0;
    NSRect bounds = target.bounds;
    for (CGFloat scale = 1; scale <= 2; scale += 1) {
        CGFloat inset = 0.5 / scale, step = 1 / scale;
        NSMutableArray<NSValue *> *points = [NSMutableArray array];
        for (CGFloat x = NSMinX(bounds) + inset; x < NSMaxX(bounds); x += step) {
            [points addObject:[NSValue valueWithPoint:NSMakePoint(x, NSMinY(bounds) + inset)]];
            [points addObject:[NSValue valueWithPoint:NSMakePoint(x, NSMaxY(bounds) - inset)]];
        }
        for (CGFloat y = NSMinY(bounds) + inset; y < NSMaxY(bounds); y += step) {
            [points addObject:[NSValue valueWithPoint:NSMakePoint(NSMinX(bounds) + inset, y)]];
            [points addObject:[NSValue valueWithPoint:NSMakePoint(NSMaxX(bounds) - inset, y)]];
        }
        [points addObject:[NSValue valueWithPoint:NSMakePoint(NSMidX(bounds), NSMidY(bounds))]];
        for (NSValue *value in points) {
            NSPoint point = [root.superview convertPoint:value.pointValue fromView:target];
            NSView *hit = [root hitTest:point];
            if (hit != target && ![hit isDescendantOf:target]) {
                if (!missed && getenv("SZFRIENDS_VIEWS_DEBUG"))
                    fprintf(stderr, "  miss at %s in %s: hit %s %s\n", NSStringFromPoint(value.pointValue).UTF8String,
                            NSStringFromRect(target.frame).UTF8String, hit.className.UTF8String,
                            NSStringFromRect(hit.frame).UTF8String);
                missed++;
            }
        }
    }
    return missed;
}

NSWindow *SZFTestHostWindow(NSView *view, NSSize size, NSAppearanceName appearance) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    window.appearance = [NSAppearance appearanceNamed:appearance];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    window.contentView = container;
    view.frame = container.bounds;
    [container addSubview:view];
    [container layoutSubtreeIfNeeded];
    return window;
}

NSString *SZFTestRender(NSView *view, NSString *name, CGFloat scale) {
    [view layoutSubtreeIfNeeded];
    NSRect bounds = view.bounds;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(NSWidth(bounds) * scale)
                      pixelsHigh:(NSInteger)(NSHeight(bounds) * scale) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                        isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = bounds.size;
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [view cacheDisplayInRect:bounds toBitmapImageRep:rep];
    }];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [[SZFTestRendersDir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"png"];
    return [png writeToFile:path atomically:YES] ? path : nil;
}

NSEvent *SZFTestKeyEvent(NSString *characters, unsigned short keyCode, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
                        windowNumber:0 context:nil characters:characters charactersIgnoringModifiers:characters
                           isARepeat:NO keyCode:keyCode];
}

@implementation SZFTestPresenter {
    BOOL _presented;
}
@synthesize onDismiss = _onDismiss;
- (BOOL)isPresented {
    return _presented;
}
- (void)presentView:(NSView *)view size:(NSSize)size fromButton:(NSView *)button {
    (void)view, (void)button;
    _presented = YES;
    self.presentCount += 1;
    self.lastSize = size;
}
- (void)resizeTo:(NSSize)size {
    self.lastSize = size;
}
- (void)dismiss {
    if (!_presented) return;
    _presented = NO;
    if (self.onDismiss) self.onDismiss();
}
@end
