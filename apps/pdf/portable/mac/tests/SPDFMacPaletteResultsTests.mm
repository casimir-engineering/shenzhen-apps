#import <Cocoa/Cocoa.h>

#import "../SPDFMacPaletteResults.h"

static int gFailureCount = 0;

static void expect_true(NSString* label, BOOL condition) {
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", label.UTF8String);
        ++gFailureCount;
    }
}

static void expect_equal_strings(NSString* label, NSString* actual, NSString* expected) {
    if (!(actual == expected || [actual isEqualToString:expected])) {
        fprintf(stderr, "FAIL %s: expected \"%s\", got \"%s\"\n", label.UTF8String, expected.UTF8String,
                actual.description.UTF8String);
        ++gFailureCount;
    }
}

static void expect_paths(NSString* label, NSArray<NSDictionary*>* results, NSArray<NSString*>* expectedPaths) {
    NSMutableArray<NSString*>* actual = [NSMutableArray array];
    for (NSDictionary* result in results) [actual addObject:result[@"path"] ?: @""];
    if (![actual isEqualToArray:expectedPaths]) {
        fprintf(stderr, "FAIL %s: expected %s, got %s\n", label.UTF8String, expectedPaths.description.UTF8String,
                actual.description.UTF8String);
        ++gFailureCount;
    }
}

static NSDictionary* open_candidate(NSString* path, NSString* title) {
    return @{@"path" : path, @"title" : title};
}

static NSDictionary* favorite_result(NSString* path, NSString* type) {
    return @{
        @"kind" : @"favorite",
        @"title" : path.lastPathComponent,
        @"path" : path,
        @"favorite" : @{@"type" : type, @"path" : path}
    };
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // --- spdf_palette_open_document_matches_query ---
        expect_true(@"empty query matches", spdf_palette_open_document_matches_query(@"", @"Title", @"/a/b.pdf"));
        expect_true(@"title substring matches case-insensitively",
                    spdf_palette_open_document_matches_query(@"hard", @"M100 Hardware Design", @"/a/b.pdf"));
        expect_true(@"file name matches when title does not",
                    spdf_palette_open_document_matches_query(@"acme", @"Datasheet (2)",
                                                             @"/docs/Acme_M100.pdf"));
        expect_true(@"diacritic-insensitive match",
                    spdf_palette_open_document_matches_query(@"resume", @"R\u00e9sum\u00e9", @"/a/r.pdf"));
        expect_true(@"non-matching query rejected",
                    !spdf_palette_open_document_matches_query(@"missing", @"Title", @"/a/b.pdf"));
        expect_true(@"directory names do not match",
                    !spdf_palette_open_document_matches_query(@"docs", @"Title", @"/docs/b.pdf"));

        // --- spdf_palette_open_document_results ---
        NSArray<NSDictionary*>* candidates = @[
            open_candidate(@"/docs/alpha.pdf", @"alpha"),
            open_candidate(@"/docs/beta.pdf", @"beta"),
            open_candidate(@"/other/alpha-two.pdf", @"alpha-two"),
        ];
        expect_paths(@"empty query returns all candidates in order",
                     spdf_palette_open_document_results(candidates, @""),
                     @[ @"/docs/alpha.pdf", @"/docs/beta.pdf", @"/other/alpha-two.pdf" ]);
        expect_paths(@"query filters by title/file name preserving order",
                     spdf_palette_open_document_results(candidates, @"alpha"),
                     @[ @"/docs/alpha.pdf", @"/other/alpha-two.pdf" ]);
        expect_paths(@"no matches yields empty", spdf_palette_open_document_results(candidates, @"gamma"), @[]);

        NSArray<NSDictionary*>* duplicated = @[
            open_candidate(@"/docs/alpha.pdf", @"alpha"),
            open_candidate(@"/docs/alpha.pdf", @"alpha"),
            open_candidate(@"/docs//alpha.pdf", @"alpha"),
        ];
        expect_paths(@"same document open twice is listed once",
                     spdf_palette_open_document_results(duplicated, @""), @[ @"/docs/alpha.pdf" ]);
        expect_paths(@"blank paths are skipped",
                     spdf_palette_open_document_results(@[ open_candidate(@"", @"ghost") ], @""), @[]);

        // --- spdf_palette_favorites_without_open_documents ---
        NSArray<NSDictionary*>* favorites = @[
            favorite_result(@"/docs/alpha.pdf", @"document"),
            favorite_result(@"/docs/alpha.pdf", @"page"),
            favorite_result(@"/docs/beta.pdf", @"document"),
        ];
        NSSet<NSString*>* open = [NSSet setWithObject:@"/docs/alpha.pdf"];
        expect_paths(@"document favorite deduped against open entry, page favorite kept",
                     spdf_palette_favorites_without_open_documents(favorites, open),
                     @[ @"/docs/alpha.pdf", @"/docs/beta.pdf" ]);
        NSArray<NSDictionary*>* deduped = spdf_palette_favorites_without_open_documents(favorites, open);
        expect_true(@"kept alpha favorite is the page-level one",
                    deduped.count > 0 && [deduped[0][@"favorite"][@"type"] isEqualToString:@"page"]);
        expect_paths(@"no open documents keeps all favorites",
                     spdf_palette_favorites_without_open_documents(favorites, [NSSet set]),
                     @[ @"/docs/alpha.pdf", @"/docs/alpha.pdf", @"/docs/beta.pdf" ]);

        // --- spdf_palette_query_reveals_all_favorites ---
        expect_true(@"'fav' reveals all favorites", spdf_palette_query_reveals_all_favorites(@"fav"));
        expect_true(@"'favo' reveals all favorites", spdf_palette_query_reveals_all_favorites(@"favo"));
        expect_true(@"'favorite' reveals all favorites", spdf_palette_query_reveals_all_favorites(@"favorite"));
        expect_true(@"'favorites' reveals all favorites", spdf_palette_query_reveals_all_favorites(@"favorites"));
        expect_true(@"keyword is case-insensitive", spdf_palette_query_reveals_all_favorites(@"FaV"));
        expect_true(@"keyword ignores surrounding whitespace",
                    spdf_palette_query_reveals_all_favorites(@" fav "));
        expect_true(@"two characters are not enough", !spdf_palette_query_reveals_all_favorites(@"fa"));
        expect_true(@"empty query is not the keyword", !spdf_palette_query_reveals_all_favorites(@""));
        expect_true(@"nil query is not the keyword", !spdf_palette_query_reveals_all_favorites(nil));
        expect_true(@"'fax' is not a prefix of favorites", !spdf_palette_query_reveals_all_favorites(@"fax"));
        expect_true(@"'favorite x' is not a prefix of favorites",
                    !spdf_palette_query_reveals_all_favorites(@"favorite x"));
        expect_true(@"'favoritess' overshoots the keyword",
                    !spdf_palette_query_reveals_all_favorites(@"favoritess"));

        // --- spdf_palette_key_equivalent_display_string ---
        expect_equal_strings(@"plain command shortcut",
                             spdf_palette_key_equivalent_display_string(@"k", NSEventModifierFlagCommand),
                             @"\u2318K");
        expect_equal_strings(@"shift+command shortcut",
                             spdf_palette_key_equivalent_display_string(
                                 @"f", NSEventModifierFlagCommand | NSEventModifierFlagShift),
                             @"\u21E7\u2318F");
        expect_equal_strings(@"control+command shortcut",
                             spdf_palette_key_equivalent_display_string(
                                 @"f", NSEventModifierFlagCommand | NSEventModifierFlagControl),
                             @"\u2303\u2318F");
        expect_equal_strings(@"uppercase key equivalent implies shift",
                             spdf_palette_key_equivalent_display_string(@"G", NSEventModifierFlagCommand),
                             @"\u21E7\u2318G");
        expect_equal_strings(@"function key without modifiers",
                             spdf_palette_key_equivalent_display_string(
                                 [NSString stringWithFormat:@"%C", static_cast<unichar>(NSF5FunctionKey)], 0),
                             @"F5");
        expect_equal_strings(@"option+arrow shortcut",
                             spdf_palette_key_equivalent_display_string(
                                 [NSString stringWithFormat:@"%C", static_cast<unichar>(NSUpArrowFunctionKey)],
                                 NSEventModifierFlagOption),
                             @"\u2325\u2191");
        expect_equal_strings(@"punctuation key equivalent",
                             spdf_palette_key_equivalent_display_string(@",", NSEventModifierFlagCommand),
                             @"\u2318,");
        expect_equal_strings(@"no key equivalent yields empty string",
                             spdf_palette_key_equivalent_display_string(@"", NSEventModifierFlagCommand), @"");
        expect_equal_strings(@"nil key equivalent yields empty string",
                             spdf_palette_key_equivalent_display_string(nil, NSEventModifierFlagCommand), @"");

        // --- spdf_palette_menu_breadcrumb ---
        expect_equal_strings(@"breadcrumb joins menu path and title",
                             spdf_palette_menu_breadcrumb(@[ @"View" ], @"Document Map"),
                             @"View \u25B8 Document Map");
        expect_equal_strings(@"breadcrumb includes nested submenus",
                             spdf_palette_menu_breadcrumb(@[ @"File", @"Recently Opened" ], @"report.pdf"),
                             @"File \u25B8 Recently Opened \u25B8 report.pdf");
        expect_equal_strings(@"breadcrumb skips empty components",
                             spdf_palette_menu_breadcrumb(@[ @"", @"File" ], @"Open..."), @"File \u25B8 Open...");
        expect_equal_strings(@"breadcrumb with no menus is just the title",
                             spdf_palette_menu_breadcrumb(@[], @"Open..."), @"Open...");

        // --- spdf_palette_menu_command_matches_query ---
        expect_true(@"empty query matches every menu command",
                    spdf_palette_menu_command_matches_query(@"", @"Open...", @"File \u25B8 Open..."));
        expect_true(@"menu command title matches case-insensitively",
                    spdf_palette_menu_command_matches_query(@"minimap", @"Show Minimap", @"View \u25B8 Show Minimap"));
        expect_true(@"breadcrumb words match too",
                    spdf_palette_menu_command_matches_query(@"view", @"Show Minimap", @"View \u25B8 Show Minimap"));
        expect_true(@"diacritic-insensitive menu match",
                    spdf_palette_menu_command_matches_query(@"resume", @"R\u00e9sum\u00e9 Export", @""));
        expect_true(@"unrelated query does not match",
                    !spdf_palette_menu_command_matches_query(@"zoom", @"Show Minimap", @"View \u25B8 Show Minimap"));

        // --- spdf_palette_menu_commands_excluding_selectors ---
        NSArray<NSDictionary*>* menuCommands = @[
            @{@"title" : @"Favorite Current Page", @"selector" : @"favoriteCurrentPage:"},
            @{@"title" : @"Zoom In", @"selector" : @"zoomIn:"},
        ];
        NSArray<NSDictionary*>* kept = spdf_palette_menu_commands_excluding_selectors(
            menuCommands, [NSSet setWithObject:@"favoriteCurrentPage:"]);
        expect_true(@"curated selector removes the matching menu command",
                    kept.count == 1 && [kept[0][@"selector"] isEqualToString:@"zoomIn:"]);
        expect_true(@"empty exclusion set keeps all menu commands",
                    spdf_palette_menu_commands_excluding_selectors(menuCommands, [NSSet set]).count == 2);
        expect_true(@"nil menu commands yield empty array",
                    spdf_palette_menu_commands_excluding_selectors(nil, [NSSet setWithObject:@"x:"]).count == 0);
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFMacPaletteResultsTests passed\n");
    return 0;
}
