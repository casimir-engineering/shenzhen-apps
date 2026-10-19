// Friends IDs as people type them, and as the helper draws them.

#import "service/identity/SZFriendsIdentityInternal.h"

#include <sodium.h>

// The longest real ID is three 8-letter words and two separators (26 characters); a generous cap keeps a pasted
// page of text from being normalised and split at all.
static const NSUInteger SZFriendsIDInputMaxLength = 256;

SZFriendsRandomUniform SZFriendsSystemRandomUniform(void) {
    SZFriendsIdentityRequireSodium();
    return ^uint32_t(uint32_t bound) { return randombytes_uniform(bound); };
}

NSUInteger SZFriendsWordCountForNewID(NSInteger listNewIDWords, NSUInteger collisionsInARow) {
    return (listNewIDWords >= 3 || collisionsInARow >= 3) ? 3 : 2;
}

@implementation SZFriendsIDCodec

- (instancetype)initWithWordList:(SZFriendsWordList *)wordList {
    if ((self = [super init])) _wordList = wordList;
    return self;
}

// Spaces, hyphens, dots and underscores, plus the forms input methods substitute for them: full-width variants
// (folded by NFKC first), the ideographic full stop and space a Chinese IME types, and the en and em dashes macOS
// smart punctuation turns a typed hyphen into.
static NSCharacterSet *SZFSeparators(void) {
    static NSCharacterSet *separators;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [set addCharactersInString:@"-._‐‑‒–—―−。｡・"];
        separators = [set copy];
    });
    return separators;
}

- (nullable NSString *)normalizedID:(NSString *)input {
    if (input.length == 0 || input.length > SZFriendsIDInputMaxLength) return nil;
    NSString *folded = [input precomposedStringWithCompatibilityMapping].lowercaseString;
    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithCapacity:3];
    for (NSString *part in [folded componentsSeparatedByCharactersInSet:SZFSeparators()]) {
        if (part.length == 0) continue; // runs of separators, and the trimmed ends
        if (words.count == 3 || [_wordList indexOfWord:part] == NSNotFound) return nil;
        [words addObject:part];
    }
    if (words.count < 2) return nil;
    return [words componentsJoinedByString:@"-"];
}

- (NSString *)randomIDWithWordCount:(NSUInteger)wordCount generator:(uint32_t (^)(uint32_t bound))randomUniform {
    if (wordCount != 2 && wordCount != 3) {
        [NSException raise:NSInvalidArgumentException format:@"Friends IDs have 2 or 3 words, not %lu",
                                                             (unsigned long)wordCount];
    }
    uint32_t bound = (uint32_t)_wordList.count;
    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithCapacity:wordCount];
    for (NSUInteger i = 0; i < wordCount; i++) {
        uint32_t draw = randomUniform(bound);
        // A generator that ignores its bound would pick words unevenly or crash later; fail at the cause.
        if (draw >= bound) [NSException raise:NSInvalidArgumentException format:@"Random draw out of range"];
        [words addObject:[_wordList wordAtIndex:draw]];
    }
    return [words componentsJoinedByString:@"-"];
}

@end
