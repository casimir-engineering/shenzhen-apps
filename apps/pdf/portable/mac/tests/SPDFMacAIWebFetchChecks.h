// open_page's fetch with a scripted resolver and connector: where each request would go, redirects, rebinding,
// limits, deadlines and Stop.
#pragma once
#import "SPDFMacAIWebFakes.h"
#import "SPDFMacAIWebFetcher.h"

@interface WebFetchResult : NSObject
@property(nonatomic) SPDFMacAIWebPage* page;
@property(nonatomic) NSError* error;
@property(nonatomic) BOOL done;
@end
@implementation WebFetchResult
@end

static WebFetchResult* WebFetch(SPDFMacAIWebFetcher* fetcher, NSString* link) {
    WebFetchResult* result = [WebFetchResult new];
    [fetcher fetchURL:[NSURL URLWithString:link] completion:^(SPDFMacAIWebPage* page, NSError* error) {
        CHECK(NSThread.isMainThread && !result.done, "a fetch completes once, on the main thread");
        result.page = page;
        result.error = error;
        result.done = YES;
    }];
    CHECK(WebWait(^BOOL { return result.done; }, 5), "the fetch finishes");
    return result;
}

static void CheckFetchBasics(void) {
    WebFakeResolver* resolver = [WebFakeResolver new];
    WebFakeConnector* connector = [WebFakeConnector new];
    SPDFMacAIWebFetcher* fetcher = [[SPDFMacAIWebFetcher alloc] initWithResolver:resolver connector:connector];
    [resolver answer:@"pages.example.com" with:@[@"93.184.216.34"]];
    connector.respond = ^NSArray*(WebConnection* connection) {
        (void)connection;
        return WebChunks(WebHTML(@"<title>Pricing</title><p>Plans start at $5.</p><a href=\"/plans\">Plans</a>"), 7);
    };
    WebFetchResult* result = WebFetch(fetcher, @"https://pages.example.com/pricing?b=1#top");
    WebConnection* connection = connector.connections.firstObject;
    CHECK([result.page.readable.text isEqual:@"Plans start at $5.\n\nPlans"], "the page's text comes back");
    CHECK([result.page.readable.title isEqual:@"Pricing"] && [result.page.address isEqual:@"93.184.216.34"] &&
          [[result.page.readable.links.firstObject objectForKey:@"url"] isEqual:@"https://pages.example.com/plans"],
          "with its title, its links and the address it was read from");
    CHECK(connector.connections.count == 1 && [connection.address isEqual:@"93.184.216.34"] && connection.port == 443 &&
          [connection.serverName isEqual:@"pages.example.com"],
          "the connection goes to the checked address, the certificate is checked for the name");
    CHECK([connection.request hasPrefix:@"GET /pricing?b=1 HTTP/1.1\r\nHost: pages.example.com\r\n"],
          "the request names the page without its fragment");

    connector.connections = [NSMutableArray array];
    for (NSString* link in @[@"https://127.0.0.1/", @"https://2130706433/admin", @"https://0x7f.1/", @"https://0177.1/",
                             @"https://[::1]/", @"https://[::ffff:127.0.0.1]/", @"https://169.254.169.254/latest/",
                             @"https://localhost/", @"https://printer.local/", @"https://db.internal/",
                             @"https://nas.lan/",
                             @"https://intranet/", @"http://pages.example.com/",
                             @"https://user:pw@pages.example.com/"]) {
        NSUInteger asked = resolver.asked.count;
        result = WebFetch(fetcher, link);
        CHECK(!result.page && result.error && resolver.asked.count == asked,
              "local, private, insecure and credentialed URLs are refused before any lookup");
    }
    CHECK(!connector.connections.count, "and before any connection");

    NSDictionary<NSString*, NSArray*>* privateAnswers = @{
        @"ten.example.com" : @[@"10.0.0.5"], @"mixed.example.com" : @[@"93.184.216.34", @"127.0.0.1"],
        @"v6loop.example.com" : @[@"::1"], @"zone.example.com" : @[@"fe80::1%en0"],
        @"mapped.example.com" : @[@"::ffff:192.168.1.1"], @"nat64.example.com" : @[@"64:ff9b::a00:1"],
        @"ula.example.com" : @[@"fd00::1"], @"sixtofour.example.com" : @[@"2002:c0a8:101::1"],
        @"cgnat.example.com" : @[@"100.100.100.100"], @"metadata.example.com" : @[@"169.254.169.254"],
        @"multicast.example.com" : @[@"239.1.1.1"], @"zero.example.com" : @[@"0.0.0.0"],
        @"nip.example.com" : @[@"2606:4700::1", @"192.168.0.10"],
    };
    for (NSString* host in privateAnswers) {
        [resolver answer:host with:privateAnswers[host]];
        result = WebFetch(fetcher, [NSString stringWithFormat:@"https://%@/", host]);
        CHECK(result.error.code == SPDFMacAIWebErrorPrivateAddress,
              "a name resolving to any private address is refused");
    }
    CHECK(!connector.connections.count, "without connecting to any of its addresses");
    result = WebFetch(fetcher, @"https://missing.example.com/");
    CHECK(result.error.code == SPDFMacAIWebErrorNotFound && !connector.connections.count, "an unknown name");

    result = WebFetch(fetcher, @"https://1572395042/x");
    connection = connector.connections.lastObject;
    CHECK(result.page && [connection.address isEqual:@"93.184.216.34"] && !connection.serverName &&
          [connection.request containsString:@"\r\nHost: 93.184.216.34\r\n"],
          "a public numeric host is connected to directly, in canonical form, with no lookup");

    [resolver answer:@"twoaddresses.example.com" with:@[@"2606:4700::1", @"93.184.216.34"]];
    connector.connections = [NSMutableArray array];
    connector.respond = ^NSArray*(WebConnection* attempt) {
        return [attempt.address containsString:@":"] ? nil : @[WebHTML(@"<p>via IPv4</p>")];
    };
    result = WebFetch(fetcher, @"https://twoaddresses.example.com/");
    CHECK([result.page.readable.text isEqual:@"via IPv4"] && connector.connections.count == 2 &&
          [result.page.address isEqual:@"93.184.216.34"], "an unreachable address falls back to the next checked one");
}

static void CheckFetchRedirects(void) {
    WebFakeResolver* resolver = [WebFakeResolver new];
    WebFakeConnector* connector = [WebFakeConnector new];
    SPDFMacAIWebFetcher* fetcher = [[SPDFMacAIWebFetcher alloc] initWithResolver:resolver connector:connector];
    [resolver answer:@"start.example.com" with:@[@"93.184.216.34"]];
    [resolver answer:@"other.example.com" with:@[@"151.101.1.69"]];
    [resolver answer:@"evil.example.net" with:@[@"192.168.1.1"]];
    __block NSDictionary<NSString*, NSData*>* routes = nil;
    connector.respond = ^NSArray*(WebConnection* connection) {
        NSString* line = [connection.request componentsSeparatedByString:@"\r\n"].firstObject;
        NSData* response = routes[[NSString stringWithFormat:@"%@ %@", connection.address, line]];
        return response ? @[response] : @[WebResponse(404, @{@"Content-Length" : @"0"}, nil)];
    };
    routes = @{@"93.184.216.34 GET / HTTP/1.1" : WebRedirect(301, @"https://other.example.com/page"),
               @"151.101.1.69 GET /page HTTP/1.1" : WebHTML(@"<p>Moved here</p>")};
    WebFetchResult* result = WebFetch(fetcher, @"https://start.example.com/");
    CHECK([result.page.readable.text isEqual:@"Moved here"] && result.page.redirects == 1 &&
          [result.page.URL.absoluteString isEqual:@"https://other.example.com/page"] &&
          [result.page.requestedURL.absoluteString isEqual:@"https://start.example.com/"],
          "a redirect to another public host is followed and reported");

    NSDictionary<NSString*, NSNumber*>* intoPrivate = @{@"https://127.0.0.1/admin" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://[::1]:8080/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://evil.example.net/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://router.local/" : @(SPDFMacAIWebErrorLocalName),
        @"http://other.example.com/" : @(SPDFMacAIWebErrorNotHTTPS),
        @"file:///etc/passwd" : @(SPDFMacAIWebErrorNotHTTPS)};
    for (NSString* location in intoPrivate) {
        routes = @{@"93.184.216.34 GET / HTTP/1.1" : WebRedirect(302, location)};
        connector.connections = [NSMutableArray array];
        result = WebFetch(fetcher, @"https://start.example.com/");
        CHECK(result.error.code == intoPrivate[location].integerValue && connector.connections.count == 1,
              "a redirect into private space, a local name or plain http is refused before connecting");
    }

    routes = @{@"93.184.216.34 GET / HTTP/1.1" : WebRedirect(307, @"/one"),
               @"93.184.216.34 GET /one HTTP/1.1" : WebRedirect(308, @"/two"),
               @"93.184.216.34 GET /two HTTP/1.1" : WebRedirect(303, @"/three"),
               @"93.184.216.34 GET /three HTTP/1.1" : WebHTML(@"<p>third</p>")};
    NSUInteger asked = resolver.asked.count;
    connector.connections = [NSMutableArray array];
    result = WebFetch(fetcher, @"https://start.example.com/");
    CHECK([result.page.readable.text isEqual:@"third"] && result.page.redirects == 3
          && connector.connections.count == 4,
          "three redirects are followed");
    CHECK(resolver.asked.count - asked == 4, "and the name is resolved and checked again for each hop");
    routes = @{@"93.184.216.34 GET / HTTP/1.1" : WebRedirect(302, @"/one"),
               @"93.184.216.34 GET /one HTTP/1.1" : WebRedirect(302, @"/two"),
               @"93.184.216.34 GET /two HTTP/1.1" : WebRedirect(302, @"/three"),
               @"93.184.216.34 GET /three HTTP/1.1" : WebRedirect(302, @"/four")};
    connector.connections = [NSMutableArray array];
    result = WebFetch(fetcher, @"https://start.example.com/");
    CHECK(result.error.code == SPDFMacAIWebErrorTooManyRedirects && connector.connections.count == 4,
          "a fourth redirect is not followed");
}

static void CheckFetchRebinding(void) {
    WebFakeResolver* resolver = [WebFakeResolver new];
    WebFakeConnector* connector = [WebFakeConnector new];
    SPDFMacAIWebFetcher* fetcher = [[SPDFMacAIWebFetcher alloc] initWithResolver:resolver connector:connector];
    // The attacker's name answers with a public address for the check and a private one ever after.
    [resolver answer:@"rebind.example.net" with:@[@"93.184.216.34"]];
    [resolver answer:@"rebind.example.net" with:@[@"127.0.0.1"]];
    connector.respond = ^NSArray*(WebConnection* connection) {
        (void)connection;
        return @[WebHTML(@"<p>first answer</p>")];
    };
    WebFetchResult* result = WebFetch(fetcher, @"https://rebind.example.net/");
    CHECK(result.page && resolver.asked.count == 1 && connector.connections.count == 1 &&
          [connector.connections[0].address isEqual:@"93.184.216.34"],
          "the connection uses the address that was checked; the name is never looked up again to connect");
    connector.respond = ^NSArray*(WebConnection* connection) {
        (void)connection;
        return @[WebRedirect(302, @"/again")];
    };
    [resolver answer:@"rebind2.example.net" with:@[@"93.184.216.34"]];
    [resolver answer:@"rebind2.example.net" with:@[@"10.0.0.1"]];
    connector.connections = [NSMutableArray array];
    result = WebFetch(fetcher, @"https://rebind2.example.net/");
    CHECK(result.error.code == SPDFMacAIWebErrorPrivateAddress && connector.connections.count == 1,
          "a redirect back to the same name sees the new private answer and stops");
}

static void CheckFetchLimits(void) {
    WebFakeResolver* resolver = [WebFakeResolver new];
    WebFakeConnector* connector = [WebFakeConnector new];
    SPDFMacAIWebFetcher* fetcher = [[SPDFMacAIWebFetcher alloc] initWithResolver:resolver connector:connector];
    [resolver answer:@"big.example.com" with:@[@"93.184.216.34"]];
    NSMutableData* huge = [NSMutableData dataWithCapacity:3 * 1024 * 1024];
    while (huge.length < 3 * 1024 * 1024) [huge appendData:[@"<p>more words here</p>"
        dataUsingEncoding:NSUTF8StringEncoding]];
    connector.respond = ^NSArray*(WebConnection* connection) {
        (void)connection;
        return WebChunks(WebResponse(200, @{@"Content-Type" : @"text/html"}, huge), 64 * 1024);
    };
    WebFetchResult* result = WebFetch(fetcher, @"https://big.example.com/");
    WebConnection* connection = connector.connections.firstObject;
    CHECK(result.page.truncated && connection.stoppedByReader && connection.delivered <= 2 * 1024 * 1024 + 64 * 1024,
          "reading stops at 2 MB from the site");
    CHECK([result.page.readable.text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 200 * 1024 &&
          result.page.readable.truncated, "and at most 200 KB of text is kept");

    connector.respond = ^NSArray*(WebConnection* connection) {
        (void)connection;
        return @[WebResponse(200, @{@"Content-Type" : @"application/pdf", @"Content-Length" : @"4"}, [@"%PDF"
            dataUsingEncoding:NSASCIIStringEncoding])];
    };
    CHECK(WebFetch(fetcher, @"https://big.example.com/").error.code == SPDFMacAIWebErrorUnsupportedContent,
          "a PDF is refused as content");
    connector.respond = ^NSArray*(WebConnection* connection) {
        (void)connection;
        return @[WebResponse(404, @{@"Content-Length" : @"0"}, nil)];
    };
    result = WebFetch(fetcher, @"https://big.example.com/");
    CHECK(result.error.code == SPDFMacAIWebErrorHTTPStatus &&
          [result.error.userInfo[SPDFMacAIWebHTTPStatusKey] isEqual:@404], "an error status is reported with its code");

    connector.hang = YES;
    fetcher.timeout = 0.3;
    connector.connections = [NSMutableArray array];
    NSDate* started = [NSDate date];
    result = WebFetch(fetcher, @"https://big.example.com/");
    CHECK(result.error.code == SPDFMacAIWebErrorTimedOut && -[started timeIntervalSinceNow] < 2,
          "a site that never answers times out");
    CHECK(WebWait(^BOOL { return connector.connections.firstObject.cancelled; }, 2),
          "and its connection is cancelled");
    resolver.silent = YES;
    result = WebFetch(fetcher, @"https://big.example.com/");
    CHECK(result.error.code == SPDFMacAIWebErrorTimedOut, "a lookup that never answers times out too");

    resolver.silent = NO;
    fetcher.timeout = 5;
    connector.connections = [NSMutableArray array];
    WebFetchResult* stopped = [WebFetchResult new];
    dispatch_block_t stop = [fetcher fetchURL:[NSURL URLWithString:@"https://big.example.com/"]
                                   completion:^(SPDFMacAIWebPage* page, NSError* error) {
        stopped.page = page;
        stopped.error = error;
        stopped.done = YES;
    }];
    WebWait(^BOOL { return connector.connections.count > 0; }, 2);
    stop();
    CHECK(WebWait(^BOOL { return stopped.done; }, 2) && stopped.error.code == SPDFMacAIWebErrorCancelled,
          "Stop ends the fetch with a cancellation");
    CHECK(WebWait(^BOOL { return connector.connections.firstObject.cancelled; }, 2), "and cancels its connection");
}
