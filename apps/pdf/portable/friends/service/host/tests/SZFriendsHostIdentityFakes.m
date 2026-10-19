// Stand-ins for the identity area's word list and codec classes, which the check-in client uses to check every
// Friends ID a host returns (SZFriendsHostCanonicalID). The host suite links only this area's objects (see
// SZFriendsHostTestSupport.h), so these answer the few messages the client sends: +bundledList, -initWithWordList:
// and -normalizedID:. The word list is SZFHTestWords; normalizedID: follows the real contract for what matters
// here: two or three list words, lowercase, joined by hyphens, anything else nil.

#import "SZFriendsHostTestSupport.h"

BOOL SZFHBundledWordListAvailable = YES;

NSArray<NSString *> *SZFHTestWords(void) {
    return @[
        @"maple", @"river", @"harbor", @"cedar", @"pebble", @"otter", @"tulip", @"lark", @"lake", @"moon",
        @"fall", @"back", @"wrong", @"name", @"forged", @"key", @"quiet", @"meadow", @"stone", @"field"
    ];
}

NSString *SZFHDrawID(NSUInteger draw) {
    NSArray<NSString *> *words = SZFHTestWords();
    return [NSString stringWithFormat:@"%@-%@", words[(draw + 4) % words.count], words[(draw / words.count + 7) %
                                                                                         words.count]];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"

@implementation SZFriendsWordList

+ (instancetype)bundledList {
    if (!SZFHBundledWordListAvailable) return nil;
    SZFriendsWordList *list = [[self alloc] init];
    list->_words = SZFHTestWords();
    return list;
}

- (NSUInteger)indexOfWord:(NSString *)word {
    return [_words indexOfObject:word];
}

@end

@implementation SZFriendsIDCodec

- (instancetype)initWithWordList:(SZFriendsWordList *)wordList {
    if ((self = [super init])) _wordList = wordList;
    return self;
}

- (NSString *)normalizedID:(NSString *)input {
    NSArray<NSString *> *parts = [input.lowercaseString componentsSeparatedByString:@"-"];
    if (parts.count < 2 || parts.count > 3) return nil;
    for (NSString *part in parts) {
        if ([_wordList indexOfWord:part] == NSNotFound) return nil;
    }
    return [parts componentsJoinedByString:@"-"];
}

@end

#pragma clang diagnostic pop
