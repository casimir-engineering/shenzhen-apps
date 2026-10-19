// Picture errors and their words. Every message is for the person choosing their own picture on the profile page:
// they want to know why it did not take and what to do instead, so each names the fix, never the mechanism.
// The words live here rather than in service/presentation/ because presentation includes this module, not the
// other way round; the helper passes localizedDescription through as the reply's error.message.

#import "avatars/SZFriendsAvatarsInternal.h"

NSErrorDomain const SZFriendsPictureErrorDomain = @"SZFriendsPictureErrorDomain";
NSString *const SZFriendsPictureErrorCodeKey = @"SZFriendsPictureErrorCode";
NSString *const SZFriendsPictureErrorFieldKey = @"SZFriendsPictureErrorField";

typedef struct {
    SZFriendsPictureError code;
    NSString *protocolCode;
    NSString *defaultField;
    NSString *message;
} SZFriendsPictureFailureInfo;

static SZFriendsPictureFailureInfo SZFriendsPictureInfoFor(SZFriendsPictureFailure failure) {
    switch (failure) {
    case SZFriendsPictureFailureMalformedIntent:
        // Only a view bug sends a malformed intent; choosing again is the one thing the person can do.
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorInvalidField, @"invalid_field", @"picture",
                                             @"Your picture couldn't be changed. Try choosing it again."};
    case SZFriendsPictureFailureAnimalUnavailable:
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorInvalidField, @"invalid_field", @"picture.index",
                                             @"That animal isn't available. Choose another one."};
    case SZFriendsPictureFailureCropOffImage:
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorInvalidField, @"invalid_field", @"picture.crop",
                                             @"The crop doesn't fit inside the picture. Adjust it and try again."};
    case SZFriendsPictureFailureTooManyBytes:
        // "5 MB" is true from the person's side: Finder counts in decimal megabytes, and 5 MiB is more than
        // 5,000,000 bytes, so anything Finder shows as under 5 MB fits.
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorTooLarge, @"picture_invalid", nil,
                                             @"This picture is over 5 MB. Choose a smaller one."};
    case SZFriendsPictureFailureTooManyPixels:
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorTooLarge, @"picture_invalid", nil,
                                             @"This picture is too large. Choose one under 8,192 pixels on each side."};
    case SZFriendsPictureFailureBomb:
        // Within the stated limits but built to expand far beyond them; no honest advice about size applies.
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorTooLarge, @"picture_invalid", nil,
                                             @"This picture can't be used. Choose a different one."};
    case SZFriendsPictureFailureUnreadable:
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorUnreadable, @"picture_invalid", nil,
                                             @"This file can't be read as a picture. "
                                             @"Choose a JPEG, PNG or HEIC image."};
    case SZFriendsPictureFailureNotAFile:
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorUnreadable, @"picture_invalid", nil,
                                             @"This isn't a picture file. Choose a JPEG, PNG or HEIC image."};
    case SZFriendsPictureFailureFileMissing:
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorFileMissing, @"file_missing", nil,
                                             @"This picture can't be opened. It may have been moved or deleted."};
    case SZFriendsPictureFailureReceivedInvalid:
        // Never shown (the friend's row keeps a placeholder); written for whoever reads the helper's log.
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorUnreadable, @"picture_invalid", nil,
                                             @"A friend's picture couldn't be shown, so their initials are shown."};
    case SZFriendsPictureFailureEncode:
    case SZFriendsPictureFailureWrite:
        return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorInternal, @"internal", nil,
                                             @"Your picture couldn't be saved. Try again."};
    }
    return (SZFriendsPictureFailureInfo){SZFriendsPictureErrorInternal, @"internal", nil,
                                         @"Your picture couldn't be saved. Try again."};
}

BOOL SZFriendsPictureFail(NSError **error, SZFriendsPictureFailure failure, NSString *field, NSString *path) {
    if (!error) return NO;
    SZFriendsPictureFailureInfo info = SZFriendsPictureInfoFor(failure);
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = info.message;
    userInfo[SZFriendsPictureErrorCodeKey] = info.protocolCode;
    if (info.code == SZFriendsPictureErrorInvalidField) {
        userInfo[SZFriendsPictureErrorFieldKey] = field ?: info.defaultField;
    }
    if (path) userInfo[NSFilePathErrorKey] = path;
    *error = [NSError errorWithDomain:SZFriendsPictureErrorDomain code:info.code userInfo:userInfo];
    return NO;
}
