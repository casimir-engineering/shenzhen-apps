// The Friends ID word list: the file format, validation, and the version compiled into the helper.

#import "service/identity/SZFriendsIdentityInternal.h"

#include <sodium.h>

// wordlist/friends-id-words-v1.txt as bytes, generated at build time by wordlist/embed.sh (identity.mk).
extern const unsigned char szfriends_word_list_v1[];
extern const size_t szfriends_word_list_v1_length;

NSString *const SZFriendsWordListV1Digest = @"feb7e254b1a9668501e52a3277de505c9982d69af54fe0f2ac55c2a7f5de857e";

static const NSUInteger SZFriendsWordListMaxWords = 65536;
static const NSUInteger SZFriendsWordListV1Count = 2048;

@implementation SZFriendsWordList {
    NSDictionary<NSString *, NSNumber *> *_indexes;
}

static NSError *SZFListError(NSString *description) {
    return SZFriendsIdentityMakeError(SZFriendsIdentityErrorInvalidWordList, description, nil);
}

static BOOL SZFWordIsValid(NSString *word) {
    NSUInteger length = word.length;
    if (length < 3 || length > 8) return NO;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [word characterAtIndex:i];
        if (c < 'a' || c > 'z') return NO;
    }
    return YES;
}

+ (nullable instancetype)listWithWords:(NSArray<NSString *> *)words version:(NSInteger)version
                                 error:(NSError **)error {
    if (words.count == 0 || words.count > SZFriendsWordListMaxWords) {
        if (error) *error = SZFListError(@"A word list needs between 1 and 65,536 words.");
        return nil;
    }
    NSMutableDictionary<NSString *, NSNumber *> *indexes = [NSMutableDictionary dictionaryWithCapacity:words.count];
    for (NSUInteger i = 0; i < words.count; i++) {
        NSString *word = words[i];
        if (![word isKindOfClass:[NSString class]] || !SZFWordIsValid(word)) {
            if (error) *error = SZFListError([NSString stringWithFormat:@"Word %lu is not 3-8 letters a-z.",
                                                                       (unsigned long)i + 1]);
            return nil;
        }
        if (indexes[word] != nil) {
            if (error) *error = SZFListError([NSString stringWithFormat:@"\"%@\" appears twice.", word]);
            return nil;
        }
        indexes[word] = @(i);
    }
    SZFriendsWordList *list = [[self alloc] init];
    list->_version = version;
    list->_words = [words copy];
    list->_indexes = [indexes copy];
    list->_wordLinesDigest = [self digestOfWordLines:list->_words];
    return list;
}

+ (NSString *)digestOfWordLines:(NSArray<NSString *> *)words {
    SZFriendsIdentityRequireSodium();
    crypto_hash_sha256_state state;
    crypto_hash_sha256_init(&state);
    for (NSString *word in words) {
        NSData *line = [[word stringByAppendingString:@"\n"] dataUsingEncoding:NSASCIIStringEncoding];
        crypto_hash_sha256_update(&state, line.bytes, line.length);
    }
    unsigned char digest[crypto_hash_sha256_BYTES];
    crypto_hash_sha256_final(&state, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof digest * 2];
    for (size_t i = 0; i < sizeof digest; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

+ (nullable instancetype)listWithFileData:(NSData *)data error:(NSError **)error {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    if (text == nil || ![text hasSuffix:@"\n"]) {
        if (error) *error = SZFListError(@"A word list file is ASCII text ending in a newline.");
        return nil;
    }
    NSArray<NSString *> *lines = [[text substringToIndex:text.length - 1] componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithCapacity:lines.count];
    NSInteger version = 0;
    BOOL sawVersion = NO;
    for (NSString *line in lines) {
        if ([line hasPrefix:@"#"]) {
            // Header lines only before the first word, so a stray comment cannot hide inside the pinned words.
            if (words.count > 0) {
                if (error) *error = SZFListError(@"Header lines must come before the words.");
                return nil;
            }
            if ([line hasPrefix:@"# version: "]) {
                NSScanner *scanner = [NSScanner scannerWithString:[line substringFromIndex:11]];
                if (sawVersion || ![scanner scanInteger:&version] || !scanner.atEnd || version < 1) {
                    if (error) *error = SZFListError(@"The version header must appear once, as a positive number.");
                    return nil;
                }
                sawVersion = YES;
            }
            continue;
        }
        [words addObject:line]; // blank or malformed lines fail word validation below
    }
    if (!sawVersion) {
        if (error) *error = SZFListError(@"The word list has no version header.");
        return nil;
    }
    return [self listWithWords:words version:version error:error];
}

+ (nullable instancetype)bundledList {
    static SZFriendsWordList *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithBytesNoCopy:(void *)szfriends_word_list_v1
                                            length:szfriends_word_list_v1_length
                                      freeWhenDone:NO];
        SZFriendsWordList *candidate = [self listWithFileData:data error:NULL];
        // Every check the release depends on, at the one place the helper gets its list: a build that embedded
        // the wrong file yields no list (no ID can be drawn) rather than IDs other installs cannot parse.
        if (candidate.version == 1 && candidate.count == SZFriendsWordListV1Count &&
            [candidate.wordLinesDigest isEqualToString:SZFriendsWordListV1Digest]) {
            list = candidate;
        }
    });
    return list;
}

- (NSUInteger)count {
    return _words.count;
}

- (NSString *)wordAtIndex:(NSUInteger)index {
    return _words[index];
}

- (NSUInteger)indexOfWord:(NSString *)word {
    NSNumber *index = _indexes[word];
    return index != nil ? index.unsignedIntegerValue : NSNotFound;
}

@end
