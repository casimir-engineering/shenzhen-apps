#import "SPDFMacCollectionIntegration.h"

@interface ShenzhenMacDelegate (SPDFMacCollectionPaletteHost)
- (void)focusOpenDocumentTabForPath:(NSString*)path;
- (NSArray<NSDictionary*>*)openDocumentPaletteCandidates;
- (NSString*)shortProvenanceForPath:(NSString*)path;
- (NSString*)pathForStateFile:(NSString*)name;
- (void)selectFirstPaletteResult;
- (void)scrollPaletteRowToVisibleWithHeader:(NSInteger)row;
- (void)updatePalettePanelFramePreservingTop:(BOOL)preserve;
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve;
@end

@interface ShenzhenMacDelegate (SPDFMacCollectionPalette)
- (NSArray*)favoriteResultsForQuery:(NSString*)query prefix:(NSString*)prefix;
// One open tab as an open-document candidate: path, a readable title, viewing
// time, group, and the Collection identity that lets a working copy fold into
// its original.
- (NSDictionary*)paletteCandidateForTab:(SPDFDocumentTab*)tab;
- (NSArray*)collectionPaletteSupplementaryRowsForQuery:(NSString*)query excludingOpenPaths:(NSSet*)paths;
- (void)refreshPaletteResults;
- (void)cancelCollectionPaletteSearch;
- (BOOL)openCollectionPaletteResult:(NSDictionary*)result;
- (void)collectionNavigateResult:(NSDictionary*)result path:(NSString*)path attempts:(NSInteger)attempts;
@end
