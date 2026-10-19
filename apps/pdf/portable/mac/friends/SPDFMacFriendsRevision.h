// Exact revisions for files ShenzhenPDF offers to Friends: a dragged tab, a `#` item.
//
// PROTOCOL.md § Intents, Files: an attachment may carry a `revision` (source, document_id, revision_id, label,
// sha256, size). The helper snapshots the file on receipt and refuses it with source_changed when the bytes no
// longer match, so a newer file is never sent in place of the one the person chose. Here the reader decides which
// bytes those are: a Collection version when Collection holds exactly these bytes, otherwise the file's own
// identity with its digest. Collection is reached only through SPDFMacFriendsCollectionLookup, so the logic is
// testable without the store and the store is never consulted while Collection is off.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsRevisionSourceCollection; // "com.intuition.shenzhenpdf"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsRevisionSourceFile;       // "file"
// Hashing bounds. A drop resolves on the main thread, so it hashes at most 64 MiB (about 30 ms on Apple silicon);
// the `#` picker resolves on a background queue and hashes up to 1 GiB. Larger files bind size and file identity
// only, and the helper's own snapshot then fixes the bytes at the moment of sending.
FOUNDATION_EXPORT const unsigned long long SPDFMacFriendsMainThreadHashLimit;
FOUNDATION_EXPORT const unsigned long long SPDFMacFriendsBackgroundHashLimit;

// What the adapter needs from Collection, in SPDFMacCollectionStore's own row shapes (SPDFMacCollectionStore.h:
// documents have id, path, title, latestVersionID; versions have id, hash, size, capturedAt).
@protocol SPDFMacFriendsCollectionLookup <NSObject>
// NO while Collection is off: nothing else is called then.
@property(nonatomic, readonly) BOOL friendsCollectionEnabled;
// @{"document":..., "version":...} for a file inside Collection's archive (-archiveInfoForPath:), or nil.
- (nullable NSDictionary*)friendsArchiveInfoForPath:(NSString*)path;
- (nullable NSDictionary*)friendsDocumentForPath:(NSString*)path;
- (NSArray<NSDictionary*>*)friendsVersionsForDocumentID:(NSString*)documentID;
- (NSArray<NSDictionary*>*)friendsDocuments;
// A readable file holding exactly that version's bytes (an existing archive preview, or a new one).
- (nullable NSURL*)friendsFileForVersionID:(NSString*)versionID documentID:(NSString*)documentID;
@end

// SHA-256 (lowercase hex) of a regular file, read in 1 MiB chunks. *size receives its size whenever the file is a
// readable regular file, even when it is over `limit` and nil is returned. Results are cached by path, device,
// inode, size and modification time, so the picker's repeated queries hash each file once.
NSString* _Nullable SPDFMacFriendsFileSHA256(NSString* path, unsigned long long limit,
                                             unsigned long long* _Nullable size);

// "version saved today, 14:02" / "version saved yesterday, 09:10" / "version saved 3 Oct, 09:12" /
// "version saved 3 Oct 2025": the label the person sees beside an attachment (PROTOCOL.md fixtures use it).
NSString* SPDFMacFriendsVersionLabel(NSDate* captured, NSDate* now, NSCalendar* calendar, NSLocale* locale);

// A Collection version's revision object (sha256 and size come from Collection; nothing is read).
NSDictionary* SPDFMacFriendsCollectionRevision(NSDictionary* document, NSDictionary* version, NSString* label);

// The revision of the bytes at `path` right now: the Collection version with this exact digest when there is one,
// otherwise source "file" with document_id from the file's device and inode and revision_id from its digest.
// nil when the file is unreadable, not a regular file, or a folder.
NSDictionary* _Nullable SPDFMacFriendsRevisionForFile(NSString* path,
                                                      id<SPDFMacFriendsCollectionLookup> _Nullable lookup,
                                                      unsigned long long hashLimit, NSDate* now);

// "PDF", "Markdown", "EPUB", or the extension in capitals: the short kind shown on an attachment chip.
NSString* SPDFMacFriendsKindLabel(NSString* path);

NS_ASSUME_NONNULL_END
