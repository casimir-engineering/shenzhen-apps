#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Emitted after a committed document/history mutation, with the store as object.
FOUNDATION_EXPORT NSNotificationName const SPDFCollectionStoreDidChangeNotification;
// Dates are Unix seconds. Document rows: id, path, aliases, title, versions,
// latestVersionID, capturedAt, status, excluded. Version rows: id, hash, size,
// capturedAt, modifiedAt, reason, keep, assets, assetWarnings, encrypted, indexFile.
// Private text-index pages are {page:1-based, text}; page0 means unknown in engine-free tools.
// Search rows also have page, snippet, query. Construction/reads never create folders.
@interface SPDFMacCollectionStore : NSObject
@property(nonatomic, readonly) NSURL* rootURL;
+ (instancetype)defaultStore;
- (instancetype)initWithRootURL:(NSURL*)URL;
// choice: unset/enabled/disabled. storageMode: dynamic (fresh default), static, unlimited.
// storageDynamicPercent is 50–80, default 80, of (free volume bytes + retained Collection bytes).
// Legacy byte limits migrate on read; switching modes preserves the selected dynamic percent.
- (NSDictionary*)settings;
- (BOOL)updateSettings:(NSDictionary*)changes error:(NSError**)error;
- (BOOL)isEnabled;
// Metadata-only: no volume query.
- (BOOL)isStorageLimited;
// Explicit settings/cleanup only; never called during construction or launch.
- (NSDictionary*)storageBudget;
- (NSArray<NSDictionary*>*)documents;
- (nullable NSDictionary*)documentForPath:(NSString*)path;
- (NSArray<NSDictionary*>*)versionsForDocumentID:(NSString*)documentID;
// Retained document/asset objects plus text indexes, excluding regenerated preview caches.
- (unsigned long long)storageUsedBytes;
- (BOOL)isArchivePath:(NSString*)path;
@end
@interface SPDFMacCollectionStore (EditableDocuments)
- (void)recordUnavailableSourcePath:(NSString*)path documentID:(NSString*)documentID;
- (nullable NSDictionary*)editableInfoForPath:(NSString*)path;
- (nullable NSURL*)editableVersionID:(nullable NSString*)versionID documentID:(NSString*)documentID error:(NSError**)error;
- (nullable NSDictionary*)captureEditablePath:(NSString*)path reason:(NSString*)reason error:(NSError**)error;
- (nullable NSURL*)renameEditablePath:(NSString*)path filename:(NSString*)filename error:(NSError**)error;
// Explicit rename/Undo variant: atomically guard and restore the Collection title.
- (nullable NSURL*)renameEditablePath:(NSString*)path filename:(NSString*)filename
    documentTitle:(NSString*)title expectedTitle:(nullable NSString*)expectedTitle error:(NSError**)error;
- (void)rememberGroup:(NSDictionary*)group documentID:(NSString*)documentID;
- (void)rememberGroups:(NSDictionary<NSString*,NSDictionary*>*)groups;
@end
@interface SPDFMacCollectionStore (Capture)
- (nullable NSDictionary*)capturePath:(NSString*)path reason:(NSString*)reason error:(NSError**)error;
// Only observed live-watch/app-save continuity may supply an existing document ID.
// Generic opens pass nil: a changed file identity at the same path starts separate history.
- (nullable NSDictionary*)capturePath:(NSString*)path reason:(NSString*)reason
               continuingDocumentID:(nullable NSString*)documentID error:(NSError**)error;
// Completion always runs on main queue. No queue exists until explicitly capturing.
- (void)capturePath:(NSString*)path reason:(NSString*)reason
        completion:(nullable void (^)(NSDictionary* _Nullable, NSError* _Nullable))completion;
- (void)capturePath:(NSString*)path reason:(NSString*)reason
        continuingDocumentID:(nullable NSString*)documentID
        completion:(nullable void (^)(NSDictionary* _Nullable, NSError* _Nullable))completion;
// Counts explicit opens atomically before cap cleanup. The completion flag remains
// YES if the count committed but a later source change caused retries/failure.
// Excluded/failed captures record existing-history usage on the worker before
// other queued captures run. When NO, callers may retry recording usage.
- (void)capturePath:(NSString*)path reason:(NSString*)reason
        continuingDocumentID:(nullable NSString*)documentID userOpenCount:(NSUInteger)count
        completion:(nullable void (^)(NSDictionary* _Nullable, NSError* _Nullable, BOOL userOpenCountRecorded))completion;
// Reader-authorized raw shadow bytes, bound to both original and copy stat.
// Metadata/identity remain the original; stale bindings fail closed. Edit gates
// deliberately use the direct-source API above.
- (void)capturePath:(NSString*)path authorizedCopy:(nullable NSDictionary*)copy reason:(NSString*)reason
        continuingDocumentID:(nullable NSString*)documentID userOpenCount:(NSUInteger)count
        completion:(nullable void (^)(NSDictionary* _Nullable, NSError* _Nullable, BOOL))completion;
- (void)importRecentPaths:(NSArray<NSString*>*)paths;
- (BOOL)ensureProtectedPath:(NSString*)path reason:(NSString*)reason error:(NSError**)error;
- (BOOL)ensureProtectedPath:(NSString*)path reason:(NSString*)reason
      continuingDocumentID:(nullable NSString*)documentID error:(NSError**)error;
@end
@interface SPDFMacCollectionStore (Access)
- (BOOL)setExcluded:(BOOL)excluded path:(NSString*)path error:(NSError**)error;
- (BOOL)setExcluded:(BOOL)excluded documentID:(NSString*)documentID error:(NSError**)error;
- (BOOL)setKeep:(BOOL)keep versionID:(NSString*)versionID documentID:(NSString*)documentID error:(NSError**)error;
// nil versionID removes document history; nil documentID removes all archived data.
// Caller obtains explicit scope confirmation. Originals/exclusion choices are untouched.
- (BOOL)deleteDocumentID:(nullable NSString*)documentID versionID:(nullable NSString*)versionID error:(NSError**)error;
// Removes older snapshots, retaining the latest saved version and source binding.
- (BOOL)deletePreviousBackupsForDocumentID:(NSString*)documentID error:(NSError**)error;
- (nullable NSURL*)materializeVersionID:(NSString*)versionID documentID:(NSString*)documentID error:(NSError**)error;
// Save As replaces the source binding without retaining the abandoned path alias.
- (BOOL)rebaseDocumentID:(NSString*)documentID toPath:(NSString*)path forgettingPath:(NSString*)oldPath error:(NSError**)error;
- (BOOL)linkDocumentID:(NSString*)documentID toPath:(NSString*)path
        allowMismatch:(BOOL)allowMismatch error:(NSError**)error;
@end
@interface SPDFMacCollectionStore (Export)
- (nullable NSDictionary*)archiveInfoForPath:(NSString*)path;
- (BOOL)exportVersionID:(NSString*)versionID documentID:(NSString*)documentID
                 toURL:(NSURL*)URL error:(NSError**)error;
@end
@interface SPDFMacCollectionStore (Search)
- (NSArray<NSDictionary*>*)search:(NSString*)query titlesOnly:(BOOL)titlesOnly
                 excludingPaths:(NSSet<NSString*>*)paths limit:(NSUInteger)limit;
- (NSArray<NSDictionary*>*)search:(NSString*)query titlesOnly:(BOOL)titlesOnly
                 excludingPaths:(NSSet<NSString*>*)paths limit:(NSUInteger)limit progress:(nullable NSProgress*)progress;
// Explicit invocation only. Enumerates user-provided roots, skips archive, symlinks/packages.
- (NSArray<NSDictionary*>*)locateCandidatesForDocumentID:(NSString*)documentID
            roots:(NSArray<NSURL*>*)roots cancelled:(BOOL (^)(void))cancelled error:(NSError**)error;
@end
@interface SPDFMacCollectionStore (Location)
// Verifies staged storage, redirects running windows, then removes all old payload.
// Only tiny routing metadata and compatibility symlinks remain for saved tabs. Destination must be empty.
// Collections containing editable copies must stay on the same disk to preserve live file writes.
- (BOOL)relocateToURL:(NSURL*)URL error:(NSError**)error;
@end
@interface SPDFMacCollectionStore (Cleanup)
// Preview does not create storage. Applying rejects a stale review without deleting anything.
// Plan: storageLimitBytes, usedBytes, projectedBytes, reclaimedBytes, canApply,
// removedVersionCount, removedDocumentCount, reviewToken, removals (documentID,
// versionID, title, capturedAt, openCount, stage: previousVersion/document).
- (NSDictionary*)previewStoragePolicy:(NSDictionary*)policy;
- (BOOL)applyStoragePolicy:(NSDictionary*)policy reviewedPlan:(NSDictionary*)plan error:(NSError**)error;
- (NSDictionary*)previewStorageLimit:(unsigned long long)limit;
- (BOOL)applyStorageLimit:(unsigned long long)limit reviewedPlan:(NSDictionary*)plan error:(NSError**)error;
// Explicit user opens only; callers exclude restoration, capture and history previews.
// Missing histories are a lazy no-op; this never creates an unused Collection.
- (BOOL)recordUserOpenForDocumentID:(NSString*)documentID error:(NSError**)error;
- (BOOL)recordUserOpenCount:(NSUInteger)count forDocumentID:(NSString*)documentID error:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
