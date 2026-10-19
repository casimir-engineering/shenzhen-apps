// The bar AI chat shows while the assistant may read all Friends chats for a while (SPDFMacFriendsChatGrant.h):
// "The assistant can read all your Friends chats · 52 min left" and Stop now; in a chat too narrow for that sentence
// (320 to 400 points), "All Friends chats · 52 min left", with the sentence in its tooltip and for VoiceOver. It is
// shown only while the grant runs and follows it: the minutes count down, and expiry, Stop now or Friends going away
// take it off the chat.
//
// The bar's identifier starts with "szfriends.", so the assistant's app_controls neither lists nor presses it
// (SPDFMacAIAppControls.h): only the person ends or changes their grant.

#import <AppKit/AppKit.h>
#import "SPDFMacFriendsChatGrant.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsGrantBarIdentifier; // "szfriends.chatAccessBar"

@interface SPDFMacFriendsGrantBar : NSView
// `show` places the bar in the chat (the bar) or takes it away (nil); it runs at once and on every grant change.
- (instancetype)initWithGrant:(SPDFMacFriendsChatGrant*)grant
                         show:(void (^)(SPDFMacFriendsGrantBar* _Nullable bar))show NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
@property(nonatomic, readonly) SPDFMacFriendsChatGrant* grant;
@property(nonatomic, readonly) NSTextField* label;
@property(nonatomic, readonly) NSButton* stopButton; // "Stop now"
- (void)refresh;
// Stops following the grant; the chat view keeps nothing of the bar after `show(nil)`.
- (void)uninstall;
@end

NS_ASSUME_NONNULL_END
