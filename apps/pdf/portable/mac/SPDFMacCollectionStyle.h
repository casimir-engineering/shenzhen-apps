#pragma once
#import <Cocoa/Cocoa.h>
// Collection chrome only. These appearance-aware colors never enter document rendering.
NSColor* SPDFCollectionColor(NSString* token);
NSButton* SPDFCollectionButton(NSString* title, id target, SEL action, NSString* kind);
NSPopUpButton* SPDFCollectionPopUp(void);
NSSearchField* SPDFCollectionSearchField(void);
void SPDFCollectionConfigureSearchField(NSSearchField* field);
NSTextField* SPDFCollectionText(NSString* text, CGFloat size, NSFontWeight weight, BOOL secondary);
NSView* SPDFCollectionSurface(NSString* token);
NSView* SPDFCollectionDivider(void);

// Current identity comes from the document, never the visible/filtered row order.
BOOL SPDFCollectionVersionIsLatest(NSDictionary* document, NSDictionary* version);
NSView* SPDFCollectionLatestBadge(void);
NSView* SPDFCollectionLatestCopyBadge(void);
