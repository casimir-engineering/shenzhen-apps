#pragma once
#import "SPDFMacDelegatePrivate.h"

// Links in assistant answers that name a document. A link always opens what it
// names when that document can be found: its tab comes forward (as for any open),
// at the linked page when there is one. Passages are highlighted only through the
// verified citation path in SPDFMacAIIntegration.
// The "Can't find this document" alert; with a site it has a second button that opens it.
NSAlert* SPDFMacAIMissingDocumentAlert(NSURL* site);

@interface ShenzhenMacDelegate (SPDFMacAIDocumentLinks)
// The open tab a link names, or nil.
- (NSString*)aiOpenTabPathForDocumentLink:(NSDictionary*)link;
// NO when the named document cannot be found; the caller then tells the reader.
- (BOOL)aiOpenDocumentLink:(NSDictionary*)link;
- (void)aiShowMissingDocumentLink;
// The same, offering to open `site` instead when the link may have meant a website.
- (void)aiShowMissingDocumentLinkOfferingSite:(NSURL*)site;
- (void)aiFinishMissingDocumentAlert:(NSModalResponse)response site:(NSURL*)site;
// Opens a web page from an answer in the browser.
- (void)aiOpenWebLink:(NSURL*)URL;
@end
