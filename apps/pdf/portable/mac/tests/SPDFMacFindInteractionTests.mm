#import "SPDFMacMenuText.h"
#import "SPDFMacFindInteraction.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacWorkspaceChrome.h"
#import "SPDFMacTabTitleDrawing.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
@end
#pragma clang diagnostic pop
@interface FindWindow : NSWindow
@property BOOL simulatesFullscreen;
@end
@implementation FindWindow
- (NSWindowStyleMask)styleMask { return [super styleMask] | (self.simulatesFullscreen ? NSWindowStyleMaskFullScreen : 0); }
@end
@interface FindGroupPickerProbe : NSView
@property BOOL shown;
- (BOOL)dismissGroupPickerIfShown;
@end
@implementation FindGroupPickerProbe
- (BOOL)dismissGroupPickerIfShown { BOOL shown=self.shown; self.shown=NO; return shown; }
@end
@interface FindProbe : ShenzhenMacDelegate
@property NSObject* tabIdentity;
@property NSUInteger clears;
@property NSUInteger searches;
@property NSUInteger saves;
@property NSInteger direction;
- (void)seedMatches;
- (void)openGroupPicker;
- (void)seedMode:(NSInteger)mode visible:(BOOL)visible;
- (NSInteger)mode;
- (BOOL)visible;
- (NSString*)query;
- (void)editQuery:(NSString*)query;
- (void)focusTextView;
- (void)focusDocument;
- (void)setMode:(NSInteger)mode;
- (void)setFullscreen:(BOOL)fullscreen presentation:(BOOL)presentation;
@end
@implementation FindProbe
- (void)openGroupPicker { FindGroupPickerProbe* picker=[FindGroupPickerProbe new]; picker.shown=YES; _tabStrip=(id)picker; }
- (instancetype)init {
    if ((self = [super init])) {
        _window = (id)[[FindWindow alloc] initWithContentRect:NSMakeRect(0,0,500,300)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        _window.releasedWhenClosed = NO;
        _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(0,0,200,30)];
        [_window.contentView addSubview:_searchField];
        _sidebarModeControl = [NSSegmentedControl new];
        spdf_sidebar_mode_control_configure_navigation(_sidebarModeControl,YES,YES);
        self.tabIdentity = [NSObject new];
    }
    return self;
}
- (void)seedMode:(NSInteger)mode visible:(BOOL)visible {
    _sidebarModeControl.spdf_selectedSidebarMode = mode; _sidebarPreferredVisible = visible;
    [self focusDocument];
}
- (SPDFDocumentTab*)selectedTab { return (id)self.tabIdentity; }
- (BOOL)hasActiveDocument { return YES; }
- (void)seedMatches { _findMatches=[NSMutableArray arrayWithObject:@{}]; }
- (void)findFromCurrentForward:(BOOL)forward { self.direction=forward ? 1 : -1; }
- (NSInteger)mode { return _sidebarModeControl.spdf_selectedSidebarMode; }
- (void)setMode:(NSInteger)mode { _sidebarModeControl.spdf_selectedSidebarMode = mode; }
- (BOOL)visible { return _sidebarPreferredVisible; }
- (void)setFullscreen:(BOOL)fullscreen presentation:(BOOL)presentation {
    ((FindWindow*)_window).simulatesFullscreen = fullscreen; _presentationMode = presentation;
}
- (NSString*)query { return _searchField.stringValue; }
- (void)editQuery:(NSString*)query { _searchField.stringValue = query; }
- (void)revealWorkspaceFind {
    [self rememberPanelBeforeFind];
    _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeSearch; _sidebarPreferredVisible = YES;
}
- (void)startFindForCurrentQuery { self.clears++; }
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal {
    NSCAssert(reset && reveal, @"typing starts a fresh visible search"); self.searches++;
}
- (void)clearFindFieldFocus { [self focusDocument]; }
- (void)rebuildSidebar {}
- (void)syncWorkspaceChrome {}
- (void)rememberSidebarWorkspaceMode { self.saves++; }
- (void)focusTextView {
    NSTextView* edit = [[NSTextView alloc] initWithFrame:NSMakeRect(0,50,300,100)];
    [_window.contentView addSubview:edit]; [_window makeFirstResponder:edit];
}
- (void)focusDocument { [_window makeFirstResponder:_window]; }
@end
static NSUInteger failures;
static void Check(BOOL ok,NSString* message) { if (!ok) { fprintf(stderr,"FAIL %s\n",message.UTF8String); failures++; } }
static NSEvent* Key(NSString* text,unsigned short code,NSEventModifierFlags flags=0) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:0 context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}
static NSBitmapImageRep* TitlePixels(NSString* title) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:120 pixelsHigh:24
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSColor.whiteColor setFill]; NSRectFill(NSMakeRect(0,0,120,24));
    NSDictionary* attributes = @{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName:NSColor.blackColor, NSParagraphStyleAttributeName:SPDFTabTitleParagraphStyle()};
    NSRect rect = SPDFTabTitleRect(NSMakeRect(0,0,120,24),0,0,title,attributes);
    NSRect groupRect = SPDFTabTitleRect(NSMakeRect(0,2,120,20),0,0,title,attributes);
    Check(NSEqualRects(rect,groupRect),@"group and document labels share the same vertical text geometry");
    NSRectClip(rect);
    SPDFDrawTabTitle(title,rect,attributes);
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}
static NSUInteger PixelDifferences(NSBitmapImageRep* first, NSBitmapImageRep* second, NSInteger start, NSInteger end) {
    NSUInteger differences = 0;
    for (NSInteger y=0;y<24;y++) for (NSInteger x=start;x<end;x++) {
        NSColor* a = [[first colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor* b = [[second colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (fabs(a.redComponent-b.redComponent) > .08) differences++;
    }
    return differences;
}
static void CheckTabTitlePixels(void) {
    NSString* middle = @"MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM";
    NSBitmapImageRep* original = TitlePixels([NSString stringWithFormat:@"AA%@XX",middle]);
    NSBitmapImageRep* suffix = TitlePixels([NSString stringWithFormat:@"AA%@ZZ",middle]);
    NSBitmapImageRep* prefix = TitlePixels([NSString stringWithFormat:@"BB%@XX",middle]);
    Check(PixelDifferences(original,suffix,88,120)>10,@"actual AppKit pixels retain distinctive long-title suffix");
    Check(PixelDifferences(original,prefix,0,32)>10,@"actual AppKit pixels retain distinctive long-title prefix");
    Check(PixelDifferences(original,suffix,0,64)==0,@"changing hidden/end text does not disturb beginning geometry");
    NSMutableString* hiddenChange = [middle mutableCopy];
    [hiddenChange replaceCharactersInRange:NSMakeRange(20,10) withString:@"NNNNNNNNNN"];
    NSBitmapImageRep* changedMiddle = TitlePixels([NSString stringWithFormat:@"AA%@XX",hiddenChange]);
    Check(SPDFTabTitleParagraphStyle().lineBreakMode == NSLineBreakByTruncatingMiddle &&
        PixelDifferences(original,changedMiddle,0,120)==0,@"hidden middle text changes preserve ellipsis and both visible ends");
}
int main(int argc, const char* argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSEvent* escape = Key(@"\033",53);
        for (NSNumber* mode in @[@0,@1,@3,@4]) for (NSNumber* visible in @[@YES,@NO]) {
            FindProbe* reader = [FindProbe new]; [reader seedMode:mode.integerValue visible:visible.boolValue];
            Check(![reader documentEscapeKeyDown:escape],@"unused search allocates no dismiss state");
            Check([reader documentTypeToSearchKeyDown:Key(@"字",0)],@"typing in a passive view starts Find");
            Check(reader.mode == SPDFSidebarModeSearch && reader.visible && [reader.query isEqual:@"字"],@"Find is revealed with typed text");
            [reader revealWorkspaceFind]; [reader editQuery:@"more typing"];
            [reader openGroupPicker];
            Check([reader documentEscapeKeyDown:escape] && [reader.query isEqual:@"more typing"] && reader.clears==0 && reader.mode==SPDFSidebarModeSearch,
                @"first Escape dismisses Groups before touching the search or panel");
            Check([reader documentEscapeKeyDown:escape],@"next Escape dismisses active Find");
            Check(reader.mode == mode.integerValue && reader.visible == visible.boolValue,@"Escape restores exact preceding panel/visibility");
            Check(reader.query.length == 0 && reader.clears == 1,@"Escape clears query and highlights once");
            Check(![reader documentEscapeKeyDown:escape],@"repeated Escape has no stale return state");
            [reader revealWorkspaceFind]; [reader dismissWorkspaceFind];
            Check(reader.mode == mode.integerValue,@"Escape in empty explicit Find restores panel too");
        }
        FindProbe* reader = [FindProbe new]; [reader seedMode:SPDFSidebarModeGroups visible:YES];
        [reader focusTextView];
        Check(![reader documentTypeToSearchKeyDown:Key(@"a",0)],@"text editors and IME input retain typing");
        [reader focusDocument];
        Check(![reader documentTypeToSearchKeyDown:Key(@"f",3,NSEventModifierFlagCommand)],@"command shortcuts retain meaning");
        Check(![reader documentTypeToSearchKeyDown:Key(@"é",0,NSEventModifierFlagOption)],@"option/dead keys are not intercepted");
        Check(![reader documentTypeToSearchKeyDown:Key(@"\uF700",126)],@"function keys are never search text");
        [reader revealWorkspaceFind]; [reader setMode:SPDFSidebarModeHistory]; [reader dismissWorkspaceFind];
        Check(reader.mode == SPDFSidebarModeHistory,@"deliberately choosing another panel wins over stale Find state");
        [reader seedMode:SPDFSidebarModeGroups visible:YES]; [reader revealWorkspaceFind];
        reader.tabIdentity = [NSObject new]; [reader dismissWorkspaceFind];
        Check(reader.mode == SPDFSidebarModeSearch,@"old document panel is not restored into a different tab");
        [reader seedMode:SPDFSidebarModeHistory visible:YES]; [reader setFullscreen:YES presentation:NO];
        [reader revealWorkspaceFind]; [reader editQuery:@"fullscreen query"];
        Check([reader documentEscapeKeyDown:escape] && reader.mode == SPDFSidebarModeHistory,
            @"Escape in fullscreen dismisses Find and returns to preceding panel");
        Check(![reader documentEscapeKeyDown:escape],@"next Escape remains available for native fullscreen exit");
        [reader revealWorkspaceFind]; [reader editQuery:@"presentation query"];
        [reader setFullscreen:YES presentation:YES];
        Check(![reader documentEscapeKeyDown:escape] && reader.query.length > 0,
            @"presentation Escape keeps its independent presentation-exit behavior");
        NSString* root = argc > 1 ? @(argv[1]) : @"mac";
        NSString* drawing = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"SPDFMacTabStripDrawing.mm"] encoding:NSUTF8StringEncoding error:nil];
        Check([drawing containsString:@"SPDFTabTitleParagraphStyle()"] && [drawing containsString:@"SPDFDrawTabTitle(title, titleRect, titleAttrs)"],
            @"tab renderer uses the pixel-tested middle-ellipsis draw path");
        CheckTabTitlePixels();
        Check([drawing containsString:@"kCGBlendModeDestinationOut"] && [drawing containsString:@"if (hovered)"],@"hover close retains trailing fade overlay");
        NSString* chrome = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"SPDFMacWorkspaceChrome.mm"] encoding:NSUTF8StringEncoding error:nil];
        Check([chrome containsString:@"- (void)revealWorkspaceFind {\n    [self rememberPanelBeforeFind];"],@"all Find entry paths capture previous panel before changing mode");
        NSString* host = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"SPDFMacUIHelpers.mm"] encoding:NSUTF8StringEncoding error:nil];
        Check([host containsString:@"event.type == NSEventTypeKeyDown && !self.attachedSheet"] &&
            [host containsString:@"[self.reader documentTypeToSearchKeyDown:event])) return"],@"window routes passive controls without stealing sheets/editors");
        FindProbe* returns=[FindProbe new]; [returns seedMode:SPDFSidebarModeSearch visible:YES];
        [returns editQuery:@"text"]; [returns seedMatches];
        Check([returns documentFindReturnKeyDown:Key(@"\r",36)] && returns.direction==1,@"Return advances search from document");
        Check([returns documentFindReturnKeyDown:Key(@"\r",36,NSEventModifierFlagCommand)] && returns.direction==-1,@"Command Return goes to previous result");
        [returns focusTextView]; Check(![returns documentFindReturnKeyDown:Key(@"\r",36)],@"Return in another editor is untouched");
        Check([SPDFMenuSelectionPreview(@"  a\n b  ") isEqual:@"a b"],@"context preview collapses whitespace");
        NSString* enormous=[@"document " stringByPaddingToLength:8000000 withString:@"document " startingAtIndex:0];
        CFAbsoluteTime started=CFAbsoluteTimeGetCurrent();
        for (NSUInteger i=0;i<100;i++) Check(SPDFMenuSelectionPreview(enormous).length<=43,@"large selection preview stays short");
        printf("Context menu preview: 8M characters, 100 previews in %.2f ms\n",(CFAbsoluteTimeGetCurrent()-started)*1000);
        if (!failures) puts("SPDFMacFindInteractionTests passed");
        return failures ? 1 : 0;
    }
}
