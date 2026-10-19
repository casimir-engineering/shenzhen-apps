#import <Cocoa/Cocoa.h>

NSArray<NSDictionary*>* SPDFShortcutHelpCatalog(void);
NSArray<NSDictionary*>* SPDFShortcutHelpRows(NSString* query);
CGFloat SPDFShortcutHelpRowHeight(NSDictionary* row);
NSView* SPDFShortcutHelpRowView(NSDictionary* row);
NSView* SPDFShortcutHelpKeycaps(NSArray<NSString*>* keys);
NSView* SPDFShortcutHelpSurface(NSRect frame);
