#pragma once
// Files and folders the person gives one chat, by dropping them on it or choosing them with Attach files. Each is a
// grant of that chat: its assistant, the parts it splits work into (run_subagents) and its Python may read the file,
// or the folder and everything under it, and nothing beside them. Grants live in the chat itself (its "grants" key,
// saved with it, so reopening the chat keeps them) and reach tools only as attachment chips on that chat's requests
// (SPDFMacAIRequestContext.h): no other chat, and no request of another chat's parts, can see them. Removing the chip
// in the composer ends the grant.
//
// A grant: {"id": "attachment:<16 hex>", "name", "kind": "file" | "folder", "path" (where it was when granted),
// "bookmark" (base64 bookmark data, so a moved or renamed item is still found)}.
#import <Foundation/Foundation.h>

@class SPDFMacAIRequestChip;

NS_ASSUME_NONNULL_BEGIN

// A grant for a file or folder the person chose. nil with a reason written for them when it cannot be given: missing,
// neither a file nor a folder, or a folder that holds their whole home folder or is a top-level system folder ("/",
// /Users, /System, /Applications, /Library…), which would open far more than they meant to share.
NSDictionary* _Nullable SPDFMacAIChatGrantForURL(NSURL* URL, NSString* _Nullable* _Nullable reason);

// Where the grant's item is now, by real path (links resolved), or nil when it is gone or is no longer the same kind.
NSString* _Nullable SPDFMacAIChatGrantResolvedPath(NSDictionary* grant);

// The grants' chips for a request of this chat. A grant whose item is gone has none.
NSArray<SPDFMacAIRequestChip*>* SPDFMacAIChatGrantChips(NSArray<NSDictionary*>* _Nullable grants);

// YES for a chip that grants a folder (its file URL is a directory).
BOOL SPDFMacAIChatChipIsFolder(SPDFMacAIRequestChip* chip);

// The real path of `relative` inside the granted folder `folder` (a real path), when it stays inside: absolute paths,
// "..", and links that lead outside the folder are refused with a reason for the model. An empty `relative` is the
// folder itself.
NSString* _Nullable SPDFMacAIChatGrantPathInside(NSString* folder, NSString* _Nullable relative,
                                                NSString* _Nullable* _Nullable reason);

// YES when `path` (real) is `root` or inside it, by whole path components.
BOOL SPDFMacAIChatGrantContains(NSString* root, NSString* path);

// The sentence the model reads each request while the chat has grants: names, ids and kinds, and how to read them.
NSString* _Nullable SPDFMacAIChatGrantsNote(NSArray<SPDFMacAIRequestChip*>* chips);

NS_ASSUME_NONNULL_END
