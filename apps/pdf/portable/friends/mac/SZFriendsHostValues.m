// Value classes declared in SZFriendsHost.h: appearance tokens, attachable items, assistant results, search results.

#import "mac/SZFriendsHost.h"
#import "mac/SZFriendsUI.h"

NSAttributedStringKey const SZFriendsMarkdownSourceAttributeName = @"SZFriendsMarkdownSource";
NSNotificationName const SZFriendsMarkdownDidChangeNotification = @"SZFriendsMarkdownDidChangeNotification";

@implementation SZFriendsAppearance

// Defaults are ShenzhenPDF's chrome palette (light, dark), the same tokens its adapter passes (neutral greys after
// the Codex desktop app): window #ffffff / #181818,
// field #ebebeb / #303030, text #0d0d0d / #ffffff, secondary #5d5d5d / #b4b4b4, lines #e3e3e3 / #313131, selection
// #ececec / #313131, hover #f2f2f2 / #292929, accent #1f62d6 / #83c3ff, control #ebebeb / #303030, outlines
// #cfcfcf / #454545, filled buttons and badges #1a6ae6 with white, a message one sent #e5f2ff / #0d273f, one received
// #f0f0f0 / #2f2f2f, destructive #ba2623 / #ff6b66. WHY exactly these: the suite renders with the defaults, and
// renders reviewed against the mockups must show what ships; the dark values once drifted (#2a2a2e, #7fb4f0) and
// reviewers approved colours users never saw. The route, success and warning colours come from the owner-approved
// mockups.
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _bodyFont = [NSFont systemFontOfSize:13];
    _secondaryFont = [NSFont systemFontOfSize:12];
    _captionFont = [NSFont systemFontOfSize:11];
    _headerFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _backgroundColor = SZFriendsDynamicColor(0xffffff, 0x181818);
    _fieldBackgroundColor = SZFriendsDynamicColor(0xebebeb, 0x303030);
    _separatorColor = SZFriendsDynamicColor(0xe3e3e3, 0x313131);
    _primaryTextColor = SZFriendsDynamicColor(0x0d0d0d, 0xffffff);
    // Secondary text keeps 4.5:1 on every background here (#5d5d5d on white is 6.6:1, on #ebebeb 5.5:1; #b4b4b4 on
    // #181818 is 8.6:1, on #313131 6.3:1).
    _secondaryTextColor = SZFriendsDynamicColor(0x5d5d5d, 0xb4b4b4);
    _accentColor = SZFriendsDynamicColor(0x1f62d6, 0x83c3ff);
    _selectionColor = SZFriendsDynamicColor(0xececec, 0x313131);
    _hoverColor = SZFriendsDynamicColor(0xf2f2f2, 0x292929);
    _outgoingBubbleColor = SZFriendsDynamicColor(0xe5f2ff, 0x0d273f);
    _incomingBubbleColor = SZFriendsDynamicColor(0xf0f0f0, 0x2f2f2f);
    _badgeColor = SZFriendsDynamicColor(0x1a6ae6, 0x1a6ae6);
    _badgeTextColor = SZFriendsDynamicColor(0xffffff, 0xffffff);
    _localRouteColor = SZFriendsDynamicColor(0x2e8540, 0x62c27e);
    _onlineRouteColor = SZFriendsDynamicColor(0x2a6fc0, 0x6aa8f0);
    _offlineRouteColor = SZFriendsDynamicColor(0x7a808a, 0x9a9aa3);
    _destructiveColor = SZFriendsDynamicColor(0xba2623, 0xff6b66);
    _controlColor = SZFriendsDynamicColor(0xebebeb, 0x303030);
    _controlBorderColor = SZFriendsDynamicColor(0xcfcfcf, 0x454545);
    _primaryButtonColor = SZFriendsDynamicColor(0x1a6ae6, 0x1a6ae6);
    _primaryButtonTextColor = SZFriendsDynamicColor(0xffffff, 0xffffff);
    _successColor = SZFriendsDynamicColor(0x2e8540, 0x62c27e);
    _warningColor = SZFriendsDynamicColor(0x8a5a12, 0xf0c27a);
    // ShenzhenPDF's chrome icon color (its Groups and Search buttons), not the dropdown's text color.
    _titleBarIconColor = SZFriendsDynamicColor(0x333333, 0xdcdcdc);
    _titleBarButtonSize = 28;
    _cornerRadius = 7;
    _dropdownWidth = 400;
    _dropdownMaxHeight = 640;
    return self;
}

@end

@implementation SZFriendsAttachableItem
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _title = @"";
    _detail = @"";
    _kindLabel = @"";
    _fileURL = [NSURL fileURLWithPath:@"/"];
    return self;
}
@end

@implementation SZFriendsAssistantResult
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _text = @"";
    _attachments = @[];
    return self;
}
@end

@implementation SZFriendsSearchResult
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _conversationID = @"";
    _messageID = @"";
    _conversationTitle = @"";
    _timeLabel = @"";
    _senderLabel = @"";
    _excerpt = @[];
    return self;
}
@end
