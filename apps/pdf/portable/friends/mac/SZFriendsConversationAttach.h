// The conversation's `#` picker (SZFriendsConversationAttach.m): what is typed after the `#` in the composer is its
// query, and the composer keeps the focus. Choosing a row puts a chip in place of the `#` and those words.

#import "mac/SZFriendsConversationPage.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsConversationPage ()
@property(nonatomic, strong, nullable) SZFriendsAttachPicker *attachPicker;
@property(nonatomic) NSUInteger attachHash;       // where the `#` that opened the picker is; NSNotFound: none typed
@property(nonatomic, copy) NSString *attachQuery; // what follows it, as the picker last asked the host
@end

@interface SZFriendsConversationPage (SZFriendsAttachPickerInternal)
- (void)closeAttachPicker; // one picker over the composer at a time
// The composer's text or insertion point changed: the picker asks the host for what now follows the `#`, or closes
// (the `#` was deleted, the insertion point left the word, or a space or a new line ended it).
- (void)followAttachQuery;
@end

NS_ASSUME_NONNULL_END
