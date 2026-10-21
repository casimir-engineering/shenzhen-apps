// Tool-call arguments as providers really send them. The shape is a real chat's: a document assistant asked for "a
// nice document" of a connector footprint sent a 6.6 KB run_python call of matplotlib code (names here are neutral),
// and the request ended on "The model returned malformed action JSON." Its failing reply was not kept anywhere, so
// these are the ways a vLLM-served model is known to write such a call: raw line breaks and \' inside the string,
// a fence or a stray token around the object, or the object cut off while finish_reason still said "tool_calls".
// Written so that it also compiles against the code before the fix (no SPDFMacAIToolArguments.h): there, the session
// checks fail.
#if __has_include("SPDFMacAIToolArguments.h")
#import "SPDFMacAIToolArguments.h"
#define SPDF_HAS_TOOL_ARGUMENTS 1
#endif
@protocol SPDFRetryProbe
@property(nonatomic, readonly) BOOL canRetry;
@property(nonatomic, readonly) NSUInteger retryMessageIndex;
@property(nonatomic, readonly) NSDictionary* lastUnreadableCall;
@end
static BOOL CanRetry(id session) { return [session respondsToSelector:@selector(canRetry)] && [session canRetry]; }
static NSString* FootprintCode(void) {
    NSMutableString* code=[NSMutableString stringWithString:@"\nimport matplotlib\nmatplotlib.use(\"Agg\")\n"
        "import matplotlib.pyplot as plt\nfrom matplotlib.patches import FancyBboxPatch, Rectangle\n\npins = {\n"];
    for (int pin=1;pin<=34;pin++)
        [code appendFormat:@"%d:('SIG_%c%d','%@'),%@",pin,'A'+pin%4,pin,pin%3 ? @"sig" : @"gnd",pin%4 ? @"" : @"\n"];
    [code appendString:@"\n}\ncol = dict(gnd=('#8d949b','#e9ecef'), sig=('#1f4e9c','#dbe6f5'),\n"
        "           nc=('#adb5bd','#f2f3f5'))\n"
        "fig = plt.figure(figsize=(16.54, 11.69))\n"
        "ax = fig.add_axes([0,0,1,1]); ax.set_xlim(0,330); ax.set_ylim(0,233); ax.axis('off')\n"
        "def pad(x,y,w,h,c,edge='#333',lw=1.6,z=3):\n"
        "\tax.add_patch(Rectangle((x-w/2,y-h/2),w,h,facecolor=c,edgecolor=edge,lw=lw,zorder=z))\n"
        "# 📐 header\n"
        "ax.text(13,219.5,\"CONNECTOR \u00b7 FOOTPRINT & PIN ASSIGNMENT\",color='white',fontsize=17.5,va='center')\n"
        "ax.text(13,211.8,'Pin 1\\'s pad is marked\\nRow A above Row B',color='#c7d0d9',fontsize=9.6)\n"
        "nseg, x0, x1 = 15, 58, 300\ndx = (x1-x0)/(nseg-1)\nyt, yb = 133.0, 112.0\nph, pw = 12.0, 7.0\n"];
    for (int row=0;row<16;row++)
        [code appendFormat:@"for i in range(15):\n    n = %d+i; x = x0+dx*i\n"
            "    pad(x, yt-%d, pw, ph, col[pins.get(n, ('NC','nc'))[1]][1])\n"
            "    ax.text(x, yt+9-%d, str(n), ha='center', va='bottom', fontsize=7, color='#3d4652')\n"
            "    ax.text(x, yt-9-%d, pins.get(n, ('NC','nc'))[0], ha='center', va='top', fontsize=5.5, rotation=90)\n",
            1+row,row*3,row*3,row*3];
    [code appendString:@"fig.savefig('footprint.png', dpi=150)\nprint('saved')\n"];
    return code;
}
// The arguments as a careless writer of JSON puts them: line breaks and tabs left raw, every ' written as \'.
static NSString* LooseArguments(NSString* code) {
    NSMutableString* out=[NSMutableString stringWithString:@"{\"code\": \""];
    for (NSUInteger i=0;i<code.length;i++) {
        unichar c=[code characterAtIndex:i];
        if (c=='\\') [out appendString:@"\\\\"]; else if (c=='"') [out appendString:@"\\\""];
        else if (c=='\'') [out appendString:@"\\'"];
        else [out appendString:[NSString stringWithCharacters:&c length:1]];
    }
    [out appendString:@"\"}"]; return out;
}
static NSDictionary* CallTurn(NSArray* calls) {
    NSMutableArray* wire=[NSMutableArray array];
    for (NSArray* call in calls)
        [wire addObject:@{@"id":call[0],@"type":@"function",@"function":@{@"name":call[1],@"arguments":call[2]}}];
    return @{@"role":@"assistant",@"content":@"",@"tool_calls":wire};
}
// A tool's result, once: before the fix a call that never ran left no completion to call.
static void Answer(FakeTools* tools,NSDictionary* result) {
    void (^reply)(NSDictionary*)=tools.reply; tools.reply=nil; if (reply) reply(result);
}
static NSString* ChatFile(SPDFMacAIChatStore* store,SPDFMacAIChatSession* session) {
    NSDictionary* chat=[store chatWithID:session.chat[@"id"]];
    NSData* data=chat ? [NSJSONSerialization dataWithJSONObject:chat options:0 error:nil] : nil;
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}
static void CheckToolArgumentParsing(void) {
#if SPDF_HAS_TOOL_ARGUMENTS
    NSString* code=FootprintCode(); NSString* loose=LooseArguments(code);
    SPDFMacAIToolArgumentsProblem problem; BOOL repaired=NO;
    CHECK(loose.length>5000 && ![NSJSONSerialization JSONObjectWithData:[loose dataUsingEncoding:NSUTF8StringEncoding]
        options:0 error:nil],"the fixture is a long run_python call strict JSON refuses");
    NSDictionary* read=SPDFMacAIToolCallArguments(loose,&problem,&repaired);
    CHECK([read[@"code"] isEqual:code] && repaired && problem==SPDFMacAIToolArgumentsReadable,
        "raw line breaks, tabs and \\' in code are read as the code the model wrote");
    CHECK([SPDFMacAIToolCallArguments(SPDFMacAIToolArgumentsJSON(read),&problem,&repaired) isEqual:read] && !repaired,
        "the repaired arguments are kept as strict JSON");
    CHECK([SPDFMacAIToolCallArguments(@"{\"page\":2}",&problem,&repaired)[@"page"] isEqual:@2] && !repaired,
        "strict JSON is read as it is");
    NSString* fenced=[NSString stringWithFormat:@"```json\n%@\n```",loose];
    CHECK([SPDFMacAIToolCallArguments(fenced,&problem,nil)[@"code"] isEqual:code],"a ```json fence is dropped");
    CHECK([SPDFMacAIToolCallArguments([loose stringByAppendingString:@"\n</tool_call>"],&problem,nil)[@"code"]
        isEqual:code],"a stray token after the object is dropped");
    CHECK(!SPDFMacAIToolCallArguments(@"{\"page\":1}{\"page\":2}",&problem,nil) &&
        problem==SPDFMacAIToolArgumentsInvalid,"two objects run together are not guessed between");
    CHECK(!SPDFMacAIToolCallArguments(@"{\"page\":1},[2]",&problem,nil),"nor an object followed by a list");
    NSString* cut=[loose substringToIndex:loose.length*4/5];
    CHECK(!SPDFMacAIToolCallArguments(cut,&problem,nil) && problem==SPDFMacAIToolArgumentsTruncated,
        "arguments cut off inside the code are truncated, never completed");
    for (NSString* end in @[@"{\"code\":\"x\\",@"{\"code\":\"\\u00",@"{\"a\":{\"b\":1}",@"{\"a\":[1,2"])
        CHECK(!SPDFMacAIToolCallArguments(end,&problem,nil) && problem==SPDFMacAIToolArgumentsTruncated,
            "an object that stops before its end is truncated");
    for (NSString* bad in @[@"not JSON",@"[1,2]",@"{\"a\":[1}",@"{'a':1}",@"{\"a\":\"say \"hi\"\"}",
                            @"{\"a\":\"\\uZZZZ\"}"])
        CHECK(!SPDFMacAIToolCallArguments(bad,&problem,nil) && problem==SPDFMacAIToolArgumentsInvalid,
            "what is not one object, even repaired, is invalid");
    CHECK(!SPDFMacAIToolCallArguments([@"{\"code\":\"" stringByPaddingToLength:70000 withString:@"x" startingAtIndex:0],
        &problem,nil) && problem==SPDFMacAIToolArgumentsTooLong,"arguments over 64 KB are not read");
    CHECK([SPDFMacAIToolCallArguments(@{@"page":@3},&problem,&repaired)[@"page"] isEqual:@3] && repaired,
        "an object sent in place of the string is taken as it is");
    CHECK([SPDFMacAIToolCallArguments(@"{\"t\":\"a\\\n📐\"}",&problem,nil)[@"t"] isEqual:@"a\n📐"],
        "a backslash before a raw break is the break; characters outside the BMP survive");
#endif
}
static void CheckToolArgumentRecovery(NSURL* root) {
    CheckToolArgumentParsing();
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools
        definitions:@[] store:store];
    NSString* code=FootprintCode(); NSString* loose=LooseArguments(code);
    NSString* cut=[loose substringToIndex:loose.length*4/5];
    // Repaired arguments run, and the call is kept as strict JSON for the turns that follow.
    [session send:@"Make a nice document of the connector footprint" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-1",@"run_python",loose]]),nil);
    CHECK(tools.calls==1 && [tools.lastName isEqual:@"run_python"] && [tools.lastArguments[@"code"] isEqual:code],
        "a run_python call with raw line breaks and \\' runs the code as written");
    NSArray* turns=session.chat[@"messages"];
    NSString* kept=turns.count>1 ? [turns[1][@"tool_calls"] firstObject][@"function"][@"arguments"] : nil;
    CHECK(kept && [NSJSONSerialization JSONObjectWithData:[kept dataUsingEncoding:NSUTF8StringEncoding] options:0
        error:nil]!=nil,
        "the call sent back in later turns is strict JSON");
    Answer(tools,@{@"stdout":@"saved"});
    transport.reply(@{@"role":@"assistant",@"content":@"Here is the footprint sheet."},nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityCompleted,"the request completes");
    // Fenced and trailing-token arguments run too.
    for (NSString* wrapped in @[[NSString stringWithFormat:@"```json\n%@\n```",loose],
                                [loose stringByAppendingString:@"<|tool_call_end|>"]]) {
        [session newChat]; NSUInteger before=tools.calls;
        [session send:@"Draw it again" model:@"fake/model" apiKey:@"fixture"];
        transport.reply(CallTurn(@[@[@"chatcmpl-tool-2",@"run_python",wrapped]]),nil);
        CHECK(tools.calls==before+1 && [tools.lastArguments[@"code"] isEqual:code],
            "fenced arguments and a trailing token still run");
        [session cancel];
    }
    // Cut off mid-string while finish_reason said "tool_calls": the model is asked again, then succeeds.
    [session newChat]; NSUInteger before=tools.calls;
    [session send:@"Make a nice document of the connector footprint" model:@"fake/model" apiKey:@"fixture"];
    NSUInteger sends=transport.sends;
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-3",@"run_python",cut]]),nil);
    NSDictionary* asked=transport.messages.lastObject;
    CHECK(tools.calls==before && transport.sends==sends+1 && session.running,
        "a cut-off call runs nothing and the model is asked again within the request");
    CHECK([asked[@"role"] isEqual:@"tool"] && [asked[@"content"] containsString:@"run_python"] &&
        [asked[@"content"] containsString:@"cut off"] && [asked[@"content"] containsString:@"shorter code"],
        "the model is told which call was cut off and how to send it");
    NSDictionary* stub=transport.messages[transport.messages.count-2];
    CHECK([[stub[@"tool_calls"] firstObject][@"function"][@"arguments"] isEqual:@"{}"],
        "the cut-off call goes back with empty arguments, so the request stays valid");
    CHECK(![ChatFile(store,session) containsString:@"matplotlib"],"the cut-off code is not saved with the chat");
    if ([session respondsToSelector:@selector(lastUnreadableCall)]) {
        NSDictionary* last=[(id<SPDFRetryProbe>)session lastUnreadableCall];
        CHECK([last[@"name"] isEqual:@"run_python"] && [last[@"arguments"] length]==4096 &&
            [cut hasPrefix:last[@"arguments"]] && [last[@"length"] unsignedIntegerValue]==cut.length,
            "the first 4 KB of what the provider sent are kept in memory to diagnose it");
    }
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-4",@"run_python",loose]]),nil);
    CHECK(tools.calls==before+1 && [tools.lastArguments[@"code"] isEqual:code],"the call sent again runs");
    Answer(tools,@{@"stdout":@"saved"});
    transport.reply(@{@"role":@"assistant",@"content":@"Done."},nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityCompleted && !session.status.length,
        "the request then completes as if nothing had happened");
    // Cut off twice: the person reads what happened and gets Retry, never the mechanism.
    [session newChat]; before=tools.calls;
    [session send:@"Make a nice document of the connector footprint" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-5",@"run_python",cut]]),nil);
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-6",@"run_python",cut]]),nil);
    CHECK(tools.calls==before && !session.running && session.activityState==SPDFMacAIChatActivityError,
        "a second cut-off call ends the request without running anything");
    CHECK([session.status isEqual:@"The assistant's answer got cut off. Try again."] &&
        [session.status rangeOfString:@"JSON" options:NSCaseInsensitiveSearch].location==NSNotFound &&
        [session.status rangeOfString:@"action" options:NSCaseInsensitiveSearch].location==NSNotFound,
        "the person reads that the answer got cut off");
    CHECK(CanRetry(session) && [(id<SPDFRetryProbe>)session retryMessageIndex]==0,"Retry is offered for the question");
    sends=transport.sends;
    [session resendFromMessageAtIndex:0 text:session.chat[@"messages"][0][@"content"] model:@"fake/model" apiKey:@"f"];
    CHECK(transport.sends==sends+1 && session.running && [session.chat[@"messages"] count]==1 && !CanRetry(session),
        "Retry sends the question again in place of the unfinished answer");
    [session cancel];
    // A batch with one unreadable call: nothing in it runs before the model sends it again.
    [session newChat]; before=tools.calls;
    [session send:@"Read page 2 and draw it" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-7",@"read_pages",@"{\"pages\":[2]}"],
        @[@"chatcmpl-tool-8",@"run_python",cut]]),nil);
    NSUInteger count=transport.messages.count;
    CHECK(tools.calls==before && session.running && count>=2 &&
        [transport.messages[count-2][@"content"] containsString:@"Not run"] &&
        [transport.messages[count-1][@"content"] containsString:@"cut off"],
        "no call of a batch with an unreadable one runs; each is answered");
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-9",@"read_pages",@"{\"pages\":[2]}"]]),nil);
    CHECK(tools.calls==before+1 && [tools.lastName isEqual:@"read_pages"],"the batch sent again runs");
    [session cancel];
    // After a change to a document, sending the question again would repeat it: a follow-up is asked for instead.
    [session newChat];
    [session send:@"Rename the chapter, then draw it" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-10",@"update_document_metadata",@"{}"]]),nil);
    Answer(tools,@{@"changed":@YES});
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-11",@"run_python",cut]]),nil);
    transport.reply(CallTurn(@[@[@"chatcmpl-tool-12",@"run_python",cut]]),nil);
    CHECK(!session.running && !CanRetry(session) && [session.status containsString:@"got cut off"] &&
        [session.status containsString:@"send a follow-up"],"after a change, a follow-up is asked for, not Retry");
}
