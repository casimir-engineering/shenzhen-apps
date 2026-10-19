#import "../SPDFMacAITranslation.h"
#import "../SPDFMacAITransport.h"
#import "../SPDFMacAITranslationPanel.h"
#import "SPDFMacReadmeWindowCapture.h"
FOUNDATION_EXPORT NSMenu* SPDFMacTranslationChoiceMenu(id target);
@interface TranslationChoiceTarget : NSObject
@property NSInteger local;
@property NSInteger ai;
@end
@implementation TranslationChoiceTarget
- (void)translateDocumentLocally:(id)sender {(void)sender;self.local++;}
- (void)translateDocumentWithAI:(id)sender {(void)sender;self.ai++;}
@end
static int failures=0,requests=0,mode=0;
static void Check(BOOL condition,const char* name){if(!condition){fprintf(stderr,"FAIL %s\n",name);++failures;}}
static BOOL Wait(BOOL(^ready)(void)) {
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:3];
    while(!ready() && end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return ready();
}
@interface TranslationProtocol : NSURLProtocol @end
@implementation TranslationProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest*)request {(void)request;return YES;}
+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request{return request;}
- (void)startLoading {
    ++requests;if(mode==2)return;
    [self.client URLProtocol:self didReceiveResponse:[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:mode==1 ? 401 : 200 HTTPVersion:@"HTTP/1.1" headerFields:nil] cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSString* response=@"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"# Bonjour\\nTraduction.\"},\"finish_reason\":\"stop\"}]}";
    if(mode==3)response=@"{\"choices\":[{\"message\":{\"content\":null},\"finish_reason\":\"stop\"}]}";
    [self.client URLProtocol:self didLoadData:[response dataUsingEncoding:NSUTF8StringEncoding]];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
int main(){@autoreleasepool {
    [NSApplication sharedApplication];NSError* error=nil;
    TranslationChoiceTarget* target=[TranslationChoiceTarget new];NSMenu* menu=SPDFMacTranslationChoiceMenu(target);
    Check(menu.numberOfItems==2 && [[menu itemAtIndex:0].title isEqual:@"Local"] && [[menu itemAtIndex:1].title isEqual:@"AI"],"chooser has two explicit providers");
    [menu performActionForItemAtIndex:0];[menu performActionForItemAtIndex:1];
    Check(target.local==1 && target.ai==1,"native chooser routes local and AI independently");
    Check(!SPDFMacAITranslationChunks(@"",&error) && error!=nil,"empty documents rejected before any request");
    Check(!SPDFMacAITranslationChunks(@"   \n",&error) && ![error.localizedDescription containsString:@"exceeds"],"whitespace input has correct no-text error");
    NSString* longText=[@"a" stringByPaddingToLength:500001 withString:@"a" startingAtIndex:0];
    Check(!SPDFMacAITranslationChunks(longText,&error),"oversize documents rejected explicitly, never truncated");
    NSProgress* preparation=[NSProgress progressWithTotalUnitCount:-1];NSMutableString* bounded=[NSMutableString stringWithString:@"before"];
    [preparation cancel];Check(!SPDFMacAITranslationAppendLine(bounded,@"after",preparation,&error) && [bounded isEqual:@"before"],"cancelled extraction appends nothing");
    preparation=[NSProgress progressWithTotalUnitCount:-1];
    Check(!SPDFMacAITranslationAppendLine(bounded,longText,preparation,&error) && bounded.length==6,"limit rejects oversized line before appending");
    SPDFMacAITranslationPanel* preparing=[[SPDFMacAITranslationPanel alloc] initWithSourceName:@"/tmp/preparing.pdf" language:@"en"];
    Check([[preparing valueForKey:@"cancel"] isEnabled],"preparation can be cancelled immediately");
    [[preparing valueForKey:@"cancel"] performClick:nil];[preparing setSourceText:@"stale extraction" error:nil];
    Check(preparing.preparation.cancelled && ![[preparing valueForKey:@"send"] isEnabled],"cancelled preparation cannot revive stale extracted text");
    Check([preparing.window.title containsString:@"preparing.pdf"],"translation identifies its captured source");
    NSString* content=[@"\n👨‍👩‍👧‍👦" stringByPaddingToLength:8000 withString:@"Bonjour\n" startingAtIndex:0];
    NSArray* chunks=SPDFMacAITranslationChunks(content,&error);
    Check([[chunks componentsJoinedByString:@""] isEqual:content] && chunks.count>1,"chunking preserves all Unicode source content");
    NSURLSessionConfiguration* configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.protocolClasses=@[TranslationProtocol.class];
    SPDFMacAITranslation* service=[[SPDFMacAITranslation alloc] initWithTransport:[[SPDFMacAITransport alloc] initWithConfiguration:configuration]];
    Check(requests==0,"service construction is inert");
    SPDFMacAITranslationPanel* panel=[[SPDFMacAITranslationPanel alloc] initWithSourceName:@"/tmp/source.pdf" language:@"fr"];
    [panel setSourceText:@"Hello" error:nil];[panel.window.contentView layoutSubtreeIfNeeded];
    Check(requests==0,"opening and populating AI panel does not send content");
    Check([[panel valueForKey:@"language"] isKindOfClass:NSClassFromString(@"SPDFMacSearchablePicker")],"searchable language picker reused");
    NSButton* send=[panel valueForKey:@"send"];NSButton* save=[panel valueForKey:@"save"];
    Check(send.enabled && !save.enabled,"send available only after extraction; no empty copy save");
    Check(NSContainsRect(panel.window.contentView.bounds,send.frame),"send button inside native panel content");
    Check(!panel.window.visible,"UI probe never shows a window");
    __block BOOL done=NO;__block NSString* result=nil;__block NSError* failure=nil;__block NSUInteger total=0;
    [service translateText:content language:@"fr" model:@"test/model" key:@"test-not-a-real-key" progress:^(NSUInteger n,NSUInteger count){(void)n;total=count;} completion:^(NSString* value,NSError* err){result=value;failure=err;done=YES;}];
    Check(Wait(^BOOL{return done;}),"chunk translation completes");Check(!failure && result.length && requests==(int)chunks.count && total==chunks.count,"all chunks translated in order");
    mode=1;done=NO;[service translateText:@"hello" language:@"fr" model:@"test/model" key:@"test-not-a-real-key" progress:nil completion:^(NSString* value,NSError* err){result=value;failure=err;done=YES;}];
    Check(Wait(^BOOL{return done;}) && failure && !result,"provider failure exposes no partial success");
    mode=3;done=NO;[service translateText:@"hello" language:@"fr" model:@"test/model" key:@"test-not-a-real-key" progress:nil completion:^(NSString* value,NSError* err){result=value;failure=err;done=YES;}];
    Check(Wait(^BOOL{return done;}) && failure && ![failure.localizedDescription containsString:@"chat"],"translation errors never claim a chat was saved");
    mode=2;done=NO;int before=requests;
    [service translateText:content language:@"fr" model:@"test/model" key:@"test-not-a-real-key" progress:nil completion:^(NSString* value,NSError* err){(void)value;(void)err;done=YES;}];
    Check(Wait(^BOOL{return requests>before;}),"cancellation fixture began request");[service cancel];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.15]];
    Check(!done && requests==before+1,"cancel stops chunk chain and suppresses stale completion");
    NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* original=[directory stringByAppendingPathComponent:@"original.md"];
    [@"original" writeToFile:original atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString* alias=[directory stringByAppendingPathComponent:@"alias.md"];
    [NSFileManager.defaultManager linkItemAtPath:original toPath:alias error:nil];
    Check(!SPDFMacAITranslationCanSaveToURL([NSURL fileURLWithPath:original],original),"save cannot overwrite source");
    Check(!SPDFMacAITranslationCanSaveToURL([NSURL fileURLWithPath:alias],original),"save cannot overwrite source through hard link");
    Check(SPDFMacAITranslationCanSaveToURL([NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"translated.md"]],original),"new translated copy allowed");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    panel.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSBitmapImageRep* bitmap=SPDFReadmeWindowBitmap(panel.window);
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/spdf-ai-translation-panel.png" atomically:YES];
    __block NSUInteger closed=0;preparing.onClosed=^{++closed;};
    [preparing windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:preparing.window]];[preparing windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:preparing.window]];
    Check(closed==1 && ![[preparing valueForKey:@"source"] string].length && !preparing.onClosed,"close clears source storage and calls teardown once");
    __weak SPDFMacAITranslationPanel* releasedPanel=nil;
    @autoreleasepool {
        NSMutableArray* holders=[NSMutableArray array];
        SPDFMacAITranslationPanel* temporary=[[SPDFMacAITranslationPanel alloc] initWithSourceName:@"/tmp/closed.pdf" language:@"en"];
        releasedPanel=temporary;[holders addObject:temporary];
        __weak NSMutableArray* weakHolders=holders;__weak SPDFMacAITranslationPanel* weakTemporary=temporary;
        temporary.onClosed=^{SPDFMacAITranslationPanel* value=weakTemporary;if(value)[weakHolders removeObject:value];};
        [temporary windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:temporary.window]];Check(!holders.count,"closed panel immediately leaves owner collection");
    }
    Check(!releasedPanel,"closed panel has no owner/callback retain cycle");
    NSLog(@"AI translation tests: %d failures",failures);return failures ? 1:0;
}}
