// A moving transfer's progress by route (PROTOCOL.md § Fast transfers, Progress by route): the route icons on its
// card and the bar split by what each route carried, drawn from the approved mockup's 16-unit paths and colours, so
// the GTK views (szfriends_gtk_transfer_progress.c) and Shenzhen 3D (apps/3d/src/friends/TransferProgress.tsx) draw
// the same ones.

#import <AppKit/AppKit.h>

#import "mac/SZFriendsUI.h"

NS_ASSUME_NONNULL_BEGIN

// The route's colour, the same in light and dark: same Wi-Fi green, direct Wi-Fi teal, Internet purple, Bluetooth
// amber, relay blue. Never grey or red, which say "not working".
NSColor *SZFriendsTransferRouteColor(NSString *_Nullable method);

// One route as a small rounded square: its colour with a white glyph while in use, an outline once it is not. Its
// tooltip and accessibility label are the route's `label` ("Bluetooth · in use").
@interface SZFriendsTransferRouteIcon : NSView
@property(nonatomic, copy, nullable) NSString *method;
@property(nonatomic) BOOL active;
@property(nonatomic, strong) SZFriendsAppearance *theme;
@end

// The 8-point bar: each route's share in its colour, the accent alone when the helper says nothing of routes, and
// a full bar that moves gently while the file is checked (still under reduce motion).
@interface SZFriendsSplitProgressBar : NSView
@property(nonatomic) double fraction;
@property(nonatomic) BOOL determinate;
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *segments; // PROTOCOL.md transfer_segment
@property(nonatomic) BOOL finishing;
@property(nonatomic, strong) SZFriendsAppearance *theme;
@end

NS_ASSUME_NONNULL_END
