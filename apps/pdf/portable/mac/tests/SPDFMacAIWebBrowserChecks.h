// open_page fetching as a browser on this Mac would, against the loopback server (SPDFMacAIWebServer.h): the headers
// it sends, a bot filter it now passes, redirect chains, compressed bodies and their limits, PDFs whatever their
// declared type, read in page ranges with table rows kept, pages built by scripts, sign-in walls, and what the chat
// and the model are told when a site still refuses.
#pragma once
#import "SPDFMacAIWebServer.h"
#import "SPDFMacAIWebDecoding.h"
#import "SPDFMacAIWebFetchChecks.h"
#import "SPDFMacAIWebHTTP.h"
#import "SPDFMacAIWebPDF.h"
#import "SPDFMacAIWebProviderChecks.h"
#import "SPDFMacAIWebToolResults.h"

static NSString* const kWebOldAgent = @"Mozilla/5.0 (compatible; ShenzhenPDF)";

static NSData* WebSiteHTML(NSString* html) { return [html dataUsingEncoding:NSUTF8StringEncoding]; }

// The imitated sites. Like hirose.com's CloudFront, every path answers 403 unless the request looks like Safari.
static NSData* WebSiteRoute(WebServedRequest* request) {
    NSString* agent = request.headers[@"user-agent"] ?: @"";
    if (![agent containsString:@"Safari/605.1.15"] || ![agent containsString:@"Version/26.0"])
        return WebResponse(403, @{@"X-Cache" : @"Error from cloudfront", @"Content-Length" : @"0"}, nil);
    NSString* path = request.path;
    NSString* page = @"<title>BM28</title><h1>BM28 Series</h1><table><tr><td>Contact Pitch</td><td>0.35 mm</td></tr>"
        "</table><a href=\"/BM28B0-6-30DS-2-0-35V-51-643875.pdf\">BM28 catalog (PDF)</a>";
    if ([path isEqual:@"/en/product/series/BM28"])
        return WebEncoded(@"text/html; charset=utf-8", @"gzip", WebGzip(WebSiteHTML(page), YES));
    if ([path isEqual:@"/br"]) return WebEncoded(@"text/html", @"br", WebBrotli(WebSiteHTML(@"<p>Brotli body</p>")));
    if ([path isEqual:@"/deflate"])
        return WebEncoded(@"text/html", @"deflate", WebGzip(WebSiteHTML(@"<p>Deflate body</p>"), NO));
    if ([path isEqual:@"/bomb"]) {
        // 24 MB of text in a few tens of kilobytes: the decoder must stop at the limit, not at the end.
        NSMutableData* huge = [NSMutableData dataWithLength:24 * 1024 * 1024];
        memset(huge.mutableBytes, 'a', huge.length);
        return WebEncoded(@"text/plain", @"gzip", WebGzip(huge, YES));
    }
    if ([path hasPrefix:@"/hop/"] || [path hasPrefix:@"/loop/"]) {
        NSInteger step = [path.lastPathComponent integerValue];
        if ([path hasPrefix:@"/hop/"] && step == 5) return WebHTML(@"<p>landed after five redirects</p>");
        NSArray* codes = @[@301, @302, @303, @307, @308];
        NSString* next = [NSString stringWithFormat:@"%@%ld", [path substringToIndex:path.length -
            path.lastPathComponent.length], (long)step + 1];
        return WebRedirect([codes[step % 5] integerValue], next);
    }
    NSData* pdf = WebDatasheetPDF();
    NSString* length = [NSString stringWithFormat:@"%lu", (unsigned long)pdf.length];
    if ([path isEqual:@"/BM28B0-6-30DS-2-0-35V-51-643875.pdf"])
        return WebResponse(200, @{@"Content-Type" : @"application/octet-stream", @"Content-Length" : length}, pdf);
    if ([path isEqual:@"/download?id=7"]) // a PDF served as text: its bytes say what it is
        return WebResponse(200, @{@"Content-Type" : @"text/plain", @"Content-Length" : length}, pdf);
    if ([path isEqual:@"/app"])
        return WebHTML(@"<!doctype html><html><head><title>Product</title><script src=\"/app.js\"></script>"
                       "<script>window.boot()</script></head><body><div id=\"root\"></div><noscript>Enable "
                       "JavaScript</noscript><a href=\"/files/BM28-datasheet.pdf\">Download</a>"
                       "<a href=\"/about\">About</a></body></html>");
    if ([path isEqual:@"/account"]) return WebResponse(401, @{@"Content-Length" : @"0"}, nil);
    if ([path isEqual:@"/signin"])
        return WebHTML(@"<title>Sign in</title><form><input name=\"user\"><input type=\"password\" name=\"pw\">"
                       "<button>Sign in</button></form>");
    return WebResponse(404, @{@"Content-Length" : @"0"}, nil);
}

static void CheckBrowserFetch(void) {
    WebHTTPServer* server = [WebHTTPServer new];
    server.route = ^NSData*(WebServedRequest* request) { return WebSiteRoute(request); };
    CHECK([server start], "the loopback server starts");
    WebLoopbackConnector* connector = [WebLoopbackConnector new];
    connector.port = server.port;
    WebFakeResolver* resolver = [WebFakeResolver new];
    [resolver answer:@"www.hirose.com" with:@[@"3.173.254.7"]];
    [resolver answer:@"datasheet.example.com" with:@[@"104.21.8.225"]];
    SPDFMacAIWebFetcher* fetcher = WebTestFetcher(resolver, connector);
    fetcher.acceptLanguage = SPDFMacAIWebAcceptLanguage(@[@"en-GB", @"zh-Hans-CN"]);

    // The imitation is faithful: the user agent open_page used to send is turned away, as hirose.com turned it away.
    __block SPDFMacAIWebResponseParser* refused = [[SPDFMacAIWebResponseParser alloc] initWithBodyLimit:1000];
    __block BOOL over = NO;
    NSString* old = [NSString stringWithFormat:@"GET /en/product/series/BM28 HTTP/1.1\r\nHost: www.hirose.com\r\n"
                     "User-Agent: %@\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n", kWebOldAgent];
    [connector exchangeRequest:[old dataUsingEncoding:NSASCIIStringEncoding] address:@"3.173.254.7" port:443
                    serverName:@"www.hirose.com" queue:dispatch_get_main_queue()
                       receive:^BOOL(NSData* bytes) { return [refused appendData:bytes]; }
                      finished:^(NSError* error) { (void)error; [refused finishAtEndOfStream]; over = YES; }];
    CHECK(WebWait(^BOOL { return over; }, 5) && refused.status == 403, "the old user agent gets 403 from the site");

    WebFetchResult* result = WebFetch(fetcher, @"https://www.hirose.com/en/product/series/BM28");
    WebServedRequest* sent = server.requests.lastObject;
    CHECK([result.page.readable.text containsString:@"Contact Pitch | 0.35 mm"] &&
          [result.page.readable.title isEqual:@"BM28"], "the same page opens for open_page, its gzip body decoded");
    CHECK([sent.headers[@"user-agent"] isEqual:SPDFMacAIWebUserAgent] &&
          [sent.headers[@"accept"] hasPrefix:@"text/html,application/xhtml+xml"] &&
          [sent.headers[@"accept-language"] isEqual:@"en-GB,en;q=0.9,zh-CN;q=0.8,zh;q=0.7"] &&
          [sent.headers[@"accept-encoding"] isEqual:@"gzip, deflate, br"] &&
          [sent.headers[@"host"] isEqual:@"www.hirose.com"] && !sent.headers[@"cookie"] && !sent.headers[@"referer"] &&
          !sent.headers[@"authorization"], "the server saw Safari's headers and the person's languages, no cookies, "
          "referrer or credentials");
    CHECK([connector.connections.lastObject.address isEqual:@"3.173.254.7"] &&
          [connector.connections.lastObject.serverName isEqual:@"www.hirose.com"],
          "the connection went to the checked address, the name kept for the certificate");

    result = WebFetch(fetcher, @"https://www.hirose.com/br");
    CHECK([result.page.readable.text isEqual:@"Brotli body"], "a br body is decoded");
    result = WebFetch(fetcher, @"https://www.hirose.com/deflate");
    CHECK([result.page.readable.text isEqual:@"Deflate body"], "a deflate body is decoded");
    result = WebFetch(fetcher, @"https://www.hirose.com/bomb");
    NSUInteger kept = [result.page.readable.text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    CHECK(result.page.truncated && kept <= 200 * 1024 && kept > 100 * 1024,
          "24 MB of gzip text stops at the decoded limit and is marked cut, never inflated whole");

    NSUInteger before = connector.connections.count;
    result = WebFetch(fetcher, @"https://www.hirose.com/hop/0");
    CHECK([result.page.readable.text isEqual:@"landed after five redirects"] && result.page.redirects == 5 &&
          connector.connections.count - before == 6, "301, 302, 303, 307 and 308 in a row are followed");
    result = WebFetch(fetcher, @"https://www.hirose.com/loop/0");
    CHECK(result.error.code == SPDFMacAIWebErrorTooManyRedirects, "a sixth redirect is not");

    result = WebFetch(fetcher, @"https://datasheet.example.com/BM28B0-6-30DS-2-0-35V-51-643875.pdf");
    SPDFMacAIWebDocument* document = result.page.document;
    CHECK(document.pageCount == 3 && [document.title isEqual:@"BM28 Test Datasheet"] &&
          [document.fileURL.lastPathComponent isEqual:@"BM28B0-6-30DS-2-0-35V-51-643875.pdf"] &&
          [document.fileURL.path hasPrefix:WebDocumentFolder().path] &&
          [[NSData dataWithContentsOfURL:document.fileURL] isEqual:WebDatasheetPDF()],
          "a PDF served as application/octet-stream is saved whole in the download folder, named like its address");
    result = WebFetch(fetcher, @"https://datasheet.example.com/download?id=7");
    CHECK(result.page.document.pageCount == 3 && ![result.page.document.identifier isEqual:document.identifier],
          "a PDF served as text/plain is known by its bytes");

    result = WebFetch(fetcher, @"https://www.hirose.com/app");
    CHECK(SPDFMacAIWebPageIsScripted(result.page) &&
          [[SPDFMacAIWebDocumentLinks(result.page) valueForKey:@"url"]
              isEqual:@[@"https://www.hirose.com/files/BM28-datasheet.pdf"]],
          "a page built by scripts is recognised, and its PDF link found");
    NSDictionary* told = SPDFMacAIWebPageToolResult(result.page, 0);
    CHECK([told[@"note"] containsString:@"shows its content with scripts"] && [told[@"document_links"] count] == 1,
          "the model is told plainly and given the PDF link to open");
    CHECK([SPDFMacAIWebPageStepStatus(result.page) isEqual:@"This page had almost nothing the assistant could read. "
           "It links to a PDF the assistant can open instead."], "and the chat says it too, with what comes next");

    CHECK(WebFetch(fetcher, @"https://www.hirose.com/account").error.code == SPDFMacAIWebErrorSignInRequired &&
          WebFetch(fetcher, @"https://www.hirose.com/signin").error.code == SPDFMacAIWebErrorSignInRequired,
          "a 401 and a page that is only a sign-in form are reported as sign-in walls");
    [server stop];
}

static void CheckDocumentPages(void) {
    NSError* error = nil;
    SPDFMacAIWebDocument* document = SPDFMacAIWebStoreDocument(WebDatasheetPDF(),
        [NSURL URLWithString:@"https://datasheet.example.com/files/ds.pdf"], WebDocumentFolder(), &error);
    NSDictionary* second = SPDFMacAIWebDocumentPages(document, 2, 1, 36000, nil);
    NSString* table = [second[@"pages"] firstObject][@"text"];
    CHECK([table isEqual:@"Pin assignment\nPin | Signal | Voltage\n1 | GND | 0 V\n2 | VBUS | 5 V"] &&
          [second[@"next_page"] isEqual:@3], "a table written column by column reads row by row, cells kept apart");
    NSDictionary* all = SPDFMacAIWebDocumentPages(document, 1, 20, 36000, nil);
    CHECK([[all[@"pages"] valueForKey:@"page"] isEqual:(@[@1, @2, @3])] && !all[@"next_page"] &&
          [[all[@"pages"] firstObject][@"text"] hasPrefix:@"BM28 Series connector, 0.35 mm pitch"],
          "the whole PDF in one call when it fits");
    NSDictionary* tight = SPDFMacAIWebDocumentPages(document, 1, 20, 120, nil);
    CHECK([tight[@"pages"] count] == 1 && [tight[@"next_page"] isEqual:@2],
          "a byte budget ends the part at a page boundary and says where to go on");
    NSDictionary* cut = SPDFMacAIWebDocumentPages(document, 1, 1, 20, nil);
    CHECK([cut[@"truncated"] isEqual:@YES] && [[cut[@"pages"] firstObject][@"text"] length] <= 20,
          "a single page longer than the budget is cut and marked");
    CHECK(!SPDFMacAIWebDocumentPages(document, 4, 1, 36000, &error) && [error.localizedDescription
          containsString:@"has 3 pages"], "a page past the end says how many there are");

    NSURL* link = SPDFMacAIWebDocumentLink(document);
    CHECK(SPDFMacAIWebIsDocumentLink(link) && ![link.absoluteString containsString:WebDocumentFolder().path] &&
          [SPDFMacAIWebDocumentFileForLink(link, WebDocumentFolder()).lastPathComponent isEqual:@"ds.pdf"] &&
          [SPDFMacAIWebDocumentSourceForLink(link).absoluteString
              isEqual:@"https://datasheet.example.com/files/ds.pdf"],
          "the chat's link names the PDF by an opaque id, never its path, and finds the saved file");
    NSURL* escape = [NSURL URLWithString:@"spdf-ai://web-document?id=../../etc&web=https://x.example/"];
    CHECK(!SPDFMacAIWebDocumentFileForLink(escape, WebDocumentFolder()) && !SPDFMacAIWebIsDocumentLink(escape),
          "an id that is not one this Mac made opens nothing");

    // Two columns of prose share baselines but are wide: they stay two passages, not one interleaved row. Text set
    // sideways in the margin does not join a row.
    NSArray* lines = @[@{@"text" : @"Left column prose that runs wide", @"x0" : @50, @"y0" : @100, @"x1" : @290,
                         @"y1" : @112},
                       @{@"text" : @"Right column prose that runs wide", @"x0" : @320, @"y0" : @100, @"x1" : @560,
                         @"y1" : @112},
                       @{@"text" : @"Copyright up the margin", @"x0" : @590, @"y0" : @20, @"x1" : @602, @"y1" : @700},
                       @{@"text" : @"Cell A", @"x0" : @50, @"y0" : @400, @"x1" : @90, @"y1" : @412}];
    CHECK([SPDFMacAIWebPageLinesText(lines, 612) isEqual:@"Left column prose that runs wide\nRight column prose that "
           "runs wide\nCopyright up the margin\nCell A"], "wide prose and sideways text are never joined into rows");

    NSMutableString* words = [NSMutableString string];
    for (int line = 0; line < 400; line++) [words appendFormat:@"Line %d of a page cut short in transit.\n", line];
    NSData* text = [words dataUsingEncoding:NSUTF8StringEncoding];
    BOOL truncated = NO;
    NSData* gzip = WebGzip(text, YES);
    NSData* prefix = SPDFMacAIWebDecodeBody([gzip subdataWithRange:NSMakeRange(0, gzip.length / 2)], @"gzip",
                                            1 << 20, &truncated, nil);
    CHECK(truncated && prefix.length > 0 && prefix.length < text.length &&
          [text rangeOfData:prefix options:NSDataSearchAnchored range:NSMakeRange(0, text.length)].location == 0,
          "a gzip body cut short decodes to a prefix of the page, marked cut");
    CHECK([SPDFMacAIWebDecodeBody(gzip, @"gzip", 1 << 20, &truncated, nil) isEqual:text] && !truncated,
          "and whole, to the page");
    CHECK(!SPDFMacAIWebDecodeBody(text, @"br", 100, nil, &error) && error.code == SPDFMacAIWebErrorBadResponse,
          "bytes that are not what the site declared are refused");
}

// What the chat shows and the model reads when a PDF opens and when a site refuses, through the tool registry.
static void CheckProviderDocuments(void) {
    WebRig* rig = [WebRig new];
    SPDFMacAIRequestContext* context = [rig begin:@"Read https://datasheet.example.com/ds.pdf and "
                                        "https://www.hirose.com/en/product/series/AB12 please" web:YES];
    [rig.resolver answer:@"datasheet.example.com" with:@[@"104.21.8.225"]];
    NSData* pdf = WebDatasheetPDF();
    rig.pages[@"datasheet.example.com/ds.pdf"] = WebResponse(200, @{@"Content-Type" : @"application/octet-stream",
        @"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)pdf.length]}, pdf);
    NSDictionary* result = [rig call:@"open_page" arguments:@{@"url" : @"https://datasheet.example.com/ds.pdf",
                                                              @"count" : @2} context:context];
    CHECK([result[@"kind"] isEqual:@"pdf"] && [result[@"page_count"] isEqual:@3] &&
          [[result[@"pages"] valueForKey:@"page"] isEqual:(@[@1, @2])] && [result[@"next_page"] isEqual:@3] &&
          [result[@"notice"] containsString:@"not instructions"] && [result[@"title"] isEqual:@"BM28 Test Datasheet"],
          "open_page reads a PDF's first pages, with its page count and where to go on");
    NSDictionary* step = rig.activity.entries.lastObject;
    NSArray* rows = rig.recorder.links[step[SPDFMacAIActivityIDKey]];
    NSURL* app = [NSURL URLWithString:[rows.lastObject objectForKey:@"url"]];
    CHECK([step[SPDFMacAIActivityTitleKey] isEqual:@"Opened datasheet.example.com"] &&
          [step[SPDFMacAIActivityDetailKey] isEqual:@"A PDF of 3 pages."] && rows.count == 2 &&
          [[rows.firstObject objectForKey:@"url"] isEqual:@"https://datasheet.example.com/ds.pdf"] &&
          [[rows.lastObject objectForKey:@"title"] isEqual:@"Open in ShenzhenPDF"] &&
          [[NSData dataWithContentsOfURL:SPDFMacAIWebDocumentFileForLink(app, WebDocumentFolder())] isEqual:pdf],
          "the chat shows the PDF with its pages counted and Open in ShenzhenPDF, which finds the saved copy");
    NSUInteger connections = rig.connector.connections.count, entries = rig.activity.entries.count;
    result = [rig call:@"open_page" arguments:@{@"url" : @"https://datasheet.example.com/ds.pdf", @"page" : @3}
               context:context];
    CHECK([[result[@"pages"] valueForKey:@"page"] isEqual:@[@3]] && !result[@"next_page"] &&
          [[result[@"pages"] firstObject][@"text"] containsString:@"BM28B0.6-10DS"] &&
          rig.connector.connections.count == connections && rig.activity.entries.count == entries,
          "reading on is from the saved PDF: no second download and no new row");
    CHECK(WebRefused([rig call:@"open_page" arguments:@{@"url" : @"https://datasheet.example.com/ds.pdf",
                                                        @"count" : @21} context:context], @"count from 1 to 20"),
          "a count over 20 is refused");

    // The site still refuses. A search found the page, so its excerpt stands in; without one, the chat says so.
    rig.transport.body = WebSearchBody(@[@{@"url" : @"https://www.hirose.com/en/product/series/BM28",
        @"title" : @"BM28 Series", @"content" : @"0.35mm pitch FPC-to-board connectors rated 5A."}], 100);
    [rig call:@"web_search" arguments:@{@"query" : @"hirose BM28"} context:context];
    [rig.resolver answer:@"www.hirose.com" with:@[@"3.173.254.7"]];
    rig.pages[@"www.hirose.com/en/product/series/BM28"] = WebResponse(403, @{@"Content-Length" : @"0"}, nil);
    result = [rig call:@"open_page" arguments:@{@"url" : @"https://www.hirose.com/en/product/series/BM28"}
               context:context];
    step = rig.activity.entries.lastObject;
    CHECK([result[@"error"] containsString:@"403"] &&
          [result[@"search_excerpt"][@"snippet"] isEqual:@"0.35mm pitch FPC-to-board connectors rated 5A."] &&
          [result[@"search_excerpt"][@"notice"] containsString:@"not the page itself"],
          "a refused page gives the model the search engine's excerpt, labelled as such");
    CHECK([step[SPDFMacAIActivityTitleKey] isEqual:@"Didn’t open hirose.com"] &&
          [step[SPDFMacAIActivityStatusKey] isEqual:@"hirose.com didn’t let us read this page. Using the search "
                                                     "result’s summary instead."],
          "and the chat says what happened and what the assistant does instead");
    rig.pages[@"www.hirose.com/en/product/series/AB12"] = WebResponse(403, @{@"Content-Length" : @"0"}, nil);
    result = [rig call:@"open_page" arguments:@{@"url" : @"https://www.hirose.com/en/product/series/AB12"}
               context:context];
    step = rig.activity.entries.lastObject;
    CHECK(!result[@"search_excerpt"] && [step[SPDFMacAIActivityStatusKey] isEqual:@"hirose.com didn’t let us read "
          "this page. The assistant carries on without it."], "without a search result, it carries on without it");
    [rig.registry endRequestWithContext:context];
}

// Each failure's row in the person's words: what happened, then what the assistant does next.
static void CheckFailureCopy(void) {
    NSDictionary<NSNumber*, NSString*>* expected = @{
        @(SPDFMacAIWebErrorNotFound) : @"site.example couldn’t be found.",
        @(SPDFMacAIWebErrorUnreachable) : @"site.example couldn’t be reached.",
        @(SPDFMacAIWebErrorTimedOut) : @"site.example took too long to answer.",
        @(SPDFMacAIWebErrorTooManyRedirects) : @"site.example kept redirecting to other addresses.",
        @(SPDFMacAIWebErrorSignInRequired) : @"site.example asks for a sign-in to show this page, so it wasn’t read.",
        @(SPDFMacAIWebErrorTooLarge) : @"This PDF is too large to download (over 32 MB).",
        @(SPDFMacAIWebErrorLockedDocument) : @"This PDF is locked with a password.",
        @(SPDFMacAIWebErrorUnsupportedContent) : @"This isn’t a page or PDF the assistant can read.",
    };
    for (NSNumber* code in expected) {
        NSError* error = SPDFMacAIWebMakeError((SPDFMacAIWebError)code.integerValue, @"model text");
        NSString* status = SPDFMacAIWebPageFailureStatus(error, @"site.example", NO);
        CHECK([status isEqual:[expected[code] stringByAppendingString:@" The assistant carries on without it."]],
              "each failure says what happened and what comes next");
    }
    NSError* busy = [NSError errorWithDomain:SPDFMacAIWebErrorDomain code:SPDFMacAIWebErrorHTTPStatus
                                    userInfo:@{SPDFMacAIWebHTTPStatusKey : @404}];
    CHECK([SPDFMacAIWebPageFailureStatus(busy, @"site.example", YES) isEqual:@"site.example has no page at this "
           "address. Using the search result’s summary instead."], "a missing page, with the summary used instead");
    CHECK([SPDFMacAIWebPageFailureStatus(SPDFMacAIWebMakeError(SPDFMacAIWebErrorCancelled, @"x"), @"a", YES)
           isEqual:@"Stopped"], "Stop is only that");

    NSString* source = [NSString stringWithContentsOfFile:@"mac/SPDFMacAIIntegration.mm" encoding:NSUTF8StringEncoding
                                                    error:nil];
    NSRange open = [source rangeOfString:@"if (SPDFMacAIWebIsDocumentLink(URL)) {"];
    NSString* branch = open.location == NSNotFound ? @"" : [source substringWithRange:NSMakeRange(open.location, 400)];
    CHECK([branch containsString:@"SPDFMacAIWebDocumentFileForLink(URL,SPDFMacAIWebDocumentDefaultFolder())"] &&
          [branch containsString:@"[self showDocumentsAtPaths:@[file.path]]"],
          "Open in ShenzhenPDF goes through the reader's normal open path with the saved copy");
}
