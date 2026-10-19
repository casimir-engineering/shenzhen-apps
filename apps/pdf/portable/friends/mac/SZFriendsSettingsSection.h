// Shenzhen Friends Settings section: what the host's Settings shows below its own Friends checkbox.
//
// AppKit views only. The host adapter owns the "Enable Shenzhen Friends" checkbox and the disclosure text,
// because they show while Friends is off and no helper runs (PROTOCOL.md § Views, settings). While Friends is on,
// the host places this section's view under them; it renders the `settings` snapshot (name, ID with Copy,
// received files with Show in Finder, automatic acceptance per friend, Delete history and Reset Friends with their
// confirmations) and sends the matching intents. It holds no logic beyond rendering, like the dropdown.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SZFriendsHost;
@class SZFriendsHelperLink;

@interface SZFriendsSettingsSection : NSObject
- (instancetype)initWithHost:(id<SZFriendsHost>)host link:(SZFriendsHelperLink *)link NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Laid out for the width the host's Settings pane gives it; its height fits the content and changes with the
// snapshot (the host observes intrinsicContentSize / fittingSize).
@property(nonatomic, readonly) NSView *view;

// The `settings` subscription is held only while the section is on screen. The link must be started (the
// dropdown's -install starts it); until it is connected the section shows the link's status line.
- (void)sectionWillAppear;
- (void)sectionDidDisappear;
@end

NS_ASSUME_NONNULL_END
