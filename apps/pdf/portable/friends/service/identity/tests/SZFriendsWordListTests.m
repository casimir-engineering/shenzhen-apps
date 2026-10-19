// The Friends ID word list (ADR 0006): curation rules 1 to 5 on the shipped file, its attribution header, the
// SHA-256 pin, the copy compiled into the helper, and the format checks of SZFriendsWordList.
// Usage: SZFriendsWordListTests <path to wordlist/friends-id-words-v1.txt>

#import "service/identity/SZFriendsIdentityInternal.h"
#import "SZFriendsIdentityTestSupport.h"

#include <string.h>

// Irregular forms for rule 4, the same table as wordlist/curate.py: past tenses, participles and plurals that
// cannot be derived by suffix rules. Each entry is "base form form...".
static const char *const SZFIrregular[] = {
    "arise arose arisen", "awake awoke awoken", "bear bore born", "begin began begun", "bite bit bitten",
    "blow blew blown", "break broke broken", "bring brought", "build built", "buy bought", "catch caught",
    "choose chose chosen", "come came", "dig dug", "draw drew drawn", "drink drank drunk", "drive drove driven",
    "eat ate eaten", "fall fell fallen", "feel felt", "find found", "fly flew flown", "freeze froze frozen",
    "get got gotten", "give gave given", "grow grew grown", "hang hung", "have had", "hear heard",
    "hide hid hidden", "hold held", "keep kept", "know knew known", "lay laid", "lead led", "leave left",
    "lend lent", "light lit", "lose lost", "make made", "mean meant", "meet met", "pay paid", "prove proven",
    "ride rode ridden", "ring rang rung", "rise rose risen", "run ran", "say said", "see saw seen", "sell sold",
    "send sent", "shake shook shaken", "shine shone", "shrink shrank shrunk", "sing sang sung", "sink sank sunk",
    "sit sat", "sleep slept", "slide slid", "speak spoke spoken", "spend spent", "spring sprang sprung",
    "stand stood", "steal stole stolen", "stick stuck", "sting stung", "stride strode", "strike struck",
    "swear swore sworn", "sweep swept", "swim swam swum", "swing swung", "take took taken", "teach taught",
    "tear tore torn", "tell told", "think thought", "throw threw thrown", "wake woke woken", "wear wore worn",
    "weave wove woven", "win won", "wind wound", "write wrote written",
    "rebuild rebuilt", "remake remade", "retell retold", "rewind rewound", "rewrite rewrote rewritten",
    "unbend unbent", "undo undid undone", "unfreeze unfroze unfrozen", "unweave unwove unwoven",
    "unwind unwound", "outgrow outgrew outgrown", "undergo underwent undergone",
    "elf elves", "half halves", "leaf leaves", "loaf loaves", "knife knives", "wolf wolves", "mouse mice",
    "goose geese", "child children", "foot feet", "tooth teeth",
};

// Rule 2: two words clash when they agree on their first five letters, a shorter word counting as its whole
// spelling, so five typed letters (or all of a shorter word) always identify one word. Five since 2026-10-12; it was
// four, which kept compounds such as backyard out of a list that already had backpack.
static const size_t SZFPrefixLetters = 5;

static BOOL SharePrefix(const char *a, size_t la, const char *b, size_t lb) {
    size_t n = la < lb ? la : lb;
    if (n > SZFPrefixLetters) n = SZFPrefixLetters;
    return memcmp(a, b, n) == 0;
}

static BOOL WithinOneEdit(const char *a, size_t la, const char *b, size_t lb) {
    if (la > lb + 1 || lb > la + 1) return NO;
    if (la == lb) {
        int differences = 0;
        for (size_t i = 0; i < la; i++) differences += a[i] != b[i];
        return differences <= 1;
    }
    if (la > lb) {
        const char *t = a; a = b; b = t;
        size_t tl = la; la = lb; lb = tl;
    }
    size_t i = 0;
    while (i < la && a[i] == b[i]) i++;
    return memcmp(a + i, b + i + 1, la - i) == 0;
}

static BOOL LRNConfusable(const char *a, size_t la, const char *b, size_t lb) {
    if (la != lb || memcmp(a, b, la) == 0) return NO;
    for (size_t i = 0; i < la; i++) {
        if (a[i] == b[i]) continue;
        char x = a[i] < b[i] ? a[i] : b[i], y = a[i] < b[i] ? b[i] : a[i];
        if (!((x == 'l' && y == 'r') || (x == 'l' && y == 'n'))) return NO;
    }
    return YES;
}

// Rule 4's regular forms of `base`: plural, past tense, -ing and -er, with the usual spelling changes.
static NSSet<NSString *> *Inflections(NSString *base, NSDictionary<NSString *, NSArray *> *irregular) {
    NSMutableSet *forms = [NSMutableSet set];
    for (NSString *suffix in @[ @"s", @"es", @"ed", @"d", @"ing", @"er", @"r" ])
        [forms addObject:[base stringByAppendingString:suffix]];
    NSUInteger n = base.length;
    unichar last = [base characterAtIndex:n - 1];
    NSString *stem = [base substringToIndex:n - 1];
    BOOL (^vowel)(unichar) = ^BOOL(unichar c) { return strchr("aeiou", c) != NULL; };
    if (last == 'e') {
        [forms addObject:[stem stringByAppendingString:@"ing"]];
        [forms addObject:[stem stringByAppendingString:@"er"]];
    }
    if (n >= 2 && last == 'y' && !vowel([base characterAtIndex:n - 2])) {
        for (NSString *suffix in @[ @"ies", @"ied", @"ier" ]) [forms addObject:[stem stringByAppendingString:suffix]];
    }
    if (n >= 3 && strchr("aeiouwxy", last) == NULL && vowel([base characterAtIndex:n - 2]) &&
        !vowel([base characterAtIndex:n - 3])) {
        NSString *doubled = [base stringByAppendingFormat:@"%C", last];
        for (NSString *suffix in @[ @"ed", @"ing", @"er" ]) [forms addObject:[doubled stringByAppendingString:suffix]];
    }
    [forms addObjectsFromArray:irregular[base] ?: @[]];
    return forms;
}

static void TestCurationRules(NSArray<NSString *> *words) {
    // Rule 1: exactly 2,048 unique entries, sorted, lowercase a-z only, 3 to 8 letters.
    SZFExpect(words.count == 2048, @"rule 1: %lu words", (unsigned long)words.count);
    SZFExpect([words isEqualToArray:[words sortedArrayUsingSelector:@selector(compare:)]], @"rule 1: sorted");
    SZFExpect([NSSet setWithArray:words].count == words.count, @"rule 1: unique");
    NSUInteger n = words.count;
    char (*text)[9] = calloc(n, sizeof *text);
    size_t *length = calloc(n, sizeof *length);
    for (NSUInteger i = 0; i < n; i++) {
        const char *w = words[i].UTF8String;
        length[i] = strlen(w);
        BOOL ok = length[i] >= 3 && length[i] <= 8;
        for (size_t k = 0; ok && k < length[i]; k++) ok = w[k] >= 'a' && w[k] <= 'z';
        SZFExpect(ok, @"rule 1: '%@'", words[i]);
        if (ok) memcpy(text[i], w, length[i]);
    }
    // Rules 2, 3 and 5 over every pair: distinct first five letters, edit distance at least 2, and no l/r or
    // n/l-only difference.
    int reported = 0;
    for (NSUInteger i = 0; i < n; i++) {
        for (NSUInteger j = i + 1; j < n; j++) {
            int rule = 0;
            if (SharePrefix(text[i], length[i], text[j], length[j])) rule = 2;
            else if (WithinOneEdit(text[i], length[i], text[j], length[j])) rule = 3;
            else if (LRNConfusable(text[i], length[i], text[j], length[j])) rule = 5;
            if (rule != 0 && reported++ < 20) SZFExpect(NO, @"rule %d: %@ and %@", rule, words[i], words[j]);
        }
    }
    SZFExpect(reported == 0, @"rules 2, 3 and 5: %d pairs", reported);
    free(text);
    free(length);
    // Rule 4: no plural, past tense, -ing or -er form of another listed word.
    NSMutableDictionary<NSString *, NSArray *> *irregular = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < sizeof SZFIrregular / sizeof SZFIrregular[0]; i++) {
        NSArray *parts = [@(SZFIrregular[i]) componentsSeparatedByString:@" "];
        irregular[parts[0]] = [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)];
    }
    NSSet *listed = [NSSet setWithArray:words];
    for (NSString *word in words) {
        for (NSString *form in Inflections(word, irregular)) {
            SZFExpect(![listed containsObject:form], @"rule 4: %@ is a form of %@", form, word);
        }
    }
}

static void TestRulesBite(void) {
    // Each rule must catch its violation, or a broken check would pass any list.
    SZFExpect(SharePrefix("backpack", 8, "backpage", 8) && SharePrefix("oat", 3, "oatmeal", 7) &&
                  SharePrefix("bath", 4, "bathe", 5) && SharePrefix("candy", 5, "candy", 5), @"rule 2 clashes");
    SZFExpect(!SharePrefix("backpack", 8, "backyard", 8) && !SharePrefix("candle", 6, "candy", 5) &&
                  !SharePrefix("doorbell", 8, "doormat", 7) && !SharePrefix("ice", 3, "icy", 3), @"rule 2 allows");
    SZFExpect(WithinOneEdit("light", 5, "night", 5) && WithinOneEdit("cart", 4, "carts", 5) &&
                  WithinOneEdit("bake", 4, "brake", 5) && !WithinOneEdit("ladder", 6, "latter", 6), @"edit distance");
    SZFExpect(LRNConfusable("glass", 5, "grass", 5) && LRNConfusable("rail", 4, "lain", 4) &&
                  !LRNConfusable("rain", 4, "lane", 4) && !LRNConfusable("crane", 5, "crate", 5), @"l/r and n/l");
    NSDictionary *irregular = @{@"speak" : @[ @"spoke", @"spoken" ]};
    SZFExpect([Inflections(@"bus", irregular) containsObject:@"buses"] &&
                  [Inflections(@"bake", irregular) containsObject:@"baking"] &&
                  [Inflections(@"party", irregular) containsObject:@"parties"] &&
                  [Inflections(@"dig", irregular) containsObject:@"digging"] &&
                  [Inflections(@"farm", irregular) containsObject:@"farmer"] &&
                  [Inflections(@"speak", irregular) containsObject:@"spoken"], @"inflections");
}

static void TestFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    SZFExpect(data != nil, @"word list at %@", path);
    if (data == nil) return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    NSMutableArray *header = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"# "]) [header addObject:[line substringFromIndex:2]];
    }
    NSString *joined = [header componentsJoinedByString:@" "];
    NSString *attribution = @"Friends ID words are a selection from the EFF Large Wordlist for Passphrases by the "
        @"Electronic Frontier Foundation (https://www.eff.org/dice), used under CC BY 4.0 "
        @"(https://creativecommons.org/licenses/by/4.0/). Changes: 2,048 of its 7,776 words selected; none altered.";
    SZFExpect([joined containsString:attribution], @"attribution header (ADR 0006)");
    SZFExpect([joined containsString:@"source: https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt"], @"URL");
    NSString *source = @"source-sha256: addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e";
    SZFExpect([joined containsString:source], @"source digest");
    SZFExpect([joined containsString:@"license: CC BY 4.0, https://creativecommons.org/licenses/by/4.0/"], @"license");

    NSError *error = nil;
    SZFriendsWordList *list = [SZFriendsWordList listWithFileData:data error:&error];
    SZFExpect(list != nil && list.version == 1, @"parses as version 1: %@", error);
    TestCurationRules(list.words);
    SZFExpect([list.wordLinesDigest isEqualToString:SZFriendsWordListV1Digest], @"pin: file digest %@",
              list.wordLinesDigest);
    SZFExpect([joined containsString:[@"words-sha256: " stringByAppendingString:SZFriendsWordListV1Digest]],
              @"header names the pinned digest");

    // The helper's compiled-in copy is this file, and passes its own checks.
    SZFriendsWordList *bundled = [SZFriendsWordList bundledList];
    SZFExpect(bundled != nil && [bundled.words isEqualToArray:list.words] && bundled.version == 1, @"bundled list");
    SZFExpect(bundled == [SZFriendsWordList bundledList], @"bundled list is shared");
    SZFExpect([bundled indexOfWord:list.words[100]] == 100 && [bundled indexOfWord:@"absent"] == NSNotFound &&
                  [[bundled wordAtIndex:2047] isEqualToString:list.words.lastObject], @"lookups");

    // Changing one word changes the digest: a new list can only ship as a deliberate new version.
    NSMutableArray *changed = [list.words mutableCopy];
    changed[7] = [changed[7] isEqualToString:@"zebra"] ? @"zebras" : @"zebra";
    SZFExpect(![[SZFriendsWordList listWithWords:changed version:1 error:NULL].wordLinesDigest
                  isEqualToString:SZFriendsWordListV1Digest], @"pin bites on a changed word");
}

static void TestFormatChecks(void) {
    NSError *error = nil;
    SZFExpect(([SZFriendsWordList listWithWords:@[ @"maple", @"river" ] version:3 error:&error].count == 2), @"small");
    for (NSArray *bad in @[ @[], @[ @"Maple" ], @[ @"ma" ], @[ @"mapletree" ], @[ @"map1e" ], @[ @"maple", @"maple" ],
                            @[ @"café" ], @[ @"" ] ]) {
        error = nil;
        SZFExpect([SZFriendsWordList listWithWords:bad version:1 error:&error] == nil &&
                      error.code == SZFriendsIdentityErrorInvalidWordList, @"rejects %@", bad);
    }
    NSString *good = @"# version: 2\n# note\nmaple\nriver\n";
    SZFriendsWordList *parsed = [SZFriendsWordList listWithFileData:[good dataUsingEncoding:NSASCIIStringEncoding]
                                                              error:&error];
    SZFExpect(parsed.version == 2 && [parsed.words isEqualToArray:(@[ @"maple", @"river" ])], @"file format");
    NSArray *badFiles = @[
        @"maple\nriver\n", @"# version: 1\nmaple\n# late\nriver\n", @"# version: 1\nmaple\n\nriver\n",
        @"# version: 1\nmaple\nriver", @"# version: 1\r\nmaple\r\n", @"# version: x\nmaple\n",
        @"# version: 1\n# version: 1\nmaple\n", @"# version: 0\nmaple\n",
    ];
    for (NSString *bad in badFiles) {
        error = nil;
        NSData *data = [bad dataUsingEncoding:NSASCIIStringEncoding];
        SZFExpect([SZFriendsWordList listWithFileData:data error:&error] == nil &&
                      error.code == SZFriendsIdentityErrorInvalidWordList, @"rejects file %@", bad.debugDescription);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <friends-id-words-v1.txt>\n", argv[0]);
            return 2;
        }
        TestRulesBite();
        TestFile(@(argv[1]));
        TestFormatChecks();
        return SZFFinish("SZFriendsWordListTests");
    }
}
