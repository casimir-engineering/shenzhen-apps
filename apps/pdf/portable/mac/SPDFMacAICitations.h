#pragma once
#import <Foundation/Foundation.h>
// A clickable document citation must have been issued by a tool in this chat.
NSDictionary* SPDFMacAICitationArguments(NSURL* URL);
BOOL SPDFMacAIChatContainsCitation(NSDictionary* chat, NSDictionary* arguments);
// Drop an invented highlight only when the exact page/revision has a retrieved page citation.
NSDictionary* SPDFMacAIResolveCitation(NSDictionary* chat, NSDictionary* arguments);
NSString* SPDFMacAIRepairCitationLinks(NSString* text, NSDictionary* chat);
// Any chat link that names a document, verified or not: spdf-ai://document with a
// document ID (doc:, collection:) or a file name, and an optional one-based page.
// Opening it shows the document (and page) but never highlights an unverified passage.
NSDictionary* SPDFMacAIDocumentLinkArguments(NSURL* URL);
// A bare file name written as a link target ("Report.pdf", "budget.numbers", "main.py"), turned into a
// document link. A name ending in a top-level domain the reader does not open ("example.com") is nil.
// A bare name whose extension is also a domain ("allegro.pl", "foo.sh") carries the site as "web",
// offered to the reader when no document of that name is found.
NSURL* SPDFMacAIDocumentNameLink(NSString* destination);
// A bare site name ("example.com", "notes.app") may also be the name of a document: a document
// link that carries the site (https) and opens it when no document of exactly that name is known.
// Paths and "www." names stay plain site links.
NSURL* SPDFMacAIDocumentOrSiteLink(NSString* destination, NSURL* site);
// Which document a link names: @{@"path"} for an open tab or another known file,
// @{@"collection"} for a Collection row, nil when nothing matches. `identify` maps a
// file path to its doc: ID. A doc: ID matches exactly (SPDFMacAIDocumentIndex), never by name.
NSDictionary* SPDFMacAIResolveDocumentLink(NSDictionary* link, NSArray<NSString*>* openPaths,
    NSArray<NSString*>* recentPaths, NSArray<NSDictionary*>* collection, NSString* (^identify)(NSString* path));
// Every document a doc: ID can name, keyed by that ID. An ID is the hash of the exact path the assistant read the
// document at (SPDFAIDocumentIdentifier), and that path changes: a tab showing a saved revision from History reads
// an editable copy inside Collection, and the tab may later close or show the source again. So the index holds open
// tabs first, then each Collection row's source, earlier names (`aliases`) and editable copies (`editablePaths`, the
// copies that exist), then `knownPaths`: other files the assistant read that still exist. Values are
// SPDFMacAIResolveDocumentLink's targets. Callers pass only rows that can be opened.
NSDictionary<NSString*, NSDictionary*>* SPDFMacAIDocumentIndex(NSArray<NSString*>* openPaths,
    NSArray<NSString*>* knownPaths, NSArray<NSDictionary*>* collection, NSString* (^identify)(NSString* path));
// An answer as the chat shows it. A document link that `available` says cannot be opened becomes its plain words,
// so an answer never shows a link that leads nowhere; punctuation typed inside a link's parentheses moves after it.
// `source` is the card under the answer when one document clearly backs it: the only document it cites, or the one
// its last line names as "Main source: [Title · p. N](link)" (that line then leaves the text). @{@"text"} plus
// @{@"source": @{@"link": NSURL, @"title", @"page"}}.
NSDictionary* SPDFMacAIAnswerPresentation(NSString* text, BOOL (^available)(NSURL* link));
