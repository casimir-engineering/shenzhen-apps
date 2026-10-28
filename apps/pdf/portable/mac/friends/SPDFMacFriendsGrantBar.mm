#import "SPDFMacFriendsGrantBar.h"
#import "../SPDFMacCollectionStyle.h"

NSString* const SPDFMacFriendsGrantBarIdentifier = @"szfriends.chatAccessBar";

// For whoever wonders what the bar means for their next message: what it may read, what stops, where it goes.
static NSString* const kDetail = @"Until then, the assistant may read any of your Friends chats when you send a "
    "message here, and doesn't search the web. What it reads goes to OpenRouter, with no training and nothing kept.";

@implementation SPDFMacFriendsGrantBar {
    void (^_show)(SPDFMacFriendsGrantBar*);
    id _observer;
}

- (instancetype)initWithGrant:(SPDFMacFriendsChatGrant*)grant show:(void (^)(SPDFMacFriendsGrantBar*))show {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 320, 30)])) return nil;
    _grant = grant;
    _show = [show copy];
    self.identifier = SPDFMacFriendsGrantBarIdentifier;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 7;
    self.toolTip = kDetail;
    self.accessibilityRole = NSAccessibilityGroupRole;
    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:12];
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    // The group carries the whole sentence for VoiceOver, whichever text fits on screen.
    _label.accessibilityElement = NO;
    [_label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    _stopButton = [NSButton buttonWithTitle:@"Stop now" target:self action:@selector(stopNow:)];
    _stopButton.controlSize = NSControlSizeSmall;
    _stopButton.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _stopButton.bezelStyle = NSBezelStyleRounded;
    _stopButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_label];
    [self addSubview:_stopButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:30],
        [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_label.trailingAnchor constraintLessThanOrEqualToAnchor:_stopButton.leadingAnchor constant:-8],
        [_stopButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_stopButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    __weak SPDFMacFriendsGrantBar* weakSelf = self;
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:SPDFMacFriendsChatGrantDidChangeNotification
        object:grant queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* note) {
        (void)note;
        [weakSelf refresh];
    }];
    [self refresh];
    return self;
}

- (void)dealloc { [self uninstall]; }

- (void)uninstall {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
    _observer = nil;
}

- (BOOL)isFlipped { return YES; }

// The sentence when it fits beside Stop now; otherwise the short text, so a narrow chat still shows the time left.
- (void)layout {
    [super layout];
    [self fitLabel];
}

- (void)fitLabel {
    NSString* full = SPDFMacFriendsGrantBarText(_grant);
    NSString* text = full ?: @"";
    if (full) {
        CGFloat room = NSWidth(self.bounds) - 10 - 8 - 6 - _stopButton.fittingSize.width;
        NSTextFieldCell* probe = [_label.cell copy];
        probe.stringValue = full;
        CGFloat needed = [probe cellSizeForBounds:NSMakeRect(0, 0, CGFLOAT_MAX, 30)].width;
        if (needed > room) text = SPDFMacFriendsGrantBarShortText(_grant);
    }
    if (![_label.stringValue isEqualToString:text]) _label.stringValue = text;
}

- (void)updateLayer {
    self.layer.backgroundColor = [SPDFCollectionColor(@"focus") colorWithAlphaComponent:0.14].CGColor;
}

- (BOOL)wantsUpdateLayer { return YES; }

- (void)refresh {
    NSString* text = SPDFMacFriendsGrantBarText(_grant);
    [self fitLabel];
    self.accessibilityLabel = text;
    self.toolTip = text ? [NSString stringWithFormat:@"%@.\n%@", text, kDetail] : kDetail;
    _label.toolTip = self.toolTip;
    if (_show) _show(text ? self : nil);
}

- (void)stopNow:(id)sender {
    (void)sender;
    [_grant stop];
    [self refresh];
}

@end
