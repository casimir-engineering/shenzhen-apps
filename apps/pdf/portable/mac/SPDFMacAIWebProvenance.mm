#import "SPDFMacAIWebProvenance.h"

// Enough for every link of 20 pages and 10 searches; past it the oldest addresses are not dropped, new ones are
// simply not added, so a flood of links on one page cannot push out what the person typed.
static const NSUInteger kMaximumAddresses = 5000;
static const NSUInteger kMaximumURLLength = 2048;

NSString* SPDFMacAIWebProvenanceKey(NSURL* URL) {
    NSURLComponents* parts = URL ? [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES] : nil;
    NSString* scheme = parts.scheme.lowercaseString;
    NSString* host = nil;
    if (@available(macOS 13.0, *)) host = parts.encodedHost;
    else host = parts.percentEncodedHost;
    host = host.lowercaseString;
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (!host.length || !([scheme isEqual:@"https"] || [scheme isEqual:@"http"])) return nil;
    NSInteger port = parts.port.integerValue;
    BOOL standard = !parts.port || port == 443 || (port == 80 && [scheme isEqual:@"http"]);
    NSString* path = parts.percentEncodedPath ?: @"";
    if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    NSString* query = parts.percentEncodedQuery.length ? [@"?" stringByAppendingString:parts.percentEncodedQuery] : @"";
    return [NSString stringWithFormat:@"%@%@%@%@", host, standard ? @"" : [NSString stringWithFormat:@":%ld",
                                                                            (long)port], path, query];
}

static NSUInteger Count(NSString* text, unichar character) {
    NSUInteger count = 0;
    for (NSUInteger index = 0; index < text.length; index++) count += [text characterAtIndex:index] == character;
    return count;
}

@implementation SPDFMacAIWebProvenance {
    NSMutableSet<NSString*>* _keys;
    NSMutableSet<NSString*>* _scanned; // the person's texts already read, by hash and length: resent every turn
}

- (instancetype)init {
    if ((self = [super init])) [self reset];
    return self;
}

- (void)reset {
    _keys = [NSMutableSet set];
    _scanned = [NSMutableSet set];
}

- (NSUInteger)count { return _keys.count; }

- (void)noteURL:(NSURL*)URL {
    NSString* key = URL.absoluteString.length <= kMaximumURLLength ? SPDFMacAIWebProvenanceKey(URL) : nil;
    if (key && _keys.count < kMaximumAddresses) [_keys addObject:key];
}

- (BOOL)allowsURL:(NSURL*)URL {
    NSString* key = SPDFMacAIWebProvenanceKey(URL);
    return key && [_keys containsObject:key];
}

- (BOOL)alreadyScanned:(NSString*)text {
    NSString* mark = [NSString stringWithFormat:@"%lu:%lu", (unsigned long)text.hash, (unsigned long)text.length];
    if ([_scanned containsObject:mark]) return YES;
    [_scanned addObject:mark];
    return NO;
}

- (void)notePersonText:(NSString*)text {
    if (![text isKindOfClass:NSString.class] || !text.length || [self alreadyScanned:text]) return;
    [self scanURLs:text];
    NSDataDetector* detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    [detector enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                            usingBlock:^(NSTextCheckingResult* match, NSMatchingFlags flags, BOOL* stop) {
        (void)flags; (void)stop;
        [self noteURL:match.URL];
    }];
}

// Every "http://" or "https://" run up to a character no address contains unescaped, trailing punctuation dropped.
- (void)scanURLs:(NSString*)plain {
    static NSCharacterSet* stops;
    static NSCharacterSet* trailing;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet* set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [set addCharactersInString:@"\"'<>`\\{}|^[]"];
        stops = set;
        trailing = [NSCharacterSet characterSetWithCharactersInString:@".,;:!?)*_"];
    });
    NSRange search = NSMakeRange(0, plain.length);
    while (search.length) {
        NSRange found = [plain rangeOfString:@"http" options:NSCaseInsensitiveSearch range:search];
        if (found.location == NSNotFound) return;
        NSRange end = [plain rangeOfCharacterFromSet:stops options:0
                                               range:NSMakeRange(found.location, plain.length - found.location)];
        NSUInteger stop = end.location == NSNotFound ? plain.length : end.location;
        NSString* candidate = [plain substringWithRange:NSMakeRange(found.location, stop - found.location)];
        // A Markdown link's closing parenthesis follows the URL; a parenthesis inside one (Wikipedia) is balanced.
        while (candidate.length && [trailing characterIsMember:[candidate characterAtIndex:candidate.length - 1]]) {
            if ([candidate characterAtIndex:candidate.length - 1] == ')' &&
                Count(candidate, '(') >= Count(candidate, ')')) break;
            candidate = [candidate substringToIndex:candidate.length - 1];
        }
        NSString* lower = candidate.lowercaseString;
        if ([lower hasPrefix:@"https://"] || [lower hasPrefix:@"http://"])
            [self noteURL:[NSURL URLWithString:candidate]];
        NSUInteger next = MAX(stop, found.location + 4);
        search = NSMakeRange(next, plain.length - next);
    }
}

@end
