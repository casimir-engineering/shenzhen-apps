// The Friends page of the Settings window. Kept apart from the reader's categories so the Settings controller's own
// test can link it with only the pane (portable/Makefile mac-unified-settings-tests).

#import "SPDFMacFriendsSettingsPage.h"
#import "SPDFMacFriendsSettingsPane.h"

// Built by SPDFMacUnifiedSettings.mm; declared here so the Friends page is laid out like its neighbours.
@interface SPDFMacUnifiedSettingsController (SPDFMacFriendsPageBuilding)
- (void)heading:(NSString*)title subtitle:(NSString*)subtitle;
- (void)add:(NSView*)view;
- (void)divider;
@end

@implementation SPDFMacUnifiedSettingsController (SPDFMacFriends)
- (void)buildFriends {
    [self heading:SPDFMacFriendsSettingsHeading subtitle:SPDFMacFriendsSettingsSubtitle];
    [self divider];
    SPDFMacFriendsSettingsPane* pane =
        [[SPDFMacFriendsSettingsPane alloc] initWithSource:SPDFMacFriendsSettingsPaneSourceForProcess()];
    [self add:pane];
}
@end
