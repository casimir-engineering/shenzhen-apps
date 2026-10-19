// Value classes declared in SZFriendsHost.h: appearance tokens, attachable items, assistant results, search results.

#import "mac/SZFriendsHost.h"
#import "mac/SZFriendsUI.h"

NSAttributedStringKey const SZFriendsMarkdownSourceAttributeName = @"SZFriendsMarkdownSource";
NSNotificationName const SZFriendsMarkdownDidChangeNotification = @"SZFriendsMarkdownDidChangeNotification";

@implementation SZFriendsAppearance

// Defaults are ShenzhenPDF's chrome palette (light, dark), the same tokens its adapter passes (its Collection palette):
// window #ffffff / #292b2e, text #26282b / #eceef1, secondary #61666d / #b3b7be, lines #dddfdf / #414448,
// selection #dbe5f0 / #374b61, accent #286398 / #a1c9ed, control #f6f6f5 / #232426, hover #e8ebed / #393d42. WHY
// exactly these: the suite renders with the defaults, and renders reviewed against the mockups must show what
// ships; the dark values once drifted (#2a2a2e, #7fb4f0) and reviewers approved colours users never saw. The rest
// come from the owner-approved mockups.
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _bodyFont = [NSFont systemFontOfSize:13];
    _secondaryFont = [NSFont systemFontOfSize:12];
    _captionFont = [NSFont systemFontOfSize:11];
    _headerFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _backgroundColor = SZFriendsDynamicColor(0xffffff, 0x292b2e);
    _fieldBackgroundColor = SZFriendsDynamicColor(0xf4f4f5, 0x1f1f23);
    _separatorColor = SZFriendsDynamicColor(0xdddfdf, 0x414448);
    _primaryTextColor = SZFriendsDynamicColor(0x26282b, 0xeceef1);
    // Secondary text keeps 4.5:1 on both backgrounds (#61666d on white is 5.9:1, #b3b7be on #292b2e is 7.6:1).
    _secondaryTextColor = SZFriendsDynamicColor(0x61666d, 0xb3b7be);
    _accentColor = SZFriendsDynamicColor(0x286398, 0xa1c9ed);
    _selectionColor = SZFriendsDynamicColor(0xdbe5f0, 0x374b61);
    _hoverColor = SZFriendsDynamicColor(0xe8ebed, 0x393d42);
    _outgoingBubbleColor = SZFriendsDynamicColor(0xdbe7f5, 0x2c3a55);
    _incomingBubbleColor = SZFriendsDynamicColor(0xefeff1, 0x34343b);
    _badgeColor = SZFriendsDynamicColor(0xd93a30, 0xd93a30);
    _badgeTextColor = SZFriendsDynamicColor(0xffffff, 0xffffff);
    _localRouteColor = SZFriendsDynamicColor(0x2e8540, 0x62c27e);
    _onlineRouteColor = SZFriendsDynamicColor(0x2a6fc0, 0x6aa8f0);
    _offlineRouteColor = SZFriendsDynamicColor(0x7a808a, 0x9a9aa3);
    _destructiveColor = SZFriendsDynamicColor(0xc4302a, 0xff9a92);
    _controlColor = SZFriendsDynamicColor(0xf6f6f5, 0x232426);
    _controlBorderColor = SZFriendsDynamicColor(0xcfd1d4, 0x4a4a52);
    _primaryButtonColor = SZFriendsDynamicColor(0x286398, 0x2f4366);
    _primaryButtonTextColor = SZFriendsDynamicColor(0xffffff, 0xeaf1ff);
    _successColor = SZFriendsDynamicColor(0x2e8540, 0x62c27e);
    _warningColor = SZFriendsDynamicColor(0x8a5a12, 0xf0c27a);
    // ShenzhenPDF's chrome icon color (its Groups and Search buttons), not the dropdown's text color.
    _titleBarIconColor = SZFriendsDynamicColor(0x26282b, 0xeceef1);
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
