#pragma once
// The Settings window's buttons (SPDFMacUnifiedSettings.mm), moved out of it to keep that file within its size cap.
#import "SPDFMacGroupActionButton.h"

// Reuse the reader's full-bounds, first-click tracking. Native cell drawing is
// intentionally replaced only for appearance, not by another tracking mechanism.
@interface SPDFSettingsButton : SPDFGroupActionButton
@end
