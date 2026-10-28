#pragma once
// Light, Dark or Follow system (the default) for every window and panel of the reader, chosen in Settings ›
// Appearance. Document pages keep their own reading theme. Saved in appearance.yaml in the reader's state, beside the
// tab group colours, as `appearanceMode: light` or `dark` (no line: follow the system). Applied as the app finishes
// launching, before its first window, and in every running window of the reader (each its own process) the moment it
// is chosen.
#import <Foundation/Foundation.h>

// @"system", @"light" or @"dark".
NSString* spdf_appearance_mode(void);
// Saves and applies the choice everywhere. NO for an unknown mode, or when it could not be saved (it still applies
// until the reader quits).
BOOL spdf_appearance_mode_set(NSString* mode);
