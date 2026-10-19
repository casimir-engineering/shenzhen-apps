#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef SPDF_TEXT_DOCUMENT_FORMAT_TESTING
static NSUInteger SPDFSourceDocumentCatalogBuildCount = 0;
#endif

// Native source documents use the offline code-block lexers. Constant pairs
// make ordinary document-type checks allocation-free beyond path extraction;
// the collection and sorted extension list are built only when requested.
// SVG remains an image, and Markdown remains a rendered document.
typedef struct {
    __unsafe_unretained NSString* extension;
    __unsafe_unretained NSString* language;
} SPDFSourceFormatPair;
static const SPDFSourceFormatPair SPDFSourceFormatPairs[] = {
    {@"c", @"c"}, {@"h", @"c"}, {@"cs", @"csharp"},
    {@"csharp", @"csharp"}, {@"cpp", @"cpp"}, {@"cc", @"cpp"},
    {@"cxx", @"cpp"}, {@"hpp", @"cpp"}, {@"hxx", @"cpp"},
    {@"hh", @"cpp"}, {@"c++", @"cpp"}, {@"h++", @"cpp"},
    {@"css", @"css"}, {@"scss", @"css"}, {@"less", @"css"},
    {@"dart", @"dart"}, {@"go", @"go"}, {@"hs", @"haskell"},
    {@"haskell", @"haskell"}, {@"html", @"html"}, {@"htm", @"html"},
    {@"xhtml", @"html"}, {@"java", @"java"}, {@"js", @"javascript"},
    {@"jsx", @"javascript"}, {@"mjs", @"javascript"}, {@"cjs", @"javascript"},
    {@"javascript", @"javascript"}, {@"json", @"json"}, {@"jsonc", @"json"},
    {@"kt", @"kotlin"}, {@"kts", @"kotlin"}, {@"kotlin", @"kotlin"},
    {@"tex", @"latex"}, {@"sty", @"latex"}, {@"latex", @"latex"},
    {@"lua", @"lua"}, {@"m", @"objc"}, {@"mm", @"objc"},
    {@"objc", @"objc"}, {@"pl", @"perl"}, {@"pm", @"perl"},
    {@"perl", @"perl"}, {@"php", @"php"}, {@"phtml", @"php"},
    {@"txt", @"plain"}, {@"text", @"plain"}, {@"log", @"plain"},
    {@"plain", @"plain"}, {@"plaintext", @"plain"}, {@"csv", @"plain"},
    {@"tsv", @"plain"}, {@"py", @"python"}, {@"pyw", @"python"},
    {@"pyi", @"python"}, {@"python", @"python"}, {@"r", @"r"},
    {@"rscript", @"r"}, {@"rb", @"ruby"}, {@"ruby", @"ruby"},
    {@"gemspec", @"ruby"}, {@"rs", @"rust"}, {@"rust", @"rust"},
    {@"scala", @"scala"}, {@"sbt", @"scala"}, {@"sh", @"shell"},
    {@"bash", @"shell"}, {@"zsh", @"shell"}, {@"ksh", @"shell"},
    {@"shell", @"shell"}, {@"sql", @"sql"}, {@"swift", @"swift"},
    {@"toml", @"toml"}, {@"ini", @"toml"}, {@"ts", @"typescript"},
    {@"tsx", @"typescript"}, {@"mts", @"typescript"}, {@"cts", @"typescript"},
    {@"typescript", @"typescript"}, {@"xml", @"xml"}, {@"plist", @"xml"},
    {@"xsl", @"xml"}, {@"xslt", @"xml"}, {@"xsd", @"xml"},
    {@"rss", @"xml"}, {@"yaml", @"yaml"}, {@"yml", @"yaml"},
};

static inline NSDictionary<NSString*, NSString*>* SPDFSourceDocumentLanguageMap(void) {
    static NSDictionary* formats;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#ifdef SPDF_TEXT_DOCUMENT_FORMAT_TESTING
        ++SPDFSourceDocumentCatalogBuildCount;
#endif
        NSMutableDictionary* map = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < sizeof(SPDFSourceFormatPairs) / sizeof(SPDFSourceFormatPairs[0]); ++i)
            map[SPDFSourceFormatPairs[i].extension] = SPDFSourceFormatPairs[i].language;
        formats = [map copy];
    });
    return formats;
}

static inline NSArray<NSString*>* SPDFSourceDocumentExtensions(void) {
    static NSArray* extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ extensions = [SPDFSourceDocumentLanguageMap().allKeys sortedArrayUsingSelector:@selector(compare:)]; });
    return extensions;
}

static inline NSString* _Nullable SPDFSourceLanguageForPath(NSString* _Nullable path) {
    if (!path.length) return nil;
    NSString* extension = path.pathExtension.lowercaseString;
    for (NSUInteger i = 0; i < sizeof(SPDFSourceFormatPairs) / sizeof(SPDFSourceFormatPairs[0]); ++i)
        if ([extension isEqualToString:SPDFSourceFormatPairs[i].extension]) return SPDFSourceFormatPairs[i].language;
    return nil;
}

static inline BOOL SPDFIsSourceDocumentPath(NSString* _Nullable path) {
    return SPDFSourceLanguageForPath(path) != nil;
}

static inline BOOL SPDFIsRenderedTextDocumentPath(NSString* _Nullable path) {
    NSString* extension = path.pathExtension.lowercaseString;
    return [extension isEqualToString:@"md"] || [extension isEqualToString:@"markdown"] ||
        [extension isEqualToString:@"mdown"] || SPDFIsSourceDocumentPath(path);
}

NS_ASSUME_NONNULL_END
