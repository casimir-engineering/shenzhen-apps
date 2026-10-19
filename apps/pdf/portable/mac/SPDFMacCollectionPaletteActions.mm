#import "SPDFMacCollectionPalette.h"
#import "SPDFMacPaletteResults.h"
#import "SPDFMacSupport.h"
@implementation ShenzhenMacDelegate (SPDFMacCollectionPaletteActions)
- (NSArray*)collectionPaletteSupplementaryRowsForQuery:(NSString*)query excludingOpenPaths:(NSSet*)openShownPaths {
    NSMutableArray* rows = [NSMutableArray array];
    // "fav" (any >= 3 character prefix of "favorites") is a browse keyword:
    // reveal every favorite, bypassing title matching and the open-document
    // dedupe so the group is complete rather than filtered by the keyword.
    BOOL revealAllFavorites = spdf_palette_query_reveals_all_favorites(query);
    NSArray<NSDictionary*>* favorites = [self favoriteResultsForQuery:revealAllFavorites ? @"" : query prefix:@""];
    if (!revealAllFavorites) favorites = spdf_palette_favorites_without_open_documents(favorites, openShownPaths);
    if (favorites.count > 0) {
        [rows addObject:@{@"kind" : @"header", @"title" : @"Favorites", @"subtitle" : @""}];
        [rows addObjectsFromArray:favorites];
    }

    // Actions: the curated favorite-current shortcuts plus every menu-bar
    // command captured when the palette opened. A curated action wins over
    // the menu item with the same selector (it carries the live document
    // name), so the two never show as duplicate rows.
    NSMutableArray<NSDictionary*>* actionRows = [NSMutableArray array];
    NSMutableSet<NSString*>* curatedSelectors = [NSMutableSet set];
    if (_doc && _path.length) {
        NSString* displayName = spdf_display_name_for_path(_path);
        if (spdf_palette_menu_command_matches_query(query, @"Favorite current page", @"")) {
            [actionRows addObject:@{
                @"kind" : @"addPage",
                @"title" : @"Favorite current page",
                @"subtitle" : displayName ?: @""
            }];
            [curatedSelectors addObject:NSStringFromSelector(@selector(favoriteCurrentPage:))];
        }
        if (spdf_palette_menu_command_matches_query(query, @"Favorite current document", @"")) {
            [actionRows addObject:@{
                @"kind" : @"addDoc",
                @"title" : @"Favorite current document",
                @"subtitle" : displayName ?: @""
            }];
            [curatedSelectors addObject:NSStringFromSelector(@selector(favoriteCurrentDocument:))];
        }
    }
    NSMutableArray<NSDictionary*>* menuCommands = [NSMutableArray array];
    for (NSDictionary* command in _paletteMenuCommandCandidates ?: @[]) {
        if (spdf_palette_menu_command_matches_query(query, command[@"title"], command[@"breadcrumb"]))
            [menuCommands addObject:command];
    }
    [actionRows addObjectsFromArray:spdf_palette_menu_commands_excluding_selectors(menuCommands, curatedSelectors)];
    if (actionRows.count > 0) {
        [rows addObject:@{@"kind" : @"header", @"title" : @"Actions", @"subtitle" : @""}];
        [rows addObjectsFromArray:actionRows];
    }

    return rows;
}
@end
