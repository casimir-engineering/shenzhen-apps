#pragma once
// The Appearance page of ShenzhenPDF's Settings window: the palette tab groups are drawn in. Like the rest of the
// window it only reads the state the host passes (tabGroupPalette, the name in use; tabGroupPalettes, an array of
// {name, fills: chip colours as 0xRRGGBB numbers}) and reports a choice through settingsChanged as tabGroupPalette.
// The reader applies it with spdf_tab_group_set_palette() (SPDFMacTabGroups.h).
#import "SPDFMacUnifiedSettings.h"

@interface SPDFMacUnifiedSettingsController (SPDFMacAppearance)
- (void)buildAppearance;
@end
