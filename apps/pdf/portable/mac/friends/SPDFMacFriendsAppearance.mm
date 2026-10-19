#import "SPDFMacFriendsAppearance.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacCollectionStyle.h"

SZFriendsAppearance* SPDFMacFriendsReaderAppearance(void) {
    SZFriendsAppearance* appearance = [SZFriendsAppearance new];
    appearance.backgroundColor = SPDFCollectionColor(@"window");
    appearance.primaryTextColor = SPDFCollectionColor(@"text");
    appearance.secondaryTextColor = SPDFCollectionColor(@"secondary");
    appearance.separatorColor = SPDFCollectionColor(@"line");
    appearance.selectionColor = SPDFCollectionColor(@"selected");
    appearance.hoverColor = SPDFCollectionColor(@"hover");
    appearance.accentColor = SPDFCollectionColor(@"accent");
    appearance.controlColor = SPDFCollectionColor(@"control");
    // The Friends button sits between Groups and Search, so it takes their icon colour.
    appearance.titleBarIconColor = SPDFChromeIconColor(YES);
    return appearance;
}
