// The conversation's `#` picker (SZFriendsConversationAttach.h).

#import "mac/SZFriendsConversationAttach.h"
#import "mac/SZFriendsMentionViews.h"

@implementation SZFriendsConversationPage (SZFriendsAttachPicker)

- (void)openAttachPicker {
    if (self.attachPicker || !self.context.host) return;
    [self closeMentionPicker];
    self.attachPicker = [[SZFriendsAttachPicker alloc] initWithContext:self.context];
    // What is typed after the `#` is the query; the composer keeps the focus.
    NSTextView *text = self.composer.textView;
    NSRange selection = text.selectedRange;
    self.attachHash = selection.length == 0 && selection.location > 0 &&
                          [text.string characterAtIndex:selection.location - 1] == '#'
                      ? selection.location - 1
                      : NSNotFound;
    self.attachQuery = @"";
    __weak SZFriendsConversationPage *weakSelf = self;
    self.attachPicker.onChoose = ^(SZFriendsAttachableItem *item) {
        SZFriendsConversationPage *page = weakSelf;
        if (!page) return;
        // The picker called this: it stays until this returns.
        __attribute__((objc_precise_lifetime)) SZFriendsAttachPicker *picker = page.attachPicker;
        (void)picker;
        // The `#` and what was typed after it become the chip.
        NSRange typed = [page attachTypedRange];
        [page closeAttachPicker];
        if (typed.location != NSNotFound) [page.composer.textView insertText:@"" replacementRange:typed];
        [page.composer addAttachments:@[ item ]];
    };
    [self addSubview:self.attachPicker];
    [self.attachPicker reloadForQuery:@""];
    [self layout];
    if (self.window && !self.composer.hidden && self.window.firstResponder != text)
        [self.window makeFirstResponder:text];
}

// The `#` and what follows it up to the insertion point, while the picker follows them; NSNotFound otherwise (the `#`
// was deleted, the insertion point left the word, or a space or a line ended it).
- (NSRange)attachTypedRange {
    NSRange none = NSMakeRange(NSNotFound, 0);
    if (!self.attachPicker || self.attachHash == NSNotFound) return none;
    NSTextView *text = self.composer.textView;
    NSString *string = text.string;
    NSRange selection = text.selectedRange;
    if (self.attachHash >= string.length || [string characterAtIndex:self.attachHash] != '#' || selection.length ||
        selection.location <= self.attachHash)
        return none;
    NSRange typed = NSMakeRange(self.attachHash, selection.location - self.attachHash);
    NSRange query = NSMakeRange(self.attachHash + 1, typed.length - 1);
    if ([string rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet options:0 range:query]
            .location != NSNotFound)
        return none;
    return typed;
}

- (void)followAttachQuery {
    if (!self.attachPicker || self.attachHash == NSNotFound) return;
    NSRange typed = [self attachTypedRange];
    if (typed.location == NSNotFound) {
        [self closeAttachPicker];
        return;
    }
    NSString *query =
        [self.composer.textView.string substringWithRange:NSMakeRange(typed.location + 1, typed.length - 1)];
    if ([query isEqualToString:self.attachQuery]) return;
    self.attachQuery = query;
    [self.attachPicker reloadForQuery:query];
}

- (void)closeAttachPicker {
    if (!self.attachPicker) return;
    [self.attachPicker removeFromSuperview];
    self.attachPicker = nil;
    self.attachHash = NSNotFound;
    if (self.window && !self.composer.hidden && self.window.firstResponder != self.composer.textView)
        [self.window makeFirstResponder:self.composer.textView];
}

@end
