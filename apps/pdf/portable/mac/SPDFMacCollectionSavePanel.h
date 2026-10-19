#import <Cocoa/Cocoa.h>
// Retains its validation delegate for the panel's lifetime. Export can only
// create a new file, so choosing an existing destination keeps the picker open.
void SPDFCollectionConfigureSavePanel(NSSavePanel* panel, NSString* sourceName);
