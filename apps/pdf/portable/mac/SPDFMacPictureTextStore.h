#pragma once
#import "SPDFMacCollectionStore.h"

NS_ASSUME_NONNULL_BEGIN

// Collection keeps a picture only when text was found in it, with that text (SPDFMacPictureText.h) in its version's
// text index, beside the plain lines search reads: {textPages: [{page, text}], pictureText: recognized}. The version
// row says it was looked at: pictureText "found" (or "none" for a picture kept because its original is gone). Pictures
// with no text are remembered by the hash of their bytes, so they are never read again unless asked.
@interface SPDFMacCollectionStore (PictureText)
// The text kept for the picture at `path` when its latest version holds exactly the bytes hashing to `hash`.
- (nullable NSDictionary*)pictureTextForPath:(NSString*)path hash:(NSString*)hash;
- (BOOL)pictureHashHasNoText:(NSString*)hash;
- (void)setPictureHash:(NSString*)hash hasNoText:(BOOL)noText;
// Keeps `recognized` with the document's latest version, when that version holds the bytes hashing to `hash`.
- (BOOL)attachPictureText:(NSDictionary*)recognized documentID:(NSString*)documentID hash:(NSString*)hash
                    error:(NSError**)error;
// A picture without text leaves Collection, unless Collection holds its only copy (its original is gone): then it stays,
// marked as looked at. YES when it left.
- (BOOL)removePictureWithoutTextDocumentID:(NSString*)documentID error:(NSError**)error;
// Pictures kept before their text was looked for (or whose latest version wasn't): {documentID, versionID, hash, path}.
- (NSArray<NSDictionary*>*)picturesAwaitingText:(BOOL (^)(NSString* path))isPicture;
@end

FOUNDATION_EXPORT NSString* _Nullable SPDFCollectionHashURL(NSURL* URL, NSError** error);

NS_ASSUME_NONNULL_END
