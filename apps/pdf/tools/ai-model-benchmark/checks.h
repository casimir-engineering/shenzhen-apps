// Explicit --self-test only: no credentials, application instance or API requests.
static int BenchmarkSelfTest(void) {
    int failures = 0;
    void (^check)(BOOL, NSString *) = ^(BOOL pass, NSString *name) {
        if (!pass)
            fprintf(stderr, "FAILED: %s\n", name.UTF8String);
    };
#define CHECK(condition, name)                                                                               \
    do {                                                                                                     \
        BOOL ok = (condition);                                                                               \
        check(ok, name);                                                                                     \
        if (!ok)                                                                                             \
            failures++;                                                                                      \
    } while (0)
    NSDictionary *valid = @{
        @"name" : @"sample",
        @"path" : @"/tmp/document.pdf",
        @"question" : @"Question?",
        @"model" : @"vendor/model"
    };
    CHECK(ValidateManifest(@[ valid ]) == nil, @"valid case array");
    CHECK(ValidateManifest(
              @{@"cases" : @[ valid ],
                @"costCapUSD" : @0.75}) == nil,
          @"valid configured manifest");
    for (id invalid in @[ NSNull.null, @42, @"text", @[], @{}, @{@"cases" : @"bad"}, @[ @1 ] ])
        CHECK(ValidateManifest(invalid) != nil, @"invalid manifest root or case");
    for (NSString *key in
         @[ @"name", @"path", @"question", @"model", @"paths", @"metadata", @"metadataByPath", @"repeat" ]) {
        NSMutableDictionary *changed = [valid mutableCopy];
        changed[key] = NSNull.null;
        CHECK(ValidateManifest(@[ changed ]) != nil, @"invalid field type");
    }
    for (id cap in @[ @0, @-1, @3, @"0.5", NSNull.null ])
        CHECK(ValidateManifest(@{@"cases" : @[ valid ], @"costCapUSD" : cap}) != nil, @"invalid cap");
    CHECK(ValidateManifest(
              @[ @{@"name" : @"n", @"path" : @"relative.pdf", @"question" : @"q", @"model" : @"m"} ]) != nil,
          @"absolute path required");
    NSString *fake = @"sk-or-v1-not-a-real-key";
    NSDictionary *sanitized = Clean(@{
        fake : fake,
        @"image_url" : @{@"url" : @"data:image/png;base64,AA"},
        @"image" : @"data:image/png;base64,AA"
    });
    NSData *cleanJSON = [NSJSONSerialization dataWithJSONObject:sanitized options:0 error:nil];
    NSString *cleanText = [[NSString alloc] initWithData:cleanJSON encoding:NSUTF8StringEncoding];
    CHECK([cleanText rangeOfString:fake].location == NSNotFound, @"credential strings and keys redacted");
    CHECK([cleanText rangeOfString:@"base64"].location == NSNotFound, @"image payload omitted");
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://invalid.test"]];
    request.HTTPBody = [@"[1,2]" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableArray *bucket = [NSMutableArray array];
    for (NSString *malformed in
         @[ @"[]", @"null", @"12", @"broken", @"{\"usage\":[]}", @"{\"usage\":{\"cost\":-1}}" ])
        SZBenchmarkResponse([malformed dataUsingEncoding:NSUTF8StringEncoding], 200, nil, 0, request, bucket);
    CHECK(bucket.count == 6, @"malformed provider responses recorded without crashing");
    CHECK(MeasuredCost == 0 && MissingSuccessfulCost,
          @"invalid cost never reduces spend and blocks requests");
    CHECK(SZBenchmarkBudgetError() != nil, @"unknown successful cost blocks requests");
    MissingSuccessfulCost = NO;
    CostLimit = .1;
    SZBenchmarkResponse([@"{\"usage\":{\"cost\":0.1}}" dataUsingEncoding:NSUTF8StringEncoding], 200, nil, 0,
                        request, bucket);
    CHECK(MeasuredCost == .1 && SZBenchmarkBudgetError() != nil, @"measured cap blocks requests");
    NSDictionary *expectedPrices = @{@"prompt" : @0.18, @"completion" : @0.72};
    CHECK([SZBenchmarkProviderOptions()[@"max_price"] isEqual:expectedPrices], @"price limits fixed");
    fprintf(stderr, "Benchmark offline checks: %d failures\n", failures);
#undef CHECK
    return failures ? 1 : 0;
}
