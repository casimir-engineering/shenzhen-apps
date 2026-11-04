// A Markdown document sent to a friend with what belongs to it (portable/friends/mac/SZFriendsHost.h
// -friendsFilesForSending:, PROTOCOL.md § Intents, Documents).
//
// A Markdown file keeps its comments beside it in "<title> - comments.md" (SPDFMacMarkdownComments.h) and its
// pictures in files it names by relative path. Sent alone, the friend's copy has neither. So a send of a .md that has
// comments, or pictures or other files it links to below its folder, carries the document's archive in its place, a
// file object marked `document` whose display_name is still "Report.md":
//
//   Report.zip                         (in a scratch folder; the archive only carries them)
//     Report/Report.md
//     Report/Report - comments.md
//     Report/img/photo.png            (every path the document uses, as it uses it)
//
// Both chats show "Report.md" ("With comments and 1 picture"), and the friend's helper places the folder "Report"
// (or "Report (2)") where received files go, so the friend has a folder, never a .zip, and Open opens Report.md with
// its comments and pictures. A helper that does not know documents keeps "Report.zip" whole.
//
// Sending a comments file by itself, or anything that is not Markdown, is left alone. A file sent with its own
// revision (PROTOCOL.md § Intents, Files) is bundled only when its bytes are still that revision's; otherwise it goes
// as it is and the helper refuses it as before.
//
// ShenzhenPDF 26.11.3-2 sent the same archive as a plain "Report (with comments).zip". Open on such a .zip still
// unpacks it once beside itself and opens the document (SPDFMacFriendsOpenableMarkdownInBundle).

#import <Foundation/Foundation.h>
#import "SPDFMacFriendsRevision.h"

NS_ASSUME_NONNULL_BEGIN

// PROTOCOL.md file objects, each Markdown document with companions replaced by its archive (written to a new folder in
// `scratch`, where bundles older than a day are removed), and a comments file dropped when its document went in a
// bundle of the same send. A Collection version's copy (`lookup`) takes its companions from beside the document it is
// a version of. Main thread; reads the documents and copies their files.
NSArray<NSDictionary*>* SPDFMacFriendsFilesWithMarkdownBundles(NSArray<NSDictionary*>* files,
                                                               id<SPDFMacFriendsCollectionLookup> _Nullable lookup,
                                                               NSString* scratch);

// YES for a .zip that is such an archive (reads its directory only): one ShenzhenPDF 26.11.3-2 sent as it is.
BOOL SPDFMacFriendsIsMarkdownBundle(NSString* path);

// For Open on such a .zip from ShenzhenPDF 26.11.3-2: the Markdown document inside, unpacked beside the archive the
// first time and found there again afterwards; nil when the archive is not one (or cannot be unpacked).
NSString* _Nullable SPDFMacFriendsOpenableMarkdownInBundle(NSString* zipPath);

NS_ASSUME_NONNULL_END
