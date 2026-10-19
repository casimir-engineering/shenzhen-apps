#import "SPDFMacAIChatWindow.h"
#import <math.h>
@interface SPDFChatDocumentWindow : NSWindow
@property(nonatomic,copy) void (^escape)(void);
@end
@implementation SPDFChatDocumentWindow
- (void)sendEvent:(NSEvent*)event {
    BOOL marked=[self.firstResponder isKindOfClass:NSTextView.class] && [(NSTextView*)self.firstResponder hasMarkedText];
    if(event.type==NSEventTypeKeyDown && event.keyCode==53 && !marked && self.escape) { self.escape();return; }
    [super sendEvent:event];
}
@end
@interface SPDFMacAIChatWindow ()
@property(nonatomic) NSURL* preferencesURL;
@property(nonatomic) SPDFMacAIChatPinMode pinMode;
@property(nonatomic) BOOL readerApplicationActive;
@property(nonatomic) BOOL positioned;
@property(nonatomic) BOOL preferenceWritePending;
@end
@implementation SPDFMacAIChatWindow
+ (NSURL*)defaultPreferencesURL {
    NSString* root=NSProcessInfo.processInfo.environment[@"SPDF_STATE_DIR"];
    if(!root.length)root=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ShenzhenPDF"];
    return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"chat-window.yaml"]];
}
+ (NSWindow*)newChatWindow {
    return [[SPDFChatDocumentWindow alloc] initWithContentRect:NSMakeRect(0,0,650,600)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:YES];
}
- (instancetype)initWithContentView:(NSView*)view preferencesURL:(NSURL*)URL {
    NSWindow* window=[[self class] newChatWindow];
    if(!(self=[super initWithWindow:window]))return nil;
    _preferencesURL=URL;window.title=@"Chat — Shenzhen PDF";window.releasedWhenClosed=NO;
    window.contentMinSize=NSMakeSize(520,400);window.excludedFromWindowsMenu=NO;
    window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    window.hidesOnDeactivate=NO;window.delegate=self;window.contentView=view;
    __weak SPDFMacAIChatWindow* weakSelf=self;
    ((SPDFChatDocumentWindow*)window).escape=^{ [weakSelf hide]; };
    [self loadPreferences];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationBecameActive:)
        name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationResignedActive:)
        name:NSApplicationWillResignActiveNotification object:NSApp];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(frontApplicationChanged:)
        name:NSWorkspaceDidActivateApplicationNotification object:nil];
    self.readerApplicationActive=[self isReaderApplication:NSWorkspace.sharedWorkspace.frontmostApplication];
    [self applyPinMode];return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    self.window.delegate=nil;
}
- (BOOL)isReaderApplication:(NSRunningApplication*)application {
    NSString* identifier=NSBundle.mainBundle.bundleIdentifier;
    return application.processIdentifier==NSProcessInfo.processInfo.processIdentifier ||
        (identifier.length && [application.bundleIdentifier isEqual:identifier]) ||
        [application.bundleIdentifier isEqual:@"org.shenzhenpdf.reader.collection"];
}
- (void)applicationBecameActive:(NSNotification*)note { (void)note;self.readerApplicationActive=YES;[self applyPinMode]; }
- (void)applicationResignedActive:(NSNotification*)note {
    (void)note;self.readerApplicationActive=NO;[self applyPinMode];
    // Workspace activation can arrive before or after AppKit resignation. Drop
    // immediately, then reconcile the settled frontmost process on the next turn.
    __weak SPDFMacAIChatWindow* weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        SPDFMacAIChatWindow* owner=weakSelf;if(!owner)return;
        owner.readerApplicationActive=[owner isReaderApplication:NSWorkspace.sharedWorkspace.frontmostApplication];[owner applyPinMode];
    });
}
- (void)frontApplicationChanged:(NSNotification*)note {
    self.readerApplicationActive=[self isReaderApplication:note.userInfo[NSWorkspaceApplicationKey]];[self applyPinMode];
}
- (void)applyPinMode {
    // App-only pin is elevated only while this or a sibling reader process is
    // frontmost. It never remains globally elevated when another app activates.
    self.window.level=self.pinMode==SPDFMacAIChatPinAllApplications ? NSFloatingWindowLevel :
        self.pinMode==SPDFMacAIChatPinApplication && self.readerApplicationActive ? NSNormalWindowLevel+1 : NSNormalWindowLevel;
}
- (void)togglePinMode:(SPDFMacAIChatPinMode)mode {
    if(mode<SPDFMacAIChatPinNormal || mode>SPDFMacAIChatPinAllApplications)return;
    self.pinMode=self.pinMode==mode ? SPDFMacAIChatPinNormal : mode;
    [self applyPinMode];[self savePreferences];if(self.pinChanged)self.pinChanged(self.pinMode);
}
- (void)setChatTitle:(NSString*)title {
    self.window.title=title.length && ![title isEqual:@"New chat"] ? [@"Chat — " stringByAppendingString:title] : @"Chat — Shenzhen PDF";
    if(self.window.visible || self.window.miniaturized)[NSApp changeWindowsItem:self.window title:self.window.title filename:NO];
}
- (void)showRelativeToWindow:(NSWindow*)reader firstResponder:(NSResponder*)responder {
    if(!self.positioned) {
        NSRect screen=(reader.screen ?: NSScreen.mainScreen).visibleFrame,frame=self.window.frame;
        frame.origin=NSMakePoint(NSMidX(reader ? reader.frame : screen)-NSWidth(frame)/2,NSMaxY(reader ? reader.frame : screen)-NSHeight(frame)-60);
        if(NSWidth(screen)>0) {
            frame.origin.x=MAX(NSMinX(screen),MIN(frame.origin.x,NSMaxX(screen)-NSWidth(frame)));
            frame.origin.y=MAX(NSMinY(screen),MIN(frame.origin.y,NSMaxY(screen)-NSHeight(frame)));
        }
        [self.window setFrame:frame display:NO];self.positioned=YES;
    }
    [self applyPinMode];[NSApp addWindowsItem:self.window title:self.window.title filename:NO];
    if(self.window.miniaturized)[self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];[self.window makeFirstResponder:responder];
}
- (void)hide {
    [self savePreferences];[self.window orderOut:nil];[NSApp removeWindowsItem:self.window];
    if(self.closed)self.closed();
}
- (BOOL)windowShouldClose:(NSWindow*)sender { (void)sender;[self hide];return NO; }
- (void)windowDidMove:(NSNotification*)note { (void)note;[self schedulePreferenceWrite]; }
- (void)windowDidResize:(NSNotification*)note { (void)note;[self schedulePreferenceWrite]; }
- (void)schedulePreferenceWrite {
    if(!self.positioned || self.preferenceWritePending)return;self.preferenceWritePending=YES;
    __weak SPDFMacAIChatWindow* weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        SPDFMacAIChatWindow* owner=weakSelf;if(!owner)return;owner.preferenceWritePending=NO;[owner savePreferences];
    });
}
- (void)loadPreferences {
    NSDictionary* attributes=[NSFileManager.defaultManager attributesOfItemAtPath:self.preferencesURL.path error:nil];
    if(!attributes || [attributes fileSize]>4096)return;
    NSString* text=[NSString stringWithContentsOfURL:self.preferencesURL encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary* values=[NSMutableDictionary dictionary];
    for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
        NSRange colon=[line rangeOfString:@":"];if(colon.location==NSNotFound)continue;
        values[[line substringToIndex:colon.location]]=[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    self.pinMode=[values[@"pin"] isEqual:@"app"] ? SPDFMacAIChatPinApplication : [values[@"pin"] isEqual:@"all"] ? SPDFMacAIChatPinAllApplications : SPDFMacAIChatPinNormal;
    NSRect frame=NSMakeRect([values[@"x"] doubleValue],[values[@"y"] doubleValue],[values[@"width"] doubleValue],[values[@"height"] doubleValue]);
    if(!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height) || NSWidth(frame)<520 || NSHeight(frame)<422)return;
    for(NSScreen* screen in NSScreen.screens)if(NSIntersectsRect(frame,screen.visibleFrame)) {
        frame.size.width=MIN(NSWidth(frame),NSWidth(screen.visibleFrame));frame.size.height=MIN(NSHeight(frame),NSHeight(screen.visibleFrame));
        frame.origin.x=MAX(NSMinX(screen.visibleFrame),MIN(NSMinX(frame),NSMaxX(screen.visibleFrame)-NSWidth(frame)));
        frame.origin.y=MAX(NSMinY(screen.visibleFrame),MIN(NSMinY(frame),NSMaxY(screen.visibleFrame)-NSHeight(frame)));
        [self.window setFrame:frame display:NO];self.positioned=YES;break;
    }
}
- (void)savePreferences {
    if(!self.preferencesURL)return;NSRect frame=self.window.frame;
    NSString* mode=self.pinMode==SPDFMacAIChatPinApplication ? @"app" : self.pinMode==SPDFMacAIChatPinAllApplications ? @"all" : @"normal";
    NSString* text=[NSString stringWithFormat:@"pin: %@\nx: %.0f\ny: %.0f\nwidth: %.0f\nheight: %.0f\n",mode,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height];
    NSError* error=nil;
    [NSFileManager.defaultManager createDirectoryAtURL:self.preferencesURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
    if(!error)[text writeToURL:self.preferencesURL atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if(!error)[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.preferencesURL.path error:nil];
}
@end
