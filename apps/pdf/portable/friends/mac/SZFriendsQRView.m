// SZFriendsQRView: the profile's QR code (the ID's qr_payload), drawn dark on white in both appearances.

#import "mac/SZFriendsQRView.h"

#import <CoreImage/CoreImage.h>

@implementation SZFriendsQRView {
    NSImage *_image;
}
- (void)setPayload:(NSString *)payload {
    if ([payload isEqualToString:_payload]) return;
    _payload = [payload copy];
    _image = nil;
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (filter && data.length) {
        [filter setValue:data forKey:@"inputMessage"];
        [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
        CIImage *output = filter.outputImage;
        if (output) {
            NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:output];
            _image = [[NSImage alloc] initWithSize:rep.size];
            [_image addRepresentation:rep];
        }
    }
    self.needsDisplay = YES;
}
- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityImageRole;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    // Always dark on white, in both appearances: scanners need the contrast, not the theme.
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    if (!_image) return;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationNone;
    [_image drawInRect:NSInsetRect(self.bounds, 6, 6)];
    [NSGraphicsContext restoreGraphicsState];
}
@end
