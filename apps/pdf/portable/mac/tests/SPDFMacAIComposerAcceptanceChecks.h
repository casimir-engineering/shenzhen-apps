// Real composer -> reader integration -> session -> URLSession, entirely offline.
#import "SPDFMacAIChatView.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacUnifiedSettings.h"
#import "SPDFMacCollectionPaletteModel.h"
#import "SPDFMacPalettePresentation.h"
static NSUInteger composerRequests, composerTitleRequests;
static NSURLRequest* composerRequest;
@interface ComposerReplyProtocol : NSURLProtocol @end
@implementation ComposerReplyProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest*)request { (void)request;return YES; }
+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request { return request; }
- (void)startLoading {
    NSData* data=self.request.HTTPBody;
    if(!data && self.request.HTTPBodyStream) {
        NSInputStream* stream=self.request.HTTPBodyStream;[stream open];NSMutableData* bytes=[NSMutableData data];
        uint8_t buffer[2048];NSInteger count;
        while((count=[stream read:buffer maxLength:sizeof(buffer)])>0)[bytes appendBytes:buffer length:(NSUInteger)count];
        [stream close];data=bytes;
    }
    NSDictionary* payload=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    Check(payload!=nil,"offline composer transport receives valid request JSON");
    NSString* instruction=[payload[@"messages"] firstObject][@"content"];
    BOOL title=[instruction hasPrefix:@"Summarize this conversation in a plain title"];
    // Count real chat sends separately, so an intentional lazy title request can
    // never hide a duplicate Return submission or make it look like one.
    @synchronized(ComposerReplyProtocol.class) {
        if(title)composerTitleRequests++;
        else {composerRequests++;composerRequest=self.request;}
    }
    if(title)Check(![payload[@"tools"] count],"title request cannot execute app tools");
    NSHTTPURLResponse* response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type":@"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSData* reply=[NSJSONSerialization dataWithJSONObject:@{@"choices":@[@{@"message":
        @{@"role":@"assistant",@"content":title ? @"Offline document discussion" : @"Offline acceptance reply"}}]} options:0 error:nil];
    [self.client URLProtocol:self didLoadData:reply];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
@interface ShenzhenMacDelegate (ComposerAcceptanceHost)
- (id)readerAIState;
- (NSString*)aiAPIKeyForSending:(NSError**)error;
- (SPDFMacAITransport*)aiChatTransport;
@end
@interface ComposerReaderProbe : ShenzhenMacDelegate
@property(nonatomic) NSString* testKey;
@property(nonatomic) NSError* keyError;
@property(nonatomic) NSUInteger keyReads;
@property(nonatomic) NSUInteger settingsOpens;
@property(nonatomic) NSString* authorizedKey;
@property(nonatomic) NSUInteger authorizationCalls;
@property(nonatomic) NSUInteger catalogRequests;
@end
@implementation ComposerReaderProbe
- (NSString*)aiAPIKeyForSending:(NSError**)error {
    self.keyReads++;if(error)*error=self.keyError;return self.testKey;
}
- (NSString*)aiAuthorizeAPIKeyForSending:(NSError**)error {
    self.authorizationCalls++;if(error)*error=self.authorizedKey ? nil : SPDFMacAIError(-128,@"Cancelled");return self.authorizedKey;
}
- (SPDFMacAITransport*)aiChatTransport {
    NSURLSessionConfiguration* configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses=@[ComposerReplyProtocol.class];
    return [[SPDFMacAITransport alloc] initWithConfiguration:configuration];
}
- (void)showUnifiedSettingsMode:(BOOL)wizard { (void)wizard;self.settingsOpens++; }
// The model list is never fetched in tests; it arrives without the chosen model.
- (void)requestAIModels { self.catalogRequests++; [self aiModelListDidLoad:@[@{@"id":@"fixture/other-model"}]]; }
- (void)showUnifiedSettings:(id)sender { (void)sender;self.settingsOpens++; }
- (void)showAIConnectionSettingsWithReason:(NSString*)reason { (void)reason;self.settingsOpens++; }
@end
@interface ComposerPaletteProbe : ComposerReaderProbe
@property(nonatomic) NSUInteger chatOpens;
- (void)seedEmptySearchPalette;
@end
@implementation ComposerPaletteProbe
- (void)seedEmptySearchPalette {
    // As an empty search shows it: the chat row first and highlighted.
    _paletteMode=1;_paletteSearchField=[NSSearchField new];_paletteSearchField.stringValue=@"";
    _paletteTable=[NSTableView new];_paletteTable.dataSource=self;
    _paletteResults=[NSMutableArray arrayWithObject:spdf_collection_palette_chat_row(@"")];
    [_paletteTable reloadData];[self selectFirstPaletteResult];
}
- (void)showAIChatForQuery:(NSString*)query { (void)query;self.chatOpens++; }
@end
static BOOL ComposerWait(BOOL (^predicate)(void)) {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!predicate() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    return predicate();
}
static NSUInteger ComposerRequestCount(void) {
    @synchronized(ComposerReplyProtocol.class) { return composerRequests; }
}
static NSUInteger ComposerTitleRequestCount(void) {
    @synchronized(ComposerReplyProtocol.class) { return composerTitleRequests; }
}
static NSEvent* ComposerReturn(BOOL shift,NSInteger windowNumber) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:shift ? NSEventModifierFlagShift : 0 timestamp:0 windowNumber:windowNumber
        context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
}
static NSString* ComposerStatus(SPDFMacAIChatView* view) {
    NSString* issue=[(NSTextField*)[view valueForKey:@"issueText"] stringValue];
    return issue.length ? issue : [(NSTextField*)[view valueForKey:@"status"] stringValue];
}
static void SaveComposerSettings(BOOL configured,BOOL enabled,BOOL setupComplete) {
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
    Check([settings load:nil],"composer fixture settings load");settings.connectionConfigured=configured;settings.enabled=enabled;
    settings.onboardingRevision=setupComplete ? SPDFUnifiedSettingsExperienceVersion : 0;
    settings.automaticAnalysis=NO;settings.model=@"offline/test-model";
    Check([settings save:nil],"composer fixture settings save");
}
#import "SPDFMacAIComposerEventChecks.h"
#import "SPDFMacAIComposerEditChecks.h"
static void CheckComposerAcceptance(void) {
    // The surrounding acceptance binary sets SPDF_STATE_DIR to a fresh temporary directory.
    Check([SPDFMacAISettings.defaultURL.path hasPrefix:NSTemporaryDirectory().stringByResolvingSymlinksInPath] ||
        [SPDFMacAISettings.defaultURL.path hasPrefix:NSTemporaryDirectory()],"composer settings are isolated from user state");
    ComposerPaletteProbe* palette=[ComposerPaletteProbe new];[palette seedEmptySearchPalette];
    NSUInteger routingRequests=ComposerRequestCount();[palette activatePaletteSelection:nil];
    Check(palette.chatOpens==1 && !palette.settingsOpens && !palette.keyReads && ComposerRequestCount()==routingRequests,
        "empty Cmd K Return routes directly to one new chat without Settings, credentials or network");
    ComposerReaderProbe* reader=[ComposerReaderProbe new];reader.testKey=@"sk-or-v1-offline-acceptance-only";
    id state=[reader readerAIState];SPDFMacAIChatView* view=[state valueForKey:@"view"];
    SPDFMacAIChatSession* session=[state valueForKey:@"session"];
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,650,540)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed=NO;window.contentView=view;[window makeFirstResponder:view.composer];
    [view displaySession:session];
    SaveComposerSettings(NO,YES,YES);
    NSUInteger initialRequests=ComposerRequestCount(),initialTitles=ComposerTitleRequestCount();view.composer.string=@"Send from Return with a stale flag";
    [view.composer keyDown:ComposerReturn(NO,window.windowNumber)];
    Check(ComposerWait(^BOOL{return session.chat[@"messages"] && [session.chat[@"messages"] count]==2 && !session.running;}),
        "actual composer Return receives offline assistant reply through production integration");
    Check(ComposerRequestCount()==initialRequests+1 && reader.keyReads==1 && !view.composer.string.length,
        "Return sends exactly once and clears accepted draft");
    Check(ComposerWait(^BOOL{return [session.chat[@"title"] isEqual:@"Offline document discussion"];}),
        "lazy title request finishes independently after the accepted answer");
    Check(ComposerTitleRequestCount()==initialTitles+1 && ComposerRequestCount()==initialRequests+1,
        "one answer schedules one title without another real chat send");
    Check(!reader.settingsOpens,"stale connection flag never opens Settings");
    SPDFMacAISettings* repaired=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];[repaired load:nil];
    Check(repaired.connectionConfigured,"valid saved key repairs false connection flag");
    Check([session.chat[@"messages"][0][@"content"] isEqual:@"Send from Return with a stale flag"] &&
        [session.chat[@"messages"][1][@"content"] isEqual:@"Offline acceptance reply"],"chat retains submitted text and model reply");
    @synchronized(ComposerReplyProtocol.class) {
        Check([[composerRequest valueForHTTPHeaderField:@"Authorization"] isEqual:[@"Bearer " stringByAppendingString:reader.testKey]],
            "production transport receives only fixture credential");
    }
    // A normal already-connected send also crosses the same production entry point.
    NSUInteger before=ComposerRequestCount();view.composer.string=@"Second message";
    [view.composer keyDown:ComposerReturn(NO,window.windowNumber)];
    Check(ComposerWait(^BOOL{return [session.chat[@"messages"] count]==4 && !session.running;}),"configured Return send completes");
    Check(ComposerRequestCount()==before+1 && reader.keyReads==2 && !reader.settingsOpens,"configured Return avoids Settings");
    before=ComposerRequestCount();NSUInteger reads=reader.keyReads;view.composer.string=@"First line";
    [view.composer setSelectedRange:NSMakeRange(view.composer.string.length,0)];
    [view.composer keyDown:ComposerReturn(YES,window.windowNumber)];
    Check([view.composer.string isEqual:@"First line\n"] && ComposerRequestCount()==before && reader.keyReads==reads,
        "actual Shift Return inserts newline without credentials or network");
    // Denied and absent credentials must preserve the conversation and draft in place.
    for(NSNumber* denied in @[@YES,@NO]) {
        SaveComposerSettings(YES,YES,YES);reader.testKey=nil;
        reader.keyError=denied.boolValue ? SPDFMacAIError(-25308,@"Keychain access denied. Allow access and retry.") : nil;
        NSString* draft=denied.boolValue ? @"Keep denied draft" : @"Keep missing-key draft";
        view.composer.string=draft;reads=reader.keyReads;before=ComposerRequestCount();
        [view.composer keyDown:ComposerReturn(NO,window.windowNumber)];
        Check([view.composer.string isEqual:draft] && reader.keyReads==reads+1 && ComposerRequestCount()==before,
            "credential failure keeps draft without a model request");
        Check(!reader.settingsOpens && window.contentView==view && [session.chat[@"messages"] count]==4,
            "credential failure stays in the same chat without Settings navigation");
        NSString* status=ComposerStatus(view).lowercaseString;
        Check(status.length && ([status containsString:@"settings"] || [status containsString:@"retry"] || [status containsString:@"connect"] || [status containsString:@"authorize"]),
            "credential failure shows actionable inline status");
    }
    for(NSNumber* incomplete in @[@YES,@NO]) {
        SaveComposerSettings(YES,incomplete.boolValue,!incomplete.boolValue);
        reader.testKey=@"sk-or-v1-offline-acceptance-only";reader.keyError=nil;
        NSString* draft=incomplete.boolValue ? @"Complete setup later" : @"Enable chat later";
        view.composer.string=draft;reads=reader.keyReads;before=ComposerRequestCount();
        [view.composer keyDown:ComposerReturn(NO,window.windowNumber)];
        Check([view.composer.string isEqual:draft] && reader.keyReads==reads && ComposerRequestCount()==before,
            "setup-incomplete or disabled chat never reads credentials or sends");
        Check(!reader.settingsOpens && ComposerStatus(view).length,"blocked setup stays in chat with inline guidance");
    }
    SaveComposerSettings(YES,YES,YES);before=ComposerRequestCount();view.composer.string=@"Retry after restoring settings";
    [view.composer keyDown:ComposerReturn(NO,window.windowNumber)];
    Check(ComposerWait(^BOOL{return [session.chat[@"messages"] count]==6 && !session.running;}),"Return can retry after inline rejection");
    Check(ComposerRequestCount()==before+1 && !view.composer.string.length && !reader.settingsOpens,
        "recovery sends exactly once without replacing the chat");
    reader.testKey=nil;reader.keyError=SPDFMacAIError(-25293,@"Fixture authorization failure");
    view.composer.string=@"Authorize this retained draft";before=ComposerRequestCount();
    [view.composer keyDown:ComposerReturn(NO,window.windowNumber)];
    NSView* issue=[view valueForKey:@"issue"];NSButton* recovery=[view valueForKey:@"recovery"];
    Check(!issue.hidden && [recovery.identifier isEqual:@"authorize"] && [recovery.title containsString:@"Authorize"] &&
        !reader.authorizationCalls,"Return exposes visible authorization recovery without prompting automatically");
    [view layoutSubtreeIfNeeded];NSScrollView* composerBox=[view valueForKey:@"input"];
    Check(NSIntersectsRect(issue.frame,view.bounds) && NSHeight(issue.frame)>=40 &&
        NSMaxY(issue.frame)<=NSMinY(composerBox.frame)+1 && NSWidth(recovery.frame)>80,
        "authorization issue and action are laid out visibly directly above the composer");
    NSString* evidence=NSProcessInfo.processInfo.environment[@"SPDF_AI_AUTH_EVIDENCE_DIR"];
    if(evidence.length)for(NSNumber* width in @[@650,@520])for(NSString* appearance in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
        [window setContentSize:NSMakeSize(width.doubleValue,540)];view.appearance=[NSAppearance appearanceNamed:appearance];
        [view layoutSubtreeIfNeeded];
        for(NSNumber* x in @[@2,@(NSWidth(recovery.bounds)-2)])for(NSNumber* y in @[@2,@(NSHeight(recovery.bounds)-2)]) {
            NSPoint point=[recovery convertPoint:NSMakePoint(x.doubleValue,y.doubleValue) toView:view.superview];NSView* hit=[view hitTest:point];
            Check(hit==recovery || [hit isDescendantOf:recovery],"authorization button full inset hit rectangle is clickable");
        }
        NSBitmapImageRep* image=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
        NSString* file=[NSString stringWithFormat:@"ai-chat-authorization-%@-%@.png",width,[appearance isEqual:NSAppearanceNameAqua] ? @"light" : @"dark"];
        Check([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[evidence stringByAppendingPathComponent:file] atomically:YES],
            "headless authorization preview exported");
    }
    reads=reader.keyReads;[recovery performClick:nil];
    Check(reader.authorizationCalls==1 && reader.keyReads==reads && ComposerRequestCount()==before &&
        [view.composer.string isEqual:@"Authorize this retained draft"] && !issue.hidden,
        "cancelled authorization preserves the draft without rereading credentials or sending");
    reader.authorizedKey=@"sk-or-v1-interactive-fixture-only";[recovery performClick:nil];
    Check(ComposerWait(^BOOL{return [session.chat[@"messages"] count]==8 && !session.running;}),
        "explicit authorization button sends retained draft with granted key");
    Check(reader.authorizationCalls==2 && reader.keyReads==reads && ComposerRequestCount()==before+1 &&
        !view.composer.string.length && issue.hidden && !reader.settingsOpens,
        "authorization success clears inline issue and draft without a second denied Keychain read");
    CheckComposerEditAndSummary(reader,view,session);
    [session cancel];window.contentView=nil;[window close];
    CheckComposerEventDispatch();
}
