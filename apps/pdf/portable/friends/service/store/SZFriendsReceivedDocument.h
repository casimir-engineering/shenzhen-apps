// Documents sent with what belongs to them (PROTOCOL.md § Intents, Documents): the archive's names, its counts, and
// placing it as the document's folder on receipt (SZFriendsReceivedDocument.m).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The document's archive: a stored .zip whose every entry is in one folder named after the document ("Report/"),
// which holds the document ("Report/Report.md") and what it uses at the paths it uses them. Read by
// SZFriendsReceivedDocument.m, which accepts nothing else: compressed or encrypted entries, links, absolute names,
// ".", ".." or hidden components, more than SZFriendsDocumentEntryLimit entries, entries whose sizes add up to more
// than the archive, or bytes that fail their CRC.
extern const NSUInteger SZFriendsDocumentEntryLimit; // 10,000
// The archive's name for a helper that does not know documents (an older one, a phone's): "Report.zip".
NSString *SZFriendsDocumentArchiveName(NSString *documentName);
// The counts as stored in transfers.document, and back; nil for anything malformed.
NSString *_Nullable SZFriendsDocumentJSON(NSDictionary<NSString *, NSNumber *> *_Nullable document);
NSDictionary<NSString *, NSNumber *> *_Nullable SZFriendsDocumentFromJSON(NSString *_Nullable json);
// A document object of a file object (PROTOCOL.md § Intents, Documents) or the counts an OFFER carries, checked:
// nil unless every count is a whole number from 0 to SZFriendsDocumentEntryLimit.
NSDictionary<NSString *, NSNumber *> *_Nullable SZFriendsDocumentCounts(id _Nullable object);
// YES when `archive` is such an archive of `documentName` (reads its directory only).
BOOL SZFriendsDocumentArchiveIsValid(NSString *archive, NSString *documentName);
// Publishes a verified, staged document archive as the document's folder where SZFriendsPublishReceivedFile would
// put the file ("Report", "Report (2)" when that is taken, never replacing anything): unpacked into a hidden folder
// beside its final place, every file and folder quarantined, then renamed into place whole, so a half-written folder
// never shows. `willPublish` gets the document's path inside the folder that will be taken. Returns that path and
// removes the staged archive; nil when the archive is not one (*notADocument, nothing touched) or could not be placed.
NSString *_Nullable SZFriendsPublishReceivedDocument(NSString *staged, NSString *documentName,
                                                     NSString *stateDirectory,
                                                     BOOL (^_Nullable willPublish)(NSString *finalPath,
                                                                                  NSError **error),
                                                     BOOL *notADocument, NSError **error);
// The document alone, out of its archive into a new private folder inside `directory`, for its preview; the caller
// removes that folder. nil when the archive is not that document's.
NSString *_Nullable SZFriendsDocumentCopyOut(NSString *archive, NSString *documentName, NSString *directory);
// Whether a received document is still where it was placed: its folder and the document in it.
BOOL SZFriendsReceivedDocumentIsHere(NSString *_Nullable documentPath);

NS_ASSUME_NONNULL_END
