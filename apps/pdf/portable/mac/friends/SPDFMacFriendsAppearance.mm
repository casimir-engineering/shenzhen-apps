#import "SPDFMacFriendsAppearance.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacCollectionStyle.h"

SZFriendsAppearance* SPDFMacFriendsReaderAppearance(void) {
    SZFriendsAppearance* appearance = [SZFriendsAppearance new];
    appearance.backgroundColor = SPDFCollectionColor(@"window");
    appearance.fieldBackgroundColor = SPDFCollectionColor(@"field");
    appearance.primaryTextColor = SPDFCollectionColor(@"text");
    appearance.secondaryTextColor = SPDFCollectionColor(@"secondary");
    appearance.separatorColor = SPDFCollectionColor(@"line");
    appearance.selectionColor = SPDFCollectionColor(@"selected");
    appearance.hoverColor = SPDFCollectionColor(@"hover");
    appearance.accentColor = SPDFCollectionColor(@"accent");
    appearance.controlColor = SPDFCollectionColor(@"control");
    appearance.controlBorderColor = SPDFCollectionColor(@"lineStrong");
    appearance.outgoingBubbleColor = SPDFCollectionColor(@"accentSoft");
    appearance.incomingBubbleColor = SPDFCollectionColor(@"bubble");
    appearance.primaryButtonColor = SPDFCollectionColor(@"accentFill");
    appearance.primaryButtonTextColor = SPDFCollectionColor(@"onAccent");
    appearance.badgeColor = SPDFCollectionColor(@"accentFill");
    appearance.badgeTextColor = SPDFCollectionColor(@"onAccent");
    appearance.destructiveColor = SPDFCollectionColor(@"destructive");
    // The Friends button sits between Groups and Search, so it takes their icon colour.
    appearance.titleBarIconColor = SPDFChromeIconColor(YES);
    return appearance;
}
