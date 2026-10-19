// The Friends page of ShenzhenPDF's Settings window: what SPDFMacUnifiedSettings.mm's -selectSection: calls for
// the "friends" section (SPDFMacFriendsSettingsIntegration.mm builds it).

#import "SPDFMacUnifiedSettings.h"

@interface SPDFMacUnifiedSettingsController (SPDFMacFriends)
- (void)buildFriends;
@end
