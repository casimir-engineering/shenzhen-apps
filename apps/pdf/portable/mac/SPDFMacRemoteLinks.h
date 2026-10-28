#pragma once
#import "SPDFMacDelegatePrivate.h"

// szpdf: links (docs/szpdf-links.md): a web page's link opens a PDF from its address in a tab of this window, and it
// shows page by page as it downloads.
//
// A link the browser hands the app goes through spdf_link_parse (core/spdf_link.h) before anything else; a refused
// one gets a short message and nothing is fetched. An accepted one is kept in the app's storage under Links/, so the
// same link comes back to the same tab, and a document that finished downloading opens from there, also offline.
// While it downloads (SPDFMacRemoteDownload) the tab opens as soon as the page asked for can be drawn, pages that
// have not arrived are blank placeholders, every new batch of bytes redraws whatever the viewport still lacks, and
// the bytes the viewport waits on are fetched first. A thin bar along the top of the page area shows how far the
// download is. When the last byte is in, the tab reloads into an ordinary document (outline, search, Collection).
//
// Nothing here runs at launch: the class only exists once a link arrives, or after the first paint when a tab of
// the restored session was still downloading when the app last quit.

@interface ShenzhenMacDelegate (SPDFMacRemoteLinks)
// The szpdf: links among `urls` (from -application:openURLs:), opened in order. Returns the URLs it did not take.
- (NSArray<NSURL*>*)openRemoteLinksAmongURLs:(NSArray<NSURL*>*)urls;
// Whether `path` is a linked document still downloading in this process.
- (BOOL)remoteLinkIsDownloadingPath:(NSString*)path;
@end
