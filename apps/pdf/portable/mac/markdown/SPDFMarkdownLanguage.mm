#import "SPDFMarkdownLanguage.h"

@implementation SPDFMarkdownLanguage
- (instancetype)initWithIdentifier:(NSString*)identifier
                       displayName:(NSString*)displayName
                           aliases:(NSArray<NSString*>*)aliases {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _displayName = [displayName copy];
        _aliases = [aliases copy];
    }
    return self;
}
@end

static SPDFMarkdownLanguage* SPDFLanguage(NSString* identifier, NSString* name, NSArray* aliases) {
    return [[SPDFMarkdownLanguage alloc] initWithIdentifier:identifier displayName:name aliases:aliases];
}

@implementation SPDFMarkdownLanguageCatalog {
    NSDictionary<NSString*, SPDFMarkdownLanguage*>* _byIdentifier;
}

+ (instancetype)sharedCatalog {
    static SPDFMarkdownLanguageCatalog* catalog;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ catalog = [SPDFMarkdownLanguageCatalog new]; });
    return catalog;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    // Each advertised entry has a dedicated offline lexer (or a parameterized
    // grammar instance of one). Kept sorted by display name for the picker.
    _languages = @[
        SPDFLanguage(@"c", @"C", @[@"h"]),
        SPDFLanguage(@"csharp", @"C#", @[@"cs", @"c#"]),
        SPDFLanguage(@"cpp", @"C++", @[@"c++", @"cc", @"cxx", @"hpp", @"hxx", @"hh"]),
        SPDFLanguage(@"css", @"CSS", @[@"scss", @"less"]),
        SPDFLanguage(@"dart", @"Dart", @[]),
        SPDFLanguage(@"go", @"Go", @[@"golang"]),
        SPDFLanguage(@"haskell", @"Haskell", @[@"hs"]),
        SPDFLanguage(@"html", @"HTML", @[@"htm", @"xhtml"]),
        SPDFLanguage(@"java", @"Java", @[]),
        SPDFLanguage(@"javascript", @"JavaScript", @[@"js", @"jsx", @"mjs"]),
        SPDFLanguage(@"json", @"JSON", @[@"jsonc"]),
        SPDFLanguage(@"kotlin", @"Kotlin", @[@"kt", @"kts"]),
        SPDFLanguage(@"latex", @"LaTeX", @[@"tex", @"sty"]),
        SPDFLanguage(@"lua", @"Lua", @[]),
        SPDFLanguage(@"markdown", @"Markdown", @[@"md"]),
        SPDFLanguage(@"objc", @"Objective-C", @[@"objective-c", @"objectivec", @"m", @"mm"]),
        SPDFLanguage(@"perl", @"Perl", @[@"pl", @"pm"]),
        SPDFLanguage(@"php", @"PHP", @[]),
        // Selecting Plain Text clears highlighting: its scanner emits no tokens.
        SPDFLanguage(@"plain", @"Plain Text", @[ @"text", @"txt", @"plaintext", @"plain-text", @"none" ]),
        SPDFLanguage(@"python", @"Python", @[@"py"]),
        SPDFLanguage(@"r", @"R", @[@"rscript"]),
        SPDFLanguage(@"ruby", @"Ruby", @[@"rb"]),
        SPDFLanguage(@"rust", @"Rust", @[@"rs"]),
        SPDFLanguage(@"scala", @"Scala", @[@"sbt"]),
        SPDFLanguage(@"shell", @"Shell", @[@"sh", @"bash", @"zsh", @"ksh", @"console", @"shellsession"]),
        SPDFLanguage(@"sql", @"SQL", @[@"mysql", @"postgres", @"postgresql", @"sqlite", @"tsql", @"plsql"]),
        SPDFLanguage(@"swift", @"Swift", @[]),
        SPDFLanguage(@"toml", @"TOML", @[@"ini"]),
        SPDFLanguage(@"typescript", @"TypeScript", @[@"ts", @"tsx", @"mts", @"cts"]),
        SPDFLanguage(@"xml", @"XML", @[@"svg", @"plist", @"xsl", @"xsd", @"rss"]),
        SPDFLanguage(@"yaml", @"YAML", @[@"yml"]),
    ];
    NSMutableDictionary* aliases = [NSMutableDictionary dictionary];
    for (SPDFMarkdownLanguage* language in _languages) {
        aliases[language.identifier] = language;
        for (NSString* alias in language.aliases) aliases[alias.lowercaseString] = language;
    }
    _byIdentifier = [aliases copy];
    return self;
}

- (SPDFMarkdownLanguage*)languageForFenceIdentifier:(NSString*)identifier {
    NSString* token = [[[identifier ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] firstObject];
    return _byIdentifier[token.lowercaseString];
}

- (NSArray<SPDFMarkdownLanguage*>*)languagesMatchingQuery:(NSString*)query {
    NSString* needle = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (needle.length == 0) return self.languages;
    NSPredicate* predicate = [NSPredicate predicateWithBlock:^BOOL(SPDFMarkdownLanguage* language, NSDictionary* _) {
        if ([language.identifier localizedCaseInsensitiveContainsString:needle] ||
            [language.displayName localizedCaseInsensitiveContainsString:needle]) return YES;
        for (NSString* alias in language.aliases)
            if ([alias localizedCaseInsensitiveContainsString:needle]) return YES;
        return NO;
    }];
    return [self.languages filteredArrayUsingPredicate:predicate];
}
@end

@implementation SPDFMarkdownLanguagePickerModel {
    NSArray<SPDFMarkdownLanguage*>* _filteredLanguages;
}
- (instancetype)init { return [self initWithCatalog:SPDFMarkdownLanguageCatalog.sharedCatalog]; }
- (instancetype)initWithCatalog:(SPDFMarkdownLanguageCatalog*)catalog {
    self = [super init];
    if (self) {
        _catalog = catalog;
        _query = @"";
        _filteredLanguages = catalog.languages;
        _selectedIndex = _filteredLanguages.count ? 0 : -1;
    }
    return self;
}
- (NSArray<SPDFMarkdownLanguage*>*)filteredLanguages { return _filteredLanguages; }
- (void)setQuery:(NSString*)query {
    _query = [query copy];
    _filteredLanguages = [self.catalog languagesMatchingQuery:_query];
    _selectedIndex = _filteredLanguages.count ? 0 : -1;
}
- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = _filteredLanguages.count ? MAX(0, MIN(selectedIndex, (NSInteger)_filteredLanguages.count - 1)) : -1;
}
- (SPDFMarkdownLanguage*)selectedLanguage {
    return _selectedIndex >= 0 && _selectedIndex < (NSInteger)_filteredLanguages.count
        ? _filteredLanguages[(NSUInteger)_selectedIndex] : nil;
}
- (void)moveSelectionBy:(NSInteger)delta { self.selectedIndex += delta; }
- (void)moveSelectionByPage:(NSInteger)direction visibleRowCount:(NSUInteger)visibleRowCount {
    [self moveSelectionBy:direction * (NSInteger)MAX((NSUInteger)1, visibleRowCount)];
}
- (void)selectFirst { self.selectedIndex = 0; }
- (void)selectLast { self.selectedIndex = (NSInteger)_filteredLanguages.count - 1; }
@end
