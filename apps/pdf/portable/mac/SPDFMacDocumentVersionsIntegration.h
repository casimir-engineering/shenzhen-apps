#pragma once
// Versions of a document in the reader (storage: SPDFMacDocumentVersions.h). "New Version…" in the File menu and the
// tab menu freezes what the document holds now as the next version, with its comments; "Versions" opens or compares
// any of them. When a document with comments is rewritten by another app (an agent, an editor), the text it held is
// kept as the previous version, so the comments stay on the text they were made on (settings.yaml
// "keepVersionsWhenChanged", on unless set to false).
#import "SPDFMacDelegatePrivate.h"

NS_ASSUME_NONNULL_BEGIN

// settings.yaml: the setting read at launch, and written back with the rest.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFDocumentVersionsLoadSettings(NSDictionary* _Nullable settings);
FOUNDATION_EXPORT NSDictionary* SPDFDocumentVersionsSettingsForSaving(NSDictionary* settings);
FOUNDATION_EXPORT BOOL SPDFDocumentVersionsKeepWhenChanged(void);
FOUNDATION_EXPORT void SPDFDocumentVersionsSetKeepWhenChanged(BOOL keep);

// File ▸ New Version… and File ▸ Versions, after Save As.
FOUNDATION_EXPORT void SPDFInstallDocumentVersionsMenu(NSMenu* fileMenu, id reader);

@interface ShenzhenMacDelegate (SPDFDocumentVersions)
// The tab menu's version items for `path`.
- (void)addVersionItemsToMenu:(NSMenu*)menu path:(NSString*)path;
// Hooks from the document lifecycle (SPDFMacCollectionIntegration.mm): a document finished opening or saving, and a
// document is about to be reloaded because its file changed.
- (void)versionsDocumentDidOpen:(NSString*)path;
- (void)versionsDocumentWillReloadAfterChange:(NSString*)path;

// For the command-line tool. Creates the next version of `path` as "New Version…" does, without asking: `carry` is
// "open" (the default when nil), "all" or "none". Updates any tab showing the document. Returns the frozen version
// (SPDFDocumentVersion.dictionaryRepresentation), or nil with `error`.
- (nullable NSDictionary*)versionsCreateForPath:(NSString*)path carry:(nullable NSString*)carry error:(NSError**)error;
// Every version of the document `path` belongs to, oldest first (dictionaryRepresentation of each).
- (NSArray<NSDictionary*>*)versionsListForPath:(NSString*)path;
// Opens the version comparison of two versions of one document (numbers as listed), older on the left.
- (BOOL)versionsCompareForPath:(NSString*)path from:(NSInteger)older to:(NSInteger)newer error:(NSError**)error;
@end

NS_ASSUME_NONNULL_END
