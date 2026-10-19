// Domain separation by prefix (review finding "signature domain separation"). Signatures are Ed25519 over
// UTF-8(domain) || message with no length or terminator, so a domain that is a prefix of another would let a
// signature made for one purpose verify for the other. Until a format version frames the domain, every label in
// use must be prefix-free. The labels are read from the sources themselves, so a new one cannot be forgotten here.

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

// Every string literal (Objective-C, C or JavaScript) under `root` that starts "SZFriends " and ends " v<n>", tests
// excluded: the shape of every domain and hash label. A trailing \n escape is part of the host list's domain and is
// kept as a newline.
static NSSet<NSString *> *SZFDomainLabelsUnder(NSString *root, NSArray<NSString *> *extensions) {
    NSMutableSet<NSString *> *labels = [NSMutableSet set];
    NSRegularExpression *literal =
        [NSRegularExpression regularExpressionWithPattern:@"[\"'](SZFriends [^\"'\\\\\n]*? v[0-9]+(\\\\n)?)[\"']"
                                                  options:0
                                                    error:NULL];
    NSDirectoryEnumerator<NSString *> *walk = [[NSFileManager defaultManager] enumeratorAtPath:root];
    for (NSString *relative in walk) {
        NSArray<NSString *> *parts = relative.pathComponents;
        if ([parts containsObject:@"tests"] || [parts containsObject:@"test"] ||
            [parts containsObject:@"node_modules"]) {
            continue;
        }
        if (![extensions containsObject:relative.pathExtension]) continue;
        NSString *source = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:relative]
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (source == nil) continue;
        for (NSTextCheckingResult *match in [literal matchesInString:source
                                                             options:0
                                                               range:NSMakeRange(0, source.length)]) {
            NSString *label = [source substringWithRange:[match rangeAtIndex:1]];
            [labels addObject:[label stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"]];
        }
    }
    return labels;
}

// "a < b" for every label that is a proper prefix of another.
static NSArray<NSString *> *SZFPrefixPairs(NSSet<NSString *> *labels) {
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSString *a in labels) {
        for (NSString *b in labels) {
            if ([a isEqualToString:b] || ![b hasPrefix:a]) continue;
            [pairs addObject:[NSString stringWithFormat:@"%@ < %@", a, b]];
        }
    }
    return pairs;
}

static void SZFTestDomainsArePrefixFree(NSString *vectorDirectory) {
    // tests/vectors -> session -> service -> friends
    NSString *friends = vectorDirectory;
    for (int i = 0; i < 4; i++) friends = friends.stringByDeletingLastPathComponent;
    NSString *service = [friends stringByAppendingPathComponent:@"service"];
    NSMutableSet<NSString *> *labels = [SZFDomainLabelsUnder(service, @[ @"m", @"c", @"h" ]) mutableCopy];
    // The host service signs and checks the same domains in JavaScript.
    NSString *host = [[friends stringByAppendingPathComponent:@"../server/friends"] stringByStandardizingPath];
    [labels unionSet:SZFDomainLabelsUnder([host stringByAppendingPathComponent:@"src"], @[ @"js", @"mjs" ])];

    // The scan must see the signature domains it guards, or an empty result would pass.
    for (NSString *required in @[
             @"SZFriends static v1", @"SZFriends request v1", @"SZFriends checkin v1", @"SZFriends release v1",
             @"SZFriends host list v1\n"
         ]) {
        SZF_CHECK([labels containsObject:required], @"domain %@ not found under %@", required, service);
    }
    NSArray<NSString *> *pairs = SZFPrefixPairs(labels);
    SZF_CHECK(pairs.count == 0, @"a domain is a prefix of another, so one signature verifies for both: %@", pairs);
    // And the check fires on the case the review describes.
    SZF_CHECK(SZFPrefixPairs([NSSet setWithObjects:@"SZFriends static", @"SZFriends static v1", nil]).count == 1,
              @"a planted prefix is caught");
}

void SZFRunSignatureDomainTests(NSString *vectorDirectory) {
    SZFTestDomainsArePrefixFree(vectorDirectory);
}
