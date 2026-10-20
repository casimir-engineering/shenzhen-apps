// Shenzhen Friends profile: the QR of the person's ID (internal).

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// The QR of `id.qr_payload`, drawn with hard pixel edges so a phone camera reads it at any size.
@interface SZFriendsQRView : NSView
@property(nonatomic, copy) NSString *payload;
@end

NS_ASSUME_NONNULL_END
