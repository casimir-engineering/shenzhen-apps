// Shenzhen Friends views: the helper's own files a view reads (internal).
//
// The helper names two kinds of file in its state directory: avatar photos in pictures/ and transfer previews in
// thumbnails/ (PROTOCOL.md § Shared objects, Avatar; § Thumbnails, What views get). A view reads exactly those: a
// path directly inside that folder, opened without following a link or waiting on a pipe, a regular file of bounded
// size, an image whose header declares a bounded size, decoded off the main thread to exactly that size. WHY,
// although the helper wrote them: a damaged or planted entry in its state (a link, a FIFO, a huge image) must never
// make a view follow it elsewhere, block, or decode something enormous while the dropdown opens.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Whether `path` names a file directly inside `folder` ("pictures", "thumbnails") of the helper's state directory,
// spelled as the client library spells the state directory or with it resolved: no subfolder, no "." or "..", no
// doubled slash. Judged by the path alone.
BOOL SZFriendsIsHelperFile(NSString *path, NSString *folder);

// The bytes of a regular file of 1 to `limit` bytes, opened without following a link and without waiting on a pipe
// or device; nil for anything else.
NSData *_Nullable SZFriendsReadRegularFile(NSString *path, off_t limit);

// The pixel size a PNG (its IHDR) or a JPEG (its first frame header) declares, read before anything is decoded. NO for
// any other format or a damaged header. `isPNG` says which it was.
BOOL SZFriendsDeclaredImageSize(NSData *data, NSInteger *width, NSInteger *height, BOOL *_Nullable isPNG);

// Avatar photos (PROTOCOL.md § Shared objects, Avatar): the helper writes 256 px JPEGs of at most 48 KiB, so a file
// over these bounds is not one of them.
FOUNDATION_EXPORT const off_t SZFriendsAvatarPhotoMaxBytes;    // 256 KiB
FOUNDATION_EXPORT const NSInteger SZFriendsAvatarPhotoMaxSide; // 1024 px

// An avatar photo decoded on the calling thread, or NULL: directly in pictures/, a regular file of at most 256 KiB,
// a JPEG or PNG declaring 1 to 1024 px a side and decoding to exactly that size. The views call it off the main
// thread only (SZFriendsAvatarPhoto); tests call it directly.
CGImageRef _Nullable SZFriendsCopyAvatarPhoto(NSString *path) CF_RETURNS_RETAINED;

// The photo to draw for an avatar's `path`, from the cache; nil while it loads on a background queue or when it
// cannot be loaded (initials are drawn meanwhile and after). Once it has loaded, `view` is asked to redraw. A failure
// is not remembered, so a photo the helper finishes writing later loads on a later draw. Main thread only.
NSImage *_Nullable SZFriendsAvatarPhoto(NSString *path, NSView *_Nullable view);
// Forgets every loaded photo (tests).
void SZFriendsForgetAvatarPhotos(void);

NS_ASSUME_NONNULL_END
