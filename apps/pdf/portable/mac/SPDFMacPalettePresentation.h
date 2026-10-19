#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacPalettePresentation)
- (NSView*)workspacePaletteViewForRow:(NSInteger)row;
- (void)showPaletteWithTitle:(NSString*)title;
- (CGFloat)paletteHeightForRow:(NSInteger)row;
- (CGFloat)paletteRowsHeight;
- (void)updatePalettePanelFramePreservingTop:(BOOL)preserveTop;
- (BOOL)isSelectablePaletteResult:(NSDictionary*)result;
- (void)scrollPaletteRowToVisibleWithHeader:(NSInteger)row;
- (void)selectFirstPaletteResult;
- (void)restorePaletteSelectionAfterReloadFromRow:(NSInteger)row;
@end
@interface ShenzhenMacDelegate (SPDFMacPalettePresentationHost)
- (NSArray*)paletteMenuCommandCandidates;
- (void)installPaletteEventMonitor;
- (void)closePalette:(id)sender;
- (void)activatePaletteSelection:(id)sender;
- (void)paletteFavoriteDeleteClicked:(id)sender;
@end
