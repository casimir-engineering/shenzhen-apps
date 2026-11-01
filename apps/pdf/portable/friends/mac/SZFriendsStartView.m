// SZFriendsStartView: what the dropdown shows until Friends answers for the first time, or when it did not start.

#import "mac/SZFriendsDropdownInternal.h"

// Written for the person who opened Friends and sees nothing of it yet. While it starts they wonder whether
// anything is happening: a spinner and the client library's line ("Starting Friends…"). When it did not start they
// wonder what to do: one line and Try Again. Never how Friends works inside. English, as the client library's lines
// are: no helper is there to supply strings in its catalog.
static NSString *const SZFStartFailedText = @"Friends couldn’t start.";
static NSString *const SZFStoppedText = @"Friends stopped working.";
static NSString *const SZFStartingText = @"Starting Friends…";
static NSString *const SZFTryAgainTitle = @"Try Again";

@implementation SZFriendsStartView {
    SZFriendsAppearance *_appearance;
    NSProgressIndicator *_spinner;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 400, 400)])) return nil;
    _appearance = context.appearance;
    self.fillColor = _appearance.backgroundColor;
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 24, 24)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeRegular;
    _spinner.displayedWhenStopped = NO;
    [self addSubview:_spinner];
    _textLabel = SZFriendsLabel(SZFStartingText, _appearance.bodyFont, _appearance.secondaryTextColor);
    _textLabel.alignment = NSTextAlignmentCenter;
    [self addSubview:_textLabel];
    _tryAgainButton = [SZFriendsButton buttonWithTitle:SZFTryAgainTitle style:SZFriendsButtonStylePrimary
                                            appearance:_appearance];
    __weak SZFriendsStartView *weakSelf = self;
    _tryAgainButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsStartView *view = weakSelf;
        if (view.onTryAgain) view.onTryAgain();
    };
    [self addSubview:_tryAgainButton];
    return self;
}

- (void)showLink:(SZFriendsHelperLink *)link {
    BOOL incompatible = link.state == SZFriendsLinkStateIncompatible;
    _failed = link.stalled && link.state != SZFriendsLinkStateReady && !incompatible;
    NSString *text;
    if (_failed) text = link.wasReady ? SZFStoppedText : SZFStartFailedText;
    else text = link.statusText.length ? link.statusText : SZFStartingText;
    _textLabel.stringValue = text;
    // A line that asks something of the person (update this app) reads as text, not as a quiet status.
    _textLabel.textColor = _failed || incompatible ? _appearance.primaryTextColor : _appearance.secondaryTextColor;
    _textLabel.font = _failed ? SZFriendsSemibold(_appearance.bodyFont) : _appearance.bodyFont;
    _tryAgainButton.hidden = !_failed;
    BOOL spinning = !_failed && !incompatible;
    if (spinning) [_spinner startAnimation:nil];
    else [_spinner stopAnimation:nil];
    _spinner.hidden = !spinning;
    [self setNeedsLayout:YES];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    if (hidden) [_spinner stopAnimation:nil];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), inner = MIN(width - 48, 300);
    CGFloat textHeight = SZFriendsFieldHeight(_textLabel, inner);
    CGFloat height = textHeight;
    if (!_spinner.hidden) height += 24 + 12;
    if (!_tryAgainButton.hidden) height += 14 + 28;
    // A third of the way down, where the confirmation card sits, not dead centre.
    CGFloat y = floor(MAX(16, (NSHeight(self.bounds) - height) / 3));
    if (!_spinner.hidden) {
        _spinner.frame = NSMakeRect(floor((width - 24) / 2), y, 24, 24);
        y += 24 + 12;
    }
    _textLabel.frame = NSMakeRect(floor((width - inner) / 2), y, inner, textHeight);
    y += textHeight + 14;
    CGFloat buttonWidth = MAX(96, [_tryAgainButton fittingWidth]);
    _tryAgainButton.frame = NSMakeRect(floor((width - buttonWidth) / 2), y, buttonWidth, 28);
}

// Clicks around the text land here, not on the page underneath.
- (void)mouseDown:(NSEvent *)event {
    (void)event;
}

@end
