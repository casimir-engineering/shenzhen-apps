// friends-ui-e2e's driver (SPDFMacFriendsUIE2E.h): rigs, waiting, screenshots and the colours as drawn. The live view
// tree and the real events are in SPDFMacFriendsUIViewTree.mm, the windows kept off every screen in
// SPDFMacFriendsUIOffscreen.mm.

#import "SPDFMacFriendsUIDriverInternal.h"

#import "SPDFMacFriendsAppearance.h"
#import "SPDFMacFriendsTitleBar.h"
#import "mac/SZFriendsListPage.h"
#include "client/szfriends_client.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

int UIFailures = 0;
NSMutableArray<NSString*>* UIFlowResults;
NSString* UIRoot = @"";
NSString* UIShotsRoot = @"";
NSString* UIHelperExecutable = @"";
NSString* UIManifest = @"";

@implementation UIVariant
@end

@implementation UIBridge
- (instancetype)init {
    if ((self = [super init])) {
        _opened = [NSMutableArray array];
        _revealed = [NSMutableArray array];
        _dropdownWidth = 400;
    }
    return self;
}
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button { self.installed = button; }
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button {
    if (self.installed == button) self.installed = nil;
}
- (NSArray<NSDictionary*>*)friendsBridgeOpenDocuments { return @[]; }
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return nil; }
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { [self.opened addObjectsFromArray:paths]; }
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)fileURLs { [self.revealed addObjectsFromArray:fileURLs]; }
- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services { (void)services; }
// The reader's own tokens, at the width this variant asks for.
- (SZFriendsAppearance*)friendsBridgeAppearance {
    SZFriendsAppearance* appearance = SPDFMacFriendsReaderAppearance();
    appearance.dropdownWidth = self.dropdownWidth;
    return appearance;
}
@end

@implementation UIRig
- (SZFriendsDropdownContent*)content { return self.dropdown.content; }
- (SZFriendsListPage*)listPage { return self.dropdown.content.listPage; }
- (NSWindow*)popoverWindow { return self.dropdown.shown ? self.dropdown.content.window : nil; }
@end

#pragma mark - Failures

void UIFail(UIRig* rig, const char* file, int line, const char* condition, NSString* detail) {
    UIFailures++;
    NSString* where = rig ? [NSString stringWithFormat:@"[%@ %@ step %ld] ", rig.variant.name, rig.flow,
                                                       (long)rig.step] : @"";
    fprintf(stderr, "%s:%d: %sexpected %s\n  %s\n", file, line, where.UTF8String, condition, detail.UTF8String);
    if (!rig) return;
    NSView* root = rig.popoverWindow ? rig.content : nil;
    if (root) fprintf(stderr, "  the popover shows:\n%s\n", UIDescribe(root).UTF8String);
    if (rig.popoverWindow) UIShot(rig, @"FAILED");
}

#pragma mark - Waiting

void UISpin(NSTimeInterval seconds) {
    UIWait(seconds, ^BOOL { return NO; });
}

BOOL UIWait(NSTimeInterval seconds, BOOL (^condition)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        @autoreleasepool {
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            // Window-server events (none are expected; ours go straight to the windows) never pile up.
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event) [NSApp sendEvent:event];
            SZFE2EPump(0);
            UICheckOffscreen();
        }
    }
    return YES;
}

NSInteger UISnapshotCount(UIRig* rig, NSString* view) {
    return rig.snapshotCounts[view].integerValue;
}

BOOL UIWaitNextSnapshot(UIRig* rig, NSString* view, NSInteger count, NSTimeInterval seconds) {
    BOOL arrived = UIWait(seconds, ^BOOL { return UISnapshotCount(rig, view) > count; });
    // The views' own subscriptions receive the same frame in the same turn; let them lay out before anyone looks.
    UISpin(0.05);
    return arrived;
}

void UIObserve(UIRig* rig, NSString* view) {
    if (rig.snapshotCounts[view]) return;
    rig.snapshotCounts[view] = @0;
    __weak UIRig* weakRig = rig;
    [rig.link subscribeToView:view params:nil handler:^(NSDictionary* data, NSInteger rev) {
        (void)rev;
        UIRig* strong = weakRig;
        strong.snapshots[view] = data;
        strong.snapshotCounts[view] = @(strong.snapshotCounts[view].integerValue + 1);
    }];
}

#pragma mark - Rigs

void UIBeginFlow(UIRig* rig, NSString* flow) {
    rig.flow = flow;
    rig.step = 0;
}

NSString* UIShotPathFor(UIRig* rig, NSString* name) {
    NSString* folder = [[UIShotsRoot stringByAppendingPathComponent:rig.variant.name]
        stringByAppendingPathComponent:rig.flow ?: @"setup"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    rig.step += 1;
    return [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%02ld-%@.png", (long)rig.step, name]];
}

// `view` drawn over the dropdown's own background, so the PNG reads like the screen whatever the popover's glass does.
static BOOL UIWritePNG(NSView* view, NSColor* background, NSString* path) {
    [view layoutSubtreeIfNeeded];
    NSRect bounds = view.bounds;
    if (NSIsEmptyRect(bounds)) return NO;
    CGFloat scale = 2;
    NSBitmapImageRep* layer = [view bitmapImageRepForCachingDisplayInRect:bounds];
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{ [view cacheDisplayInRect:bounds toBitmapImageRep:layer]; }];
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(NSWidth(bounds) * scale)
                      pixelsHigh:(NSInteger)(NSHeight(bounds) * scale) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                        isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = bounds.size;
    NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [background setFill];
        NSRectFill(NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds)));
        [layer drawInRect:NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds)) fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

#pragma mark - Colours as drawn

// The colour at `point` (in `view`'s coordinates) as `view`'s window shows it, two ways: drawn again by
// cacheDisplayInRect: (what the PNGs show), and from the layers the window itself composited (the backing stores
// AppKit drew into for the screen; a visual-effect backdrop renders transparent there, so the dropdown's own
// background is laid under both). The run never captures the screen: that would need a permission prompt.
static BOOL UIColorFromRep(NSBitmapImageRep* rep, NSInteger x, NSInteger y, double rgb[3]) {
    if (x < 0 || y < 0 || x >= rep.pixelsWide || y >= rep.pixelsHigh) return NO;
    NSColor* color = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color) return NO;
    rgb[0] = color.redComponent, rgb[1] = color.greenComponent, rgb[2] = color.blueComponent;
    return YES;
}

BOOL UISampleCached(UIRig* rig, NSView* view, NSPoint point, double rgb[3]) {
    NSView* root = rig.content;
    [root layoutSubtreeIfNeeded];
    NSRect bounds = root.bounds;
    NSBitmapImageRep* layer = [root bitmapImageRepForCachingDisplayInRect:bounds];
    [root.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [root cacheDisplayInRect:bounds toBitmapImageRep:layer];
    }];
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:layer.pixelsWide pixelsHigh:layer.pixelsHigh bitsPerSample:8
                 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0
                    bitsPerPixel:0];
    rep.size = bounds.size;
    NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [root.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [rig.bridge.friendsBridgeAppearance.backgroundColor setFill];
        NSRectFill(bounds);
        [layer drawInRect:bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
            respectFlipped:YES hints:nil];
    }];
    [NSGraphicsContext restoreGraphicsState];
    NSPoint inRoot = [view convertPoint:point toView:root];
    CGFloat scale = rep.pixelsWide / NSWidth(bounds);
    CGFloat fromTop = root.isFlipped ? inRoot.y : NSHeight(bounds) - inRoot.y;
    return UIColorFromRep(rep, (NSInteger)(inRoot.x * scale), (NSInteger)(fromTop * scale), rgb);
}

BOOL UISampleWindowLayers(UIRig* rig, NSView* view, NSPoint point, double rgb[3], NSString* _Nullable savePath) {
    NSWindow* window = view.window;
    NSView* frameView = window.contentView.superview ?: window.contentView;
    [window displayIfNeeded];
    CALayer* layer = frameView.layer;
    if (!layer) return NO;
    CGFloat scale = 2;
    NSSize size = frameView.bounds.size;
    size_t width = (size_t)(size.width * scale), height = (size_t)(size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NO;
    __block CGColorRef background = NULL;
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        background = CGColorRetain(rig.bridge.friendsBridgeAppearance.backgroundColor.CGColor);
    }];
    CGContextSetFillColorWithColor(context, background);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGColorRelease(background);
    CGContextScaleCTM(context, scale, scale);
    if (layer.geometryFlipped) {
        CGContextTranslateCTM(context, 0, size.height);
        CGContextScaleCTM(context, 1, -1);
    }
    [layer renderInContext:context];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!image) return NO;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    if (savePath) [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:savePath
                                                                                           atomically:YES];
    NSPoint inFrame = [frameView convertPoint:[view convertPoint:point toView:nil] fromView:nil];
    CGFloat fromTop = frameView.isFlipped ? inFrame.y : size.height - inFrame.y;
    return UIColorFromRep(rep, (NSInteger)(inFrame.x * scale), (NSInteger)(fromTop * scale), rgb);
}

static double UILuminance(const double rgb[3]) {
    double linear[3];
    for (int i = 0; i < 3; i++)
        linear[i] = rgb[i] <= 0.04045 ? rgb[i] / 12.92 : pow((rgb[i] + 0.055) / 1.055, 2.4);
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

double UIContrast(const double a[3], const double b[3]) {
    double la = UILuminance(a), lb = UILuminance(b);
    return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}

BOOL UIShot(UIRig* rig, NSString* name) {
    NSView* frameView = rig.content.superview;
    if (!rig.popoverWindow || !frameView) return NO;
    UISpin(0.05);
    NSArray* problems = UILayoutProblems(rig);
    NSString* path = UIShotPathFor(rig, name);
    BOOL written = UIWritePNG(rig.content, rig.bridge.friendsBridgeAppearance.backgroundColor, path);
    if (!written) {
        UIFailures++;
        fprintf(stderr, "[%s %s] no screenshot at %s\n", rig.variant.name.UTF8String, rig.flow.UTF8String,
                path.UTF8String);
        return NO;
    }
    NSString* real = UIRealComputerShown(rig.content);
    if (real) problems = [problems arrayByAddingObject:[NSString stringWithFormat:@"this Mac's own \"%@\" shows", real]];
    if (problems.count && ![name isEqualToString:@"FAILED"]) {
        UIFailures++;
        fprintf(stderr, "[%s %s step %ld %s] layout:\n  %s\n  (%s)\n", rig.variant.name.UTF8String,
                rig.flow.UTF8String, (long)rig.step, name.UTF8String,
                [problems componentsJoinedByString:@"\n  "].UTF8String, path.UTF8String);
        return NO;
    }
    return YES;
}

BOOL UIShotWindow(UIRig* rig, NSWindow* window, NSString* name) {
    UISpin(0.05);
    NSView* view = window.contentView;
    NSString* real = UIRealComputerShown(view);
    if (real) {
        UIFailures++;
        fprintf(stderr, "[%s %s %s] this Mac's own \"%s\" shows\n", rig.variant.name.UTF8String, rig.flow.UTF8String,
                name.UTF8String, real.UTF8String);
    }
    return UIWritePNG(view, NSColor.windowBackgroundColor, UIShotPathFor(rig, name));
}

// The reader's title bar, as the integration suite builds it: a strip with Search at its end, and the views' button
// placed between them by the reader's own placement code.
static NSWindow* UIReaderWindow(UIVariant* variant, NSView* button) {
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                              NSWindowStyleMaskFullSizeContentView;
    NSPoint origin = UIOffscreenOrigin(NSMakeSize(900, variant.windowHeight));
    NSRect frame = NSMakeRect(origin.x, origin.y, 900, variant.windowHeight);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Friends UI test";
    window.titlebarAppearsTransparent = YES;
    NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, variant.windowHeight)];
    window.contentView = content;
    NSView* strip = [NSView new];
    NSButton* search = [NSButton buttonWithTitle:@"" target:nil action:NSSelectorFromString(@"showFavoritesPalette:")];
    search.bordered = NO;
    for (NSView* view in @[ strip, search ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [strip.topAnchor constraintEqualToAnchor:content.topAnchor], [strip.heightAnchor constraintEqualToConstant:44],
        [strip.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:80],
        [strip.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-44],
        [search.widthAnchor constraintEqualToConstant:24], [search.heightAnchor constraintEqualToConstant:24],
        [search.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
        [search.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor]
    ]];
    SPDFMacFriendsTitleBarPlacement* placement = SPDFMacFriendsInstallTitleBarButton(
        button, content, strip, SPDFMacFriendsTrailingConstraint(content, strip), search, 28);
    (void)placement;
    [content layoutSubtreeIfNeeded];
    return window;
}

NSDictionary<NSString*, NSString*>* UIDeviceEnvironment(NSString* person) {
    return @{@"SZFRIENDS_E2E_DEVICE_NAME" : [NSString stringWithFormat:@"Test computer %@", person],
             @"SZFRIENDS_E2E_DEVICE_SYSTEM" : @"Test system 1.0"};
}

// This Mac's own name and system, which no screen of the run may show (the helpers are given test ones).
static NSArray<NSString*>* UIRealComputerWords(void) {
    static NSArray<NSString*>* words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray* list = [NSMutableArray array];
        NSString* name = NSHost.currentHost.localizedName;
        if (name.length >= 4) [list addObject:name];
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        [list addObject:[NSString stringWithFormat:@"macOS %ld.%ld", (long)v.majorVersion, (long)v.minorVersion]];
        words = list;
    });
    return words;
}

NSString* UIRealComputerShown(NSView* root) {
    NSString* shown = UIDescribe(root);
    for (NSString* word in UIRealComputerWords())
        if ([shown rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) return word;
    return nil;
}

UIRig* UIStartRig(SZFE2EWorld* world, UIVariant* variant, NSString* name,
                  NSDictionary<NSString*, NSString*>* environment) {
    UIRig* rig = [UIRig new];
    rig.variant = variant;
    rig.snapshotCounts = [NSMutableDictionary dictionary];
    rig.snapshots = [NSMutableDictionary dictionary];
    rig.openedURLs = [NSMutableArray array];
    rig.helper = [world helperNamed:name];
    NSString* home = [rig.helper.stateDirectory stringByAppendingString:@"-home"];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    NSMutableDictionary* env = [UIDeviceEnvironment(name) mutableCopy];
    env[@"HOME"] = home;
    [env addEntriesFromDictionary:environment ?: @{}];
    rig.helper.extraEnvironment = env;
    if (![rig.helper start]) {
        UIFail(nil, __FILE__, __LINE__, "the helper starts", rig.helper.log);
        return nil;
    }
    // What the reader's link connects to: the client library reads these when it starts. The reader's own state (tab
    // drag key, reading copies) goes to the test home too.
    setenv("SZFRIENDS_STATE_DIR", rig.helper.stateDirectory.fileSystemRepresentation, 1);
    setenv("SPDF_STATE_DIR", home.fileSystemRepresentation, 1);
    rig.bridge = [UIBridge new];
    rig.bridge.dropdownWidth = variant.dropdownWidth;
    // A bundle with no embedded helper: the link connects to the helper this run started and never spawns one.
    NSBundle* bundle = [NSBundle bundleWithPath:home] ?: NSBundle.mainBundle;
    rig.host = [[SPDFMacFriendsHost alloc] initWithBridge:rig.bridge bundle:bundle
                                                  formats:[NSSet setWithArray:@[ @"pdf", @"md", @"txt" ]]];
    rig.link = [[SZFriendsHelperLink alloc] initWithHost:rig.host];
    rig.dropdown = [[SZFriendsDropdownController alloc] initWithHost:rig.host link:rig.link];
    [rig.dropdown install];
    if (!rig.bridge.installed) {
        UIFail(nil, __FILE__, __LINE__, "the views hand their button to the reader", @"");
        return nil;
    }
    // Nothing a test presses may reach System Settings, Finder or the general pasteboard.
    SZFriendsContext* context = rig.dropdown.context;
    __weak UIRig* weakRig = rig;
    context.openURL = ^(NSURL* url) { [weakRig.openedURLs addObject:url]; };
    context.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    context.chooseImage = ^(void (^completion)(NSString*)) { completion(nil); };
    // A popped-up menu would show on the person's screen and run its own loop: the flows choose from the record.
    rig.menus = [NSMutableArray array];
    context.presentMenu = ^(NSMenu* menu, NSView* view, NSPoint point) {
        (void)view, (void)point;
        [weakRig.menus addObject:menu];
    };
    rig.window = UIReaderWindow(variant, rig.bridge.installed);
    rig.window.appearance = [NSAppearance appearanceNamed:variant.appearance];
    [rig.window orderFrontRegardless];
    SZFriendsHelperLink* link = rig.link;
    if (!UIWait(10, ^BOOL { return link.state == SZFriendsLinkStateReady; })) {
        UIFail(nil, __FILE__, __LINE__, "the reader's link reaches the helper",
               [NSString stringWithFormat:@"state %ld; helper log:\n%@", (long)link.state, rig.helper.log]);
        UIStopRig(rig);
        return nil;
    }
    UIObserve(rig, @"list");
    UIWait(5, ^BOOL { return UISnapshotCount(rig, @"list") > 0; });
    return rig;
}

// The fake helper's socket fallback folder (szfriends-<hash>) for a state path too long for a socket; removed with
// the rig so a run leaves nothing behind.
static void UIRemoveSocketFallback(NSString* state) {
    char path[1024];
    bool fallback = false;
    if (szfriends_socket_path(state.fileSystemRepresentation, path, sizeof path, &fallback) != SZFRIENDS_OK || !fallback)
        return;
    NSString* folder = [@(path) stringByDeletingLastPathComponent];
    if ([folder.lastPathComponent hasPrefix:@"szfriends-"])
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
}

void UIStopRig(UIRig* rig) {
    if (rig.dropdown.shown) [rig.dropdown close];
    [rig.dropdown uninstall];
    [rig.link stopDisablingFriends:NO];
    [rig.window orderOut:nil];
    [rig.window close];
    UISpin(0.05);
    [rig.helper terminate];
    UIRemoveSocketFallback(rig.helper.stateDirectory);
}

BOOL UIOpenDropdown(UIRig* rig) {
    if (rig.dropdown.shown) return YES;
    NSString* why = nil;
    if (!UIClick(rig.bridge.installed, &why)) {
        UIFail(rig, __FILE__, __LINE__, "the Friends button takes the click", why ?: @"");
        return NO;
    }
    if (!UIWait(5, ^BOOL { return rig.dropdown.shown && rig.popoverWindow.isVisible; })) {
        UIFail(rig, __FILE__, __LINE__, "the dropdown opens", @"");
        return NO;
    }
    [rig.popoverWindow makeKeyWindow];
    UISpin(0.2);
    return YES;
}

BOOL UICloseDropdown(UIRig* rig) {
    if (!rig.dropdown.shown) return YES;
    [rig.dropdown close];
    return UIWait(5, ^BOOL { return !rig.dropdown.shown; });
}
