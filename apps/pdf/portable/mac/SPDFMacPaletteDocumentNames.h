#pragma once
#import <Foundation/Foundation.h>

// How the Cmd+K palette names a document and says where it lives. Pure string
// work on paths the palette already holds: nothing here reads a file, so the
// palette's first rows stay instant (see tests/SPDFMacPaletteDocumentNamesTests.mm).

// YES for file names that identify a file to a machine rather than to a person:
// hex digests and UUIDs ("2f6fa8b5ebba154de171778d8d99b38f"), and names that are
// mostly digits ("DT100000001_1700000000000"). Any extension is ignored.
BOOL spdf_palette_name_is_opaque(NSString* name);

// The file name a person reads: the last path component without a document
// extension ("Report v2.0" keeps its ".0").
NSString* spdf_palette_file_display_name(NSString* path);

// The row title for a document. An explicit label (a saved version's name) wins;
// then the document's own title when the file name is opaque and that title says
// something more; otherwise the file name. Never a path.
NSString* spdf_palette_document_title(NSString* path, NSString* label, NSString* metadataTitle);

// The Collection document a working copy belongs to, or nil when `path` is not a
// Collection working copy (<Collection>/editable/<document>/<copy>/<file>).
NSString* spdf_palette_collection_copy_document_id(NSString* path);

// Where a document lives, in a few words for the quiet column: "Collection" for
// the reader's own saved copies, the app for files another app keeps ("Safari",
// "Mail", "WeChat"), "Downloads", or the nearest meaningful folder name.
// `home` and `supportDirectory` are the user's home and the reader's own data folder.
NSString* spdf_palette_location_label(NSString* path, NSString* home, NSString* supportDirectory);

// Folds each Collection working copy into the open document it is a copy of, so
// one document is one row. A copy's original is known from the original row's
// collectionHistoryID, or from originalPathByDocumentID (document id -> original
// path), or from a working copy row's own "originalPath" (what its tab already
// knows). The surviving row is the one in this process when only one of them is,
// else the original; it keeps the most recent viewing times and lists the paths
// folded into it under "mergedPaths". A copy whose original is not open keeps
// its row and records that path as "originalPath".
NSArray<NSDictionary*>* spdf_palette_merge_collection_copies(
    NSArray<NSDictionary*>* candidates, NSDictionary<NSString*, NSString*>* originalPathByDocumentID);

// Document id -> original path for every document in a Collection manifest
// dictionary ({documents: {id: {path}}}). Malformed entries are skipped.
NSDictionary<NSString*, NSString*>* spdf_palette_collection_original_paths(NSDictionary* manifest);

// Document id -> the name the Collection keeps for it (what it was saved or
// renamed as, without the extension), from a manifest dictionary.
NSDictionary<NSString*, NSString*>* spdf_palette_collection_titles(NSDictionary* manifest);

// Rows still named by a hash or id file name take the name the Collection keeps
// for their document, when that name is one a person gave. The document is known
// from a working copy's folder, the row's collectionHistoryID, or its original
// path. Other rows are returned as they are.
NSArray<NSDictionary*>* spdf_palette_titled_from_collection(NSArray<NSDictionary*>* rows,
    NSDictionary<NSString*, NSString*>* originalPathByDocumentID, NSDictionary<NSString*, NSString*>* titles);
