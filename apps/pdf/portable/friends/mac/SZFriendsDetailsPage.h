// Shenzhen Friends friend details and profile pages (internal).

#import "mac/SZFriendsPage.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsYourLinksView;
@class SZFriendsYourComputersView;

@class SZFriendsAnimalSet;

// The animal set the views draw from (the app's bundled copy, or the one tests point SZFriendsAvatarView at).
SZFriendsAnimalSet *_Nullable SZFriendsCurrentAnimalSet(void);

// A friend's details: route, ID with Copy, verification, automatic acceptance, received files, Remove and Block.
@interface SZFriendsDetailsPage : SZFriendsPage
- (instancetype)initWithContext:(SZFriendsContext *)context conversationID:(NSString *)conversationID;
@property(nonatomic, copy, readonly) NSString *conversationID;
@property(nonatomic, strong, readonly) SZFriendsHeaderView *header;
@property(nonatomic, strong, readonly) NSSwitch *autoAcceptSwitch;
@property(nonatomic, strong, readonly) SZFriendsButton *cpyButton;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *actionButtons;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *keyChangeButtons;
@property(nonatomic, strong, readonly) NSView *keyChangeCard;
@property(nonatomic, strong, readonly) NSView *verificationLabel;
// The small check beside an ID the Friends server confirmed (details id_confirmed); hidden otherwise.
@property(nonatomic, strong, readonly) NSView *attestationView;
// The route's icon before its words (SZFriendsRouteGlyph); hidden for a route that draws none.
@property(nonatomic, strong, readonly) NSView *routeIconView;
@property(nonatomic, strong, readonly) NSTextField *routeLabel;
@end

// The page behind Add by ID: name, picture (animals and your own photo), the ID with Copy and QR, add by ID.
@interface SZFriendsProfilePage : SZFriendsPage
@property(nonatomic, strong, readonly) SZFriendsHeaderView *header;
@property(nonatomic, strong, readonly) NSTextField *nameField;
@property(nonatomic, strong, readonly) SZFriendsButton *photoButton;
@property(nonatomic, strong, readonly) SZFriendsButton *cpyButton;
@property(nonatomic, strong, readonly) SZFriendsButton *qrButton;
@property(nonatomic, strong, readonly) NSTextField *addField;
@property(nonatomic, strong, readonly) SZFriendsButton *addButton;
@property(nonatomic, readonly) BOOL showingAnimals;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *animalButtons;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *ownPictureButton;
@property(nonatomic, strong, readonly, nullable) NSView *cropView;
@property(nonatomic, strong, readonly) SZFriendsYourLinksView *linksView; // "Your links" (SZFriendsLinkPage.h)
// "Your computers" (SZFriendsDevices.h)
@property(nonatomic, strong, readonly) SZFriendsYourComputersView *computersView;
- (void)toggleAnimals;
- (void)sendAddRequest;
// Shows the crop step for a picked or dropped photo; Use Picture sends set_picture with the crop square.
- (void)beginCropForImageAtPath:(NSString *)path;
@end

// The crop step: the photo under a circle, dragged to place and zoomed with the slider.
@interface SZFriendsCropView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context imagePath:(NSString *)path;
@property(nonatomic, readonly) BOOL hasImage;
@property(nonatomic, strong, readonly) SZFriendsButton *useButton;
@property(nonatomic, strong, readonly) SZFriendsButton *cancelButton;
// The square, in source pixels, inside the circle now (PROTOCOL.md set_picture crop).
- (NSDictionary<NSString *, NSNumber *> *)cropSquare;
@property(nonatomic, copy, nullable) void (^onUse)(NSDictionary *crop);
@property(nonatomic, copy, nullable) void (^onCancel)(void);
@end

NS_ASSUME_NONNULL_END
