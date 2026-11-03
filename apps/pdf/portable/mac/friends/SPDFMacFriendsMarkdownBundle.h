// A Markdown document sent to a friend with what belongs to it (portable/friends/mac/SZFriendsHost.h
// -friendsFilesForSending:).
//
// A Markdown file keeps its comments beside it in "<title> - comments.md" (SPDFMacMarkdownComments.h) and its
// pictures in files it names by relative path. Sent alone, the friend's copy has neither. So a send of a .md that has
// comments, or pictures or other files it links to below its folder, carries one .zip in its place:
//
//   Report (with comments).zip        ("Report.zip" when there are no comments, only pictures)
//     Report/Report.md
//     Report/Report - comments.md
//     Report/img/photo.png            (every path the document uses, as it uses it)
//
// One file, so the chat shows one item, every app and every older ShenzhenPDF receives it as it is, and Finder,
// Shenzhen Files and phones open it into a "Report" folder where the pairing and the paths hold. ShenzhenPDF opens it
// in place: Open unpacks it once beside the .zip (into "Report", or "Report (2)" when that name is taken) and opens
// Report.md, with its comments and pictures. The helper and the protocol are unchanged.
//
// Sending a comments file by itself, or anything that is not Markdown, is left alone. A file sent with its own
// revision (PROTOCOL.md § Intents, Files) is bundled only when its bytes are still that revision's; otherwise it goes
// as it is and the helper refuses it as before.

#import <Foundation/Foundation.h>
#import "SPDFMacFriendsRevision.h"

NS_ASSUME_NONNULL_BEGIN

// PROTOCOL.md file objects, each Markdown document with companions replaced by its .zip (written to a new folder in
// `scratch`, where bundles older than a day are removed), and a comments file dropped when its document went in a
// bundle of the same send. A Collection version's copy (`lookup`) takes its companions from beside the document it is
// a version of. Main thread; reads the documents and copies their files.
NSArray<NSDictionary*>* SPDFMacFriendsFilesWithMarkdownBundles(NSArray<NSDictionary*>* files,
                                                               id<SPDFMacFriendsCollectionLookup> _Nullable lookup,
                                                               NSString* scratch);

// YES for a .zip that is such a bundle (reads its directory only).
BOOL SPDFMacFriendsIsMarkdownBundle(NSString* path);

// For Open on a received .zip: the Markdown document inside, unpacked beside the archive the first time and found
// there again afterwards; nil when the archive is not one of these bundles (or cannot be unpacked).
NSString* _Nullable SPDFMacFriendsOpenableMarkdownInBundle(NSString* zipPath);

NS_ASSUME_NONNULL_END
