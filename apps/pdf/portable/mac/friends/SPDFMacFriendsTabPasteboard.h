// Reader tabs as Friends attachments: what a tab dragged onto Friends sends.
//
// The tab strip writes one JSON string per drag under its private pasteboard type: a tab dictionary
// (spdf_dictionary_from_tab, SPDFMacModels.mm) or, for a group, {"groupTabs": [tab dictionaries]}, signed with the
// reader's per-user key (SPDFMacTabDragSignature.h). Only a payload whose signature verifies is read: any app can
// write the type, and a forged one could send any file the reader can read under a harmless name. Each tab becomes
// the file and exact revision on screen (brief § Drag and drop): a read-only tab shows the reader's private reading
// copy, so that copy's bytes are sent under the source's name; a Collection version tab shows an immutable archive
// file bound to that version; any other tab shows its file as it is now. Which file holds those bytes is decided from
// the reader's own state, never from the payload's workingPath, and the name friends see belongs to the file sent.

#import <AppKit/AppKit.h>
#import "SPDFMacFriendsRevision.h"

@class SZFriendsAttachableItem;

NS_ASSUME_NONNULL_BEGIN

// The tab strip's drag type (SPDFTabDragPasteboardType in SPDFMacTabStripViewPrivate.h; a source-contract test
// keeps the two equal without this file importing the strip's private header).
FOUNDATION_EXPORT NSPasteboardType const SPDFMacFriendsTabPasteboardType;

// The tab dictionaries a pasteboard carries under a valid signature; empty when it carries no signed reader tab.
// Cheap: verifies an HMAC and parses JSON, reads no file but the key. The first form uses this process's key.
NSArray<NSDictionary*>* SPDFMacFriendsTabDictionariesFromPasteboard(NSPasteboard* pasteboard);
NSArray<NSDictionary*>* SPDFMacFriendsTabDictionariesFromPasteboardWithKey(NSPasteboard* pasteboard,
                                                                           NSData* _Nullable key, NSDate* now);

// YES when at least one dragged tab names a file, so the Friends button can spring-load for it.
BOOL SPDFMacFriendsPasteboardHasSendableTabs(NSPasteboard* pasteboard);

// The file whose bytes one of this reader's own tabs shows: the working copy for a read-only tab, otherwise the
// tab's path. For tab dictionaries the reader made itself (the `#` picker), never for a dropped payload.
NSString* _Nullable SPDFMacFriendsTabDisplayedFile(NSDictionary* tab);

// Where the reader keeps the private reading copy of a read-only `source` (ShenzhenPDFMac.mm
// -readOnlyCopiesDirectory and -readOnlyCopyFileNameForSourcePath:, kept in step by a source-contract test).
NSString* SPDFMacFriendsReadOnlyCopyPath(NSString* source, NSString* stateDirectory);

// The file a dropped tab's bytes come from: for a read-only tab, the reading copy the reader keeps for its path in
// `stateDirectory` when that is a regular file, otherwise the tab's path itself.
NSString* _Nullable SPDFMacFriendsDraggedTabFile(NSDictionary* tab, NSString* stateDirectory);

// The files dropped tabs would send, read without hashing (the views ask on every draggingEntered): each tab's
// SPDFMacFriendsDraggedTabFile once, in drag order, as it is on disk now, a link or a folder included, so Friends
// refuses them while dragging as it refuses the same files from Finder. Tabs whose file is gone are left out.
NSArray<NSString*>* SPDFMacFriendsDraggedTabFiles(NSArray<NSDictionary*>* tabs, NSString* stateDirectory);

// One attachable item per dropped tab whose file still exists, in drag order, without duplicates. Tabs whose file is
// gone or is a folder are left out (folders cannot be sent yet). `hashLimit` bounds hashing (main-thread callers pass
// SPDFMacFriendsMainThreadHashLimit); `stateDirectory` is the reader's (SPDFMacStateDirectoryPath()).
NSArray<SZFriendsAttachableItem*>* SPDFMacFriendsItemsForTabs(NSArray<NSDictionary*>* tabs,
                                                              id<SPDFMacFriendsCollectionLookup> _Nullable lookup,
                                                              unsigned long long hashLimit, NSDate* now,
                                                              NSString* stateDirectory);

NS_ASSUME_NONNULL_END
