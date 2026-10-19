// Shared between the avatars implementation files only; nothing outside avatars/ includes it.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "avatars/SZFriendsAvatars.h"

NS_ASSUME_NONNULL_BEGIN

// Why a picture failed, beyond the public error code: each reason has its own words for the person.
typedef NS_ENUM(NSInteger, SZFriendsPictureFailure) {
    SZFriendsPictureFailureMalformedIntent,   // set_picture object malformed; `field` names the part
    SZFriendsPictureFailureAnimalUnavailable, // an animal this app does not offer
    SZFriendsPictureFailureCropOffImage,      // the crop square leaves the picture
    SZFriendsPictureFailureTooManyBytes,      // over SZFriendsPictureMaxInputBytes
    SZFriendsPictureFailureTooManyPixels,     // over SZFriendsPictureMaxInputPixels on a side
    SZFriendsPictureFailureBomb,              // declares far more pixels than its bytes can honestly hold
    SZFriendsPictureFailureUnreadable,        // not a complete image in an accepted format
    SZFriendsPictureFailureNotAFile,          // `path` is a folder, a device or a pipe
    SZFriendsPictureFailureFileMissing,       // `path` does not exist or cannot be opened
    SZFriendsPictureFailureReceivedInvalid,   // a friend's picture failed validation (logged, never shown)
    SZFriendsPictureFailureEncode,            // ImageIO could not encode, or nothing fit the byte limit
    SZFriendsPictureFailureWrite,             // the pictures directory could not be written
};

// Builds the NSError for a failure, with the PROTOCOL.md code, field and path in userInfo (SZFriendsAvatars.h).
// Returns NO so callers can write `return SZFriendsPictureFail(error, ...)` from BOOL methods.
BOOL SZFriendsPictureFail(NSError *_Nullable *_Nullable error, SZFriendsPictureFailure failure,
                          NSString *_Nullable field, NSString *_Nullable path);

// sRGB, cached: every bitmap and every color the pipeline produces is concrete sRGB.
CGColorSpaceRef SZFriendsPictureSRGB(void);

// Encodes a 256 x 256 opaque image as a metadata-free baseline JPEG within SZFriendsPictureMaxOutputBytes.
NSData *_Nullable SZFriendsPictureEncodeJPEG(CGImageRef image, NSError *_Nullable *_Nullable error);

// Draws `image` (already cropped to a square) onto an opaque white 256 x 256 sRGB bitmap. White because JPEG has
// no transparency and a transparent PNG's background must come out the same everywhere.
CGImageRef _Nullable SZFriendsPictureCreateSquare(CGImageRef image) CF_RETURNS_RETAINED;

// set_picture parsing and storage (SZFriendsPictureIntent.m).
SZFriendsPicture *_Nullable SZFriendsPictureFromIntent(id picture, SZFriendsAnimalSet *_Nullable set,
                                                       NSString *directory, NSError *_Nullable *_Nullable error);
SZFriendsPicture *_Nullable SZFriendsPictureStore(NSData *jpeg, NSString *directory,
                                                  NSError *_Nullable *_Nullable error);
// Reads a regular file of at most `limit` bytes without blocking on pipes or devices.
NSData *_Nullable SZFriendsPictureReadFile(NSString *path, NSUInteger limit, NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
