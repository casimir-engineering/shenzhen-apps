#pragma once
// The Appearance page of ShenzhenPDF's Settings window: light or dark windows, and the palette tab groups are drawn
// in. Like the rest of the window it only reads the state the host passes (appearanceMode: system, light or dark;
// tabGroupPalette, the name in use; tabGroupPalettes, an array of {name, fills: chip colours as 0xRRGGBB numbers}) and
// reports a choice through settingsChanged as appearanceMode or tabGroupPalette. The reader applies them with
// spdf_appearance_mode_set() (SPDFMacAppearanceMode.h) and spdf_tab_group_set_palette() (SPDFMacTabGroups.h).
#import "SPDFMacUnifiedSettings.h"

@interface SPDFMacUnifiedSettingsController (SPDFMacAppearance)
- (void)buildAppearance;
// Redraws the palette popup from the state, after the host updated tabGroupPalettes or tabGroupPalette.
- (void)refreshAppearance;
@end
