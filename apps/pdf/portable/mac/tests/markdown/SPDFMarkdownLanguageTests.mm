#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownHighlighter.h"

static void SPDFExpectNoOverlap(NSArray<SPDFMarkdownSyntaxToken*>* tokens, NSString* language) {
    for (NSUInteger i = 1; i < tokens.count; ++i)
        SPDFExpect(NSIntersectionRange(tokens[i - 1].range, tokens[i].range).length == 0,
                   [language stringByAppendingString:@" tokens never overlap"]);
}

static SPDFMarkdownSyntaxToken* SPDFTokenCovering(NSArray<SPDFMarkdownSyntaxToken*>* tokens, NSRange range) {
    for (SPDFMarkdownSyntaxToken* token in tokens) {
        if (token.range.location <= range.location && NSMaxRange(token.range) >= NSMaxRange(range)) return token;
    }
    return nil;
}

static void SPDFExpectFragmentKind(NSArray<SPDFMarkdownSyntaxToken*>* tokens, NSString* code,
                                   NSString* fragment, SPDFMarkdownSyntaxTokenKind kind, NSString* label) {
    NSRange range = [code rangeOfString:fragment];
    if (range.location == NSNotFound) {
        SPDFExpect(NO, [label stringByAppendingString:@" fragment exists in the sample"]);
        return;
    }
    SPDFMarkdownSyntaxToken* token = SPDFTokenCovering(tokens, range);
    SPDFExpect(token != nil && token.kind == kind, label);
}

// One smoke sample per advertised language: proves the dedicated lexer emits
// the expected comment/string/keyword (and number/key/markup where natural)
// token classes without overlapping ranges.
static NSDictionary<NSString*, NSDictionary*>* SPDFLanguageSamples(void) {
    NSDictionary* (^sample)(NSString*, NSDictionary*) = ^(NSString* code, NSDictionary* expected) {
        return @{@"code": code, @"expected": expected};
    };
    NSNumber* keyword = @(SPDFMarkdownSyntaxTokenKeyword);
    NSNumber* string = @(SPDFMarkdownSyntaxTokenString);
    NSNumber* comment = @(SPDFMarkdownSyntaxTokenComment);
    NSNumber* number = @(SPDFMarkdownSyntaxTokenNumber);
    NSNumber* key = @(SPDFMarkdownSyntaxTokenKey);
    NSNumber* markup = @(SPDFMarkdownSyntaxTokenMarkup);
    return @{
        @"c": sample(@"int value = 42; // note\nconst char* s = \"text\";",
                     @{@"// note": comment, @"\"text\"": string, @"int": keyword, @"42": number}),
        @"cpp": sample(@"// note\nclass Foo { const char* s = \"text\"; int x = 0x1F; };",
                       @{@"// note": comment, @"\"text\"": string, @"class": keyword, @"0x1F": number}),
        @"objc": sample(@"// note\n@interface Foo\n@end\nNSString* s = @\"text\"; int n = 42;",
                        @{@"// note": comment, @"\"text\"": string, @"@interface": keyword, @"42": number}),
        @"csharp": sample(@"// note\npublic class Foo { string s = \"text\"; int n = 42; }",
                          @{@"// note": comment, @"\"text\"": string, @"public": keyword, @"42": number}),
        @"java": sample(@"// note\npublic class Foo { String s = \"text\"; int n = 42; }",
                        @{@"// note": comment, @"\"text\"": string, @"public": keyword, @"42": number}),
        @"kotlin": sample(@"// note\nval s = \"text\"\nvar n = 42",
                          @{@"// note": comment, @"\"text\"": string, @"val": keyword, @"42": number}),
        @"go": sample(@"// note\nfunc main() { s := \"text\"; n := 42 }",
                      @{@"// note": comment, @"\"text\"": string, @"func": keyword, @"42": number}),
        @"rust": sample(@"// note\nfn main() { let s = \"text\"; let n = 42; }",
                        @{@"// note": comment, @"\"text\"": string, @"fn": keyword, @"42": number}),
        @"typescript": sample(@"// note\ninterface Foo { s: string }\nconst t = \"text\"; const n = 42;",
                              @{@"// note": comment, @"\"text\"": string, @"interface": keyword, @"42": number}),
        @"dart": sample(@"// note\nfinal s = \"text\"; var n = 42;",
                        @{@"// note": comment, @"\"text\"": string, @"final": keyword, @"42": number}),
        @"scala": sample(@"// note\nval s = \"text\"\nvar n = 42",
                         @{@"// note": comment, @"\"text\"": string, @"val": keyword, @"42": number}),
        @"ruby": sample(@"# note\ndef greet\n  s = \"text\"\n  n = 42\nend",
                        @{@"# note": comment, @"\"text\"": string, @"def": keyword, @"42": number}),
        @"php": sample(@"// note\nfunction f($name) { $s = \"text\"; return 42; }",
                       @{@"// note": comment, @"\"text\"": string, @"function": keyword, @"42": number,
                         @"$name": key}),
        @"shell": sample(@"# note\nif true; then\n  echo \"text\" $HOME 42\nfi",
                         @{@"# note": comment, @"\"text\"": string, @"if": keyword, @"42": number,
                           @"$HOME": key}),
        @"perl": sample(@"# note\nmy $name = \"text\";\nmy $n = 42;",
                        @{@"# note": comment, @"\"text\"": string, @"my": keyword, @"42": number,
                          @"$name": key}),
        @"lua": sample(@"-- note\nlocal s = \"text\"\nlocal n = 42",
                       @{@"-- note": comment, @"\"text\"": string, @"local": keyword, @"42": number}),
        @"r": sample(@"# note\nf <- function(x) x + 42\ns <- \"text\"",
                     @{@"# note": comment, @"\"text\"": string, @"function": keyword, @"42": number}),
        @"haskell": sample(@"-- note\nmodule Main where\ngreeting = \"text\"\nanswer = 42",
                           @{@"-- note": comment, @"\"text\"": string, @"module": keyword, @"42": number}),
        @"sql": sample(@"-- note\nSELECT name FROM users WHERE id = 42 AND label = 'text';",
                       @{@"-- note": comment, @"'text'": string, @"SELECT": keyword, @"42": number}),
        @"html": sample(@"<!-- note -->\n<div class=\"box\">42 &amp; more</div>",
                        @{@"<!-- note -->": comment, @"\"box\"": string, @"<div": markup, @"class": key,
                          @"&amp;": markup}),
        @"xml": sample(@"<!-- note -->\n<node attr=\"1\">text</node>",
                       @{@"<!-- note -->": comment, @"\"1\"": string, @"<node": markup, @"attr": key}),
        @"css": sample(@"/* note */\n.box { content: \"text\"; color: #fff; margin: 42px; }",
                       @{@"/* note */": comment, @"\"text\"": string, @".box": markup, @"content": key,
                         @"#fff": number, @"42": number}),
        @"latex": sample(@"% note\n\\section{Intro} $x + 1$",
                         @{@"% note": comment, @"$x + 1$": string, @"\\section": keyword, @"{": markup}),
        @"yaml": sample(@"# note\nname: \"text\"\ncount: 42\nenabled: true",
                        @{@"# note": comment, @"\"text\"": string, @"name": key, @"42": number,
                          @"true": keyword}),
        @"toml": sample(@"# note\n[server]\nname = \"text\"\nport = 42\nactive = true",
                        @{@"# note": comment, @"\"text\"": string, @"[server]": markup, @"name": key,
                          @"42": number, @"true": keyword}),
        @"swift": sample(@"let value = 42 // swift comment\nlet s = \"text\"",
                         @{@"// swift comment": comment, @"\"text\"": string, @"let": keyword, @"42": number}),
        @"python": sample(@"def value():\n    # python comment\n    return 42",
                          @{@"# python comment": comment, @"def": keyword, @"42": number}),
        @"javascript": sample(@"const value = 42; // js comment\nconst s = \"text\";",
                              @{@"// js comment": comment, @"\"text\"": string, @"const": keyword,
                                @"42": number}),
        @"json": sample(@"{\"value\": 42, \"ok\": true}",
                        @{@"\"value\"": key, @"42": number, @"true": keyword}),
        @"markdown": sample(@"## Heading\n**strong** and [link](target)",
                            @{@"##": markup, @"**": markup}),
        // Plain Text is the explicit "no highlighting" picker choice: its
        // scanner must emit zero tokens even for code-looking input.
        @"plain": sample(@"int value = 42; // would be tokens in C\n\"text\"", @{}),
    };
}

int main(void) {
    @autoreleasepool {
        SPDFMarkdownLanguageCatalog* catalog = SPDFMarkdownLanguageCatalog.sharedCatalog;
        NSDictionary<NSString*, NSDictionary*>* samples = SPDFLanguageSamples();
        SPDFExpect(catalog.languages.count == 31, @"the catalog advertises the mainstream languages plus Plain Text");
        SPDFExpect(catalog.languages.count == samples.count, @"every advertised language has a smoke sample");
        SPDFExpect([[catalog languageForFenceIdentifier:@"  JS extra"].identifier isEqualToString:@"javascript"],
                   @"aliases and fence info suffixes resolve");
        SPDFExpect([catalog languageForFenceIdentifier:@"made-up"] == nil, @"unknown fence stays unknown");

        // The picker relies on a stable, display-name-sorted catalog.
        NSMutableSet* identifiers = [NSMutableSet set];
        for (NSUInteger i = 0; i < catalog.languages.count; ++i) {
            SPDFMarkdownLanguage* language = catalog.languages[i];
            SPDFExpect(![identifiers containsObject:language.identifier], @"identifiers stay unique");
            [identifiers addObject:language.identifier];
            if (i > 0) {
                SPDFExpect([catalog.languages[i - 1].displayName
                               caseInsensitiveCompare:language.displayName] == NSOrderedAscending,
                           @"catalog stays sorted by display name for the picker");
            }
            SPDFExpect([catalog languageForFenceIdentifier:language.identifier] == language,
                       @"identifier resolves to its own catalog entry");
            for (NSString* alias in language.aliases) {
                SPDFExpect([catalog languageForFenceIdentifier:alias] == language,
                           [alias stringByAppendingString:@" alias resolves to its language"]);
            }
        }
        NSDictionary* aliasExpectations = @{
            @"c++": @"cpp", @"cc": @"cpp", @"h": @"c", @"objective-c": @"objc", @"mm": @"objc",
            @"cs": @"csharp", @"c#": @"csharp", @"kt": @"kotlin", @"golang": @"go", @"rs": @"rust",
            @"ts": @"typescript", @"tsx": @"typescript", @"rb": @"ruby", @"bash": @"shell",
            @"zsh": @"shell", @"console": @"shell", @"mysql": @"sql", @"postgres": @"sql",
            @"htm": @"html", @"svg": @"xml", @"plist": @"xml", @"scss": @"css", @"yml": @"yaml",
            @"ini": @"toml", @"tex": @"latex", @"hs": @"haskell", @"pl": @"perl",
            @"rscript": @"r", @"sbt": @"scala", @"py": @"python",
        };
        for (NSString* alias in aliasExpectations) {
            SPDFExpect([[catalog languageForFenceIdentifier:alias].identifier
                           isEqualToString:aliasExpectations[alias]],
                       [alias stringByAppendingString:@" fence alias resolves"]);
        }
        NSArray* scriptMatches = [[catalog languagesMatchingQuery:@"script"] valueForKey:@"identifier"];
        SPDFExpect([scriptMatches containsObject:@"javascript"] && [scriptMatches containsObject:@"typescript"],
                   @"language search matches display names");

        SPDFMarkdownHighlighter* highlighter = [SPDFMarkdownHighlighter new];
        for (SPDFMarkdownLanguage* language in catalog.languages) {
            NSDictionary* sample = samples[language.identifier];
            SPDFExpect(sample != nil, [language.identifier stringByAppendingString:@" has a sample"]);
            if (!sample) continue;
            NSString* code = sample[@"code"];
            NSArray* tokens = [highlighter tokensForCode:code language:language];
            if ([language.identifier isEqualToString:@"plain"]) {
                SPDFExpect(tokens.count == 0, @"Plain Text emits no tokens");
                continue;
            }
            SPDFExpect(tokens.count >= 2, [language.displayName stringByAppendingString:@" has a dedicated lexer"]);
            SPDFExpectNoOverlap(tokens, language.displayName);
            NSDictionary* expected = sample[@"expected"];
            for (NSString* fragment in expected) {
                SPDFExpectFragmentKind(tokens, code, fragment,
                                       (SPDFMarkdownSyntaxTokenKind)[expected[fragment] integerValue],
                                       [NSString stringWithFormat:@"%@ classifies %@", language.displayName,
                                                                  fragment]);
            }
        }

        NSArray<SPDFMarkdownSyntaxToken*>* pythonTokens =
            [highlighter tokensForCode:@"# comment\nvalue = 1"
                              language:[catalog languageForFenceIdentifier:@"python"]];
        NSArray<SPDFMarkdownSyntaxToken*>* jsTokens =
            [highlighter tokensForCode:@"# not-a-js-comment\nvalue = 1"
                              language:[catalog languageForFenceIdentifier:@"javascript"]];
        SPDFExpect(pythonTokens.firstObject.kind == SPDFMarkdownSyntaxTokenComment,
                   @"Python recognizes hash comments");
        SPDFExpect(jsTokens.firstObject.kind != SPDFMarkdownSyntaxTokenComment,
                   @"JavaScript does not borrow Python comment syntax");

        NSDictionary* stringCases = @{
            @"javascript": @"const url = \"https://example.com\";",
            @"swift": @"let url = \"https://example.com\"",
            @"python": @"value = '# not a comment'",
            @"ruby": @"value = \"# not a comment\"",
            @"sql": @"SELECT '-- not a comment' FROM t",
            @"c": @"const char* s = \"// not a comment\";",
        };
        NSDictionary* protectedFragments = @{
            @"javascript": @"\"https://example.com\"",
            @"swift": @"\"https://example.com\"",
            @"python": @"'# not a comment'",
            @"ruby": @"\"# not a comment\"",
            @"sql": @"'-- not a comment'",
            @"c": @"\"// not a comment\"",
        };
        for (NSString* identifier in stringCases) {
            NSString* source = stringCases[identifier];
            NSRange quote = [source rangeOfString:protectedFragments[identifier]];
            NSArray* tokens = [highlighter tokensForCode:source language:[catalog languageForFenceIdentifier:identifier]];
            SPDFMarkdownSyntaxToken* token = SPDFTokenCovering(tokens, quote);
            SPDFExpect(token.kind == SPDFMarkdownSyntaxTokenString,
                       [identifier stringByAppendingString:@" keeps comment markers inside strings"]);
        }
        NSString* JSONC = @"{\"a\": 1 // comment\n}";
        NSArray* JSONCTokens = [highlighter tokensForCode:JSONC language:[catalog languageForFenceIdentifier:@"jsonc"]];
        SPDFMarkdownSyntaxToken* JSONCComment = SPDFTokenCovering(JSONCTokens, [JSONC rangeOfString:@"// comment"]);
        SPDFExpect(JSONCComment.kind == SPDFMarkdownSyntaxTokenComment,
                   @"the advertised jsonc alias highlights comments without corrupting strings");
        NSString* arithmetic = @"let value = 1-2";
        NSArray* arithmeticTokens =
            [highlighter tokensForCode:arithmetic language:[catalog languageForFenceIdentifier:@"swift"]];
        NSRange minus = [arithmetic rangeOfString:@"-"];
        BOOL operatorCaptured = NO;
        for (SPDFMarkdownSyntaxToken* token in arithmeticTokens) {
            if (NSLocationInRange(minus.location, token.range)) operatorCaptured = YES;
        }
        SPDFExpect(!operatorCaptured, @"numeric tokens do not swallow arithmetic operators");

        SPDFMarkdownLanguagePickerModel* picker = [SPDFMarkdownLanguagePickerModel new];
        picker.query = @"s";
        SPDFExpect(picker.filteredLanguages.count > 1 && picker.selectedIndex == 0,
                   @"query filters and selects first row");
        [picker moveSelectionBy:1];
        SPDFExpect(picker.selectedIndex == 1, @"arrow navigation advances one row");
        [picker moveSelectionByPage:1 visibleRowCount:picker.filteredLanguages.count + 10];
        [picker moveSelectionBy:1];
        SPDFExpect(picker.selectedIndex == (NSInteger)picker.filteredLanguages.count - 1,
                   @"navigation clamps at last row");
        picker.query = @"no such language";
        SPDFExpect(picker.selectedLanguage == nil && picker.selectedIndex == -1,
                   @"empty result has no selection");
    }
    return SPDFFinishTests(@"SPDFMarkdownLanguageTests");
}
