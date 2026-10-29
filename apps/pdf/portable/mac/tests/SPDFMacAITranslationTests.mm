#import "../SPDFMacAITranslation.h"
#import "../SPDFMacAITransport.h"
#import "../SPDFMacAIJobTranslator.h"
#import "../SPDFMacAIOutputFiles.h"
#import "../SPDFMacTranslateLanguagePopover.h"
@interface SPDFMacTranslateLanguagePopover (Tests)
- (instancetype)initWithTranslate:(void (^)(NSString*))translate;
- (void)controlTextDidChange:(NSNotification*)note;
@end
static int failures=0,requests=0,mode=0;
static void Check(BOOL condition,const char* name){if(!condition){fprintf(stderr,"FAIL %s\n",name);++failures;}}
// The model, answering on the loopback the way the job's requests reach it: a JSON array back for lines (mode 0, one
// too few in mode 4), Markdown for text, an error (1), nothing (2: never answers) or an empty answer (3).
@interface TranslationProtocol : NSURLProtocol @end
@implementation TranslationProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest*)request {(void)request;return YES;}
+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request{return request;}
- (void)startLoading {
    ++requests;if(mode==2)return;
    NSData* body=self.request.HTTPBody;
    if(!body && self.request.HTTPBodyStream) {
        NSMutableData* read=[NSMutableData data];uint8_t buffer[4096];NSInputStream* stream=self.request.HTTPBodyStream;[stream open];
        for(NSInteger n;(n=[stream read:buffer maxLength:sizeof(buffer)])>0;)[read appendBytes:buffer length:(NSUInteger)n];
        [stream close];body=read;
    }
    NSArray* messages=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil][@"messages"];
    NSString* content=@"# Bonjour\nTraduction.";
    if([messages.firstObject[@"content"] containsString:@"JSON array"]) {
        NSMutableArray* lines=[NSMutableArray array];
        for(NSString* line in [NSJSONSerialization JSONObjectWithData:[messages.lastObject[@"content"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil])
            [lines addObject:[@"FR " stringByAppendingString:line]];
        if(mode==4)[lines removeLastObject];
        content=[@"```json\n" stringByAppendingString:[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:lines options:0 error:nil] encoding:NSUTF8StringEncoding]];
    }
    NSDictionary* reply=@{@"choices":@[@{@"message":@{@"role":@"assistant",@"content":mode==3 ? NSNull.null : content},@"finish_reason":@"stop"}]};
    [self.client URLProtocol:self didReceiveResponse:[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:mode==1 ? 401 : 200 HTTPVersion:@"HTTP/1.1" headerFields:nil] cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
// The translator waits on a worker thread for answers the transport delivers on the main thread, as in the app.
static id OnWorker(id (^work)(void)) {
    __block id result=nil;__block BOOL done=NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{result=work();done=YES;});
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!done && end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return result;
}
static void Type(SPDFMacTranslateLanguagePopover* picker,NSString* text) {
    picker.field.stringValue=text;[picker controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:picker.field]];
}
int main(){@autoreleasepool {
    [NSApplication sharedApplication];NSError* error=nil;
    Check(!SPDFMacAITranslationChunks(@"",&error) && error!=nil,"empty documents rejected before any request");
    Check(!SPDFMacAITranslationChunks(@"   \n",&error) && ![error.localizedDescription containsString:@"500,000"],"whitespace input has the no-text error");
    NSString* longText=[@"a" stringByPaddingToLength:500001 withString:@"a" startingAtIndex:0];
    Check(!SPDFMacAITranslationChunks(longText,&error),"oversize documents rejected explicitly, never truncated");
    NSString* content=[@"\n👨‍👩‍👧‍👦" stringByPaddingToLength:8000 withString:@"Bonjour\n" startingAtIndex:0];
    NSArray* chunks=SPDFMacAITranslationChunks(content,&error);
    Check([[chunks componentsJoinedByString:@""] isEqual:content] && chunks.count>1,"chunking preserves all Unicode source content");

    // Language names: a code or a listed name is the English name; anything else a language could be called stays.
    Check([SPDFMacAITranslationLanguageName(@"fr") isEqual:@"French"] && [SPDFMacAITranslationLanguageName(@"french") isEqual:@"French"],"codes and names give the English name");
    Check([SPDFMacAITranslationLanguageName(@" Breton ") isEqual:@"Breton"] && !SPDFMacAITranslationLanguageName(@"x/../y") && !SPDFMacAITranslationLanguageName(@""),"a typed language is kept, a path is not");
    Check([SPDFMacAIJobOutputName(@"/x/Datasheet.pdf",@"translate",@"fr") isEqual:@"Datasheet (French).pdf"] &&
          [SPDFMacAIJobOutputName(@"/x/Datasheet.pdf",@"translate",@"Breton") isEqual:@"Datasheet (Breton).pdf"] &&
          [SPDFMacAIJobOutputName(@"/x/Notes.md",@"translate",@"zh-Hans") isEqual:@"Notes (Simplified Chinese).pdf"],"outputs are named \"<name> (<Language>)\"");

    // The job's translator: lines come back one for one, text part by part; failures and Stop give nothing.
    NSURLSessionConfiguration* configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.protocolClasses=@[TranslationProtocol.class];
    SPDFMacAIJobTranslator* translator=[[SPDFMacAIJobTranslator alloc] initWithTransport:[[SPDFMacAITransport alloc] initWithConfiguration:configuration] model:@"test/model" key:@"test-not-a-real-key" language:@"French"];
    Check(requests==0,"the translator is inert until asked");
    NSArray* lines=OnWorker(^id{return [translator translateLines:@[@"Hello",@"world"] progress:[NSProgress progressWithTotalUnitCount:2] error:nil];});
    Check([lines isEqual:(@[@"FR Hello",@"FR world"])],"lines come back translated, one for one, in order");
    mode=4;requests=0;__block NSError* failure=nil;
    lines=OnWorker(^id{NSError* e=nil;id r=[translator translateLines:@[@"a",@"b"] progress:[NSProgress progressWithTotalUnitCount:2] error:&e];failure=e;return r;});
    Check(!lines && failure && requests==2,"a reply with a line missing is asked once more, then refused");
    mode=0;requests=0;NSProgress* progress=[NSProgress progressWithTotalUnitCount:1];
    NSString* text=OnWorker(^id{return [translator translateText:content progress:progress error:nil];});
    Check(text.length && requests==(int)chunks.count && progress.completedUnitCount==(int64_t)chunks.count,"a text document is translated part by part");
    mode=1;text=OnWorker(^id{NSError* e=nil;id r=[translator translateText:@"hello" progress:[NSProgress progressWithTotalUnitCount:1] error:&e];failure=e;return r;});
    Check(!text && failure,"a provider failure gives no partial document");
    mode=3;text=OnWorker(^id{NSError* e=nil;id r=[translator translateText:@"hello" progress:[NSProgress progressWithTotalUnitCount:1] error:&e];failure=e;return r;});
    Check(!text && failure,"an empty answer gives no document");
    mode=2;progress=[NSProgress progressWithTotalUnitCount:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[progress cancel];});
    text=OnWorker(^id{return [translator translateText:@"hello" progress:progress error:nil];});
    Check(!text && progress.cancelled,"Stop ends a request the model never answers");

    // The language picker, from the keyboard only.
    __block NSString* chosen=nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SPDFTranslateRecentLanguages"];
    SPDFMacTranslateLanguagePopover* picker=[[SPDFMacTranslateLanguagePopover alloc] initWithTranslate:^(NSString* l){chosen=l;}];
    [picker pressReturn];
    Check([chosen isEqual:@"English"],"Return straight away translates into English");
    chosen=nil;picker=[[SPDFMacTranslateLanguagePopover alloc] initWithTranslate:^(NSString* l){chosen=l;}];
    Type(picker,@"fr");[picker pressReturn];
    Check(!chosen && [picker.field.stringValue isEqual:@"French"],"typing narrows to French and Return chooses it");
    [picker pressReturn];
    Check([chosen isEqual:@"French"],"a second Return translates into French");
    chosen=nil;picker=[[SPDFMacTranslateLanguagePopover alloc] initWithTranslate:^(NSString* l){chosen=l;}];
    Type(picker,@"Breton");[picker pressReturn];[picker pressReturn];
    Check([chosen isEqual:@"Breton"],"a language not in the list is used as typed");
    Check([SPDFMacTranslateRecentLanguages() isEqual:(@[@"Breton",@"French",@"English"])],"chosen languages are remembered, latest first");
    chosen=nil;picker=[[SPDFMacTranslateLanguagePopover alloc] initWithTranslate:^(NSString* l){chosen=l;}];
    [picker moveSelection:-1];[picker moveSelection:1];[picker moveSelection:1];[picker pressReturn];
    Check(chosen.length && ![chosen isEqual:@"English"],"arrows move through the list");
    chosen=nil;picker=[[SPDFMacTranslateLanguagePopover alloc] initWithTranslate:^(NSString* l){chosen=l;}];
    Type(picker,@"ger");[picker pressReturn];[picker close];
    Check(!chosen,"closing translates nothing");
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SPDFTranslateRecentLanguages"];
    NSLog(@"AI translation tests: %d failures",failures);return failures ? 1:0;
}}
