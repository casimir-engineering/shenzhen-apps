// The Friends section of ShenzhenPDF's Settings, and showing it once to every reader.
//
// The once-only display uses what the unified Settings onboarding already uses (SPDFMacAISettingsIntegration.mm):
// a revision number, the same onboarding lock so two windows never both present Settings, and presentation after
// first paint in the primary window only. It does not reuse the AI setup revision itself, because raising that would
// send every existing reader through AI setup again; Friends keeps its own revision in settings.yaml instead.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacLaunchPrerenderPrivate.h"
#import "SPDFMacFriendsSettingsPage.h"
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

static void SelectFriendsSection(void) {
    for (NSWindow* window in NSApp.windows) {
        id controller = window.windowController;
        if ([controller isKindOfClass:SPDFMacUnifiedSettingsController.class])
            [(SPDFMacUnifiedSettingsController*)controller selectSection:SPDFMacFriendsSettingsSectionKey];
    }
}

@implementation ShenzhenMacDelegate (SPDFMacFriendsSettingsIntroduction)

- (BOOL)friendsShowSettingsIntroductionIfNeeded {
    if (self.restoreWindowID.length || self.detachedTabLaunch) return NO;
    SPDFMacFriendsSettingsState* settings = SPDFMacFriendsSettingsState.sharedState;
    if (settings.introducedRevision >= SPDFMacFriendsSettingsIntroductionRevision) return NO;
    // A new reader goes through AI setup first; the Friends section waits for a launch where setup is done, so the
    // two never compete for the same Settings window.
    SPDFMacAISettings* ai = [[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
    if (![ai load:nil] || ai.onboardingRevision < SPDFUnifiedSettingsExperienceVersion) return NO;
    NSString* lockPath = [SPDFMacAISettings.defaultURL.path stringByAppendingString:@".onboarding.lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (fd >= 0) close(fd);
        return NO;
    }
    // Another window may have shown it since this one launched: the file, not memory, decides.
    id disk = [self stateObjectFromFile:@"settings.yaml"];
    BOOL due = SPDFMacFriendsIntroducedRevisionInSettings([disk isKindOfClass:NSDictionary.class] ? disk : nil) <
        SPDFMacFriendsSettingsIntroductionRevision;
    if (due) {
        // Marked when shown, not when dismissed: the section informs and asks nothing, unlike AI setup.
        [settings setIntroducedRevision:SPDFMacFriendsSettingsIntroductionRevision];
        [self savePersistentState];
    } else if ([disk isKindOfClass:NSDictionary.class]) {
        [settings loadFromSettings:disk];
    }
    flock(fd, LOCK_UN);
    close(fd);
    if (!due) return NO;
    [self showUnifiedSettings:nil];
    SelectFriendsSection();
    return YES;
}

@end

@implementation ShenzhenMacDelegate (SPDFMacFriendsSettingsSection)

- (void)friendsShowSettingsSection {
    [self showUnifiedSettings:nil];
    SelectFriendsSection();
}

@end
