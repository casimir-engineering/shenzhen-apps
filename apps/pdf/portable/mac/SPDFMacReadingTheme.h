#import <Cocoa/Cocoa.h>

// The two View-menu rows that drive the reading theme, installed together
// because they are one control split in two: Cmd+I inverts the page, and
// Cmd+Shift+I decides whether the pictures on it invert with it.
//
// The second row lived in Settings, which read as a preference; it is a
// per-document view choice, remembered per file; Settings has a separate default.
// The document command belongs beside the
// inversion it modifies. Windows already had it on its View menu.
//
// Both equivalents are the letter I, and the shifted one is spelled with a
// CAPITAL I and the command mask alone. Three menu items now share that letter
// -- Opt+I opens Properties -- and a lowercase "i" with an explicit shift flag
// was matched by none of them: the keystroke reached the app and fired nothing.
void SPDFMacInstallReadingThemeMenuItems(NSMenu* viewMenu, id target);
