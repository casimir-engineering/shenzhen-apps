// Shenzhen Friends conversation: history, transfer cards, the composer, the `#` picker, conversation search and
// the request card (internal).

#import "mac/SZFriendsDrops.h"
#import "mac/SZFriendsPage.h"

NS_ASSUME_NONNULL_BEGIN

// One history item (PROTOCOL.md item): day separator, message, transfer card or event.
@interface SZFriendsItemView : SZFriendsFlippedView
+ (instancetype)viewForItem:(NSDictionary *)item context:(SZFriendsContext *)context;
@property(nonatomic, copy, readonly) NSString *itemID;
@property(nonatomic, copy, readonly) NSString *itemKind;
@property(nonatomic, readonly) BOOL highlighted;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *actionButtons;
@property(nonatomic, strong, readonly, nullable) NSView *progressView;
- (void)applyItem:(NSDictionary *)item;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

// The message list: a scroll view that is also the conversation's drop target (files dropped here are sent at once).
@interface SZFriendsMessageList : NSScrollView
- (instancetype)initWithContext:(SZFriendsContext *)context;
@property(nonatomic, readonly) SZFriendsDropHighlight dropHighlight;
// The words over the list while it refuses a drag (drop_folders_refused, drop_not_a_file); "" otherwise.
@property(nonatomic, copy, readonly) NSString *dropRefusal;
// The plate those words are drawn on, as last drawn, in the list's coordinates; NSZeroRect without one (tests).
@property(nonatomic, readonly) NSRect dropRefusalRect;
@property(nonatomic) BOOL acceptsDrops;
@property(nonatomic, copy, nullable) void (^onDropItems)(NSArray<SZFriendsAttachableItem *> *items);
@end

// `#`: a searchable list of the host's attachable items over the composer. Selecting one adds a chip; it sends
// nothing. Up and Down move, Return attaches, Escape closes it (and only it).
@interface SZFriendsAttachPicker : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
@property(nonatomic, strong, readonly) NSSearchField *searchField;
@property(nonatomic, copy, readonly) NSArray<SZFriendsAttachableItem *> *items;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *itemButtons;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy, nullable) void (^onChoose)(SZFriendsAttachableItem *item);
@property(nonatomic, copy, nullable) void (^onClose)(void);
- (void)reloadForQuery:(NSString *)query;
- (void)chooseSelected;
- (CGFloat)preferredHeight;
@end

// Conversation search results: excerpts with matches emphasised; choosing one jumps to that exact message.
@interface SZFriendsSearchResultsView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyResult:(NSDictionary *)result; // PROTOCOL.md result.search_messages
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *resultButtons;
@property(nonatomic, copy, nullable) void (^onChoose)(NSString *conversationID, NSString *messageID);
- (CGFloat)preferredHeight;
@end

// The composer's `/` state: typing `/` into an empty composer turns it into a command for the host's assistant.
typedef NS_ENUM(NSInteger, SZFriendsCommandState) {
    SZFriendsCommandStateOff = 0, // a message to the friend
    SZFriendsCommandStateEditing, // the field holds a command; Return or the arrow runs it, Escape leaves it
    SZFriendsCommandStateRunning, // the assistant is working: a progress row with Cancel
};

@class SZFriendsComposerCommand;

// The composer: Return sends, Shift+Return inserts a line; `#` opens the picker; dropped files become chips; `/`
// asks the host's assistant (SZFriendsComposerInternal.h).
@interface SZFriendsComposerView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context conversationID:(NSString *)conversationID;
- (void)applyComposer:(NSDictionary *)composer; // PROTOCOL.md composer
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, strong, readonly) NSTextView *textView;
@property(nonatomic, strong, readonly) SZFriendsButton *sendButton;
@property(nonatomic, copy, readonly) NSArray<SZFriendsAttachableItem *> *attachments;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *chipButtons;
@property(nonatomic, readonly) SZFriendsDropHighlight dropHighlight;
// The input's box and the `#` / drop hint under it (tests check the disabled look).
@property(nonatomic, strong, readonly) SZFriendsFlippedView *inputBox;
@property(nonatomic, strong, readonly) NSTextField *hintLabel;
@property(nonatomic, copy, nullable) void (^onOpenAttachPicker)(void);
// `@` typed where a word starts, while the composer is enabled, holds a message and the helper takes mentions.
@property(nonatomic, copy, nullable) void (^onOpenMentionPicker)(void);
@property(nonatomic, copy, readonly, nullable) NSString *mentionNote; // composer.mention_note, under the `@` picker
@property(nonatomic, copy, nullable) void (^onHeightChange)(void);
// A chip for one friend at the insertion point, in place of the `@` typed to open the picker (SZFriendsMentionViews.h).
- (void)insertMentionForConversation:(NSString *)conversationID label:(NSString *)label;
- (void)addAttachments:(NSArray<SZFriendsAttachableItem *> *)items;
- (void)removeAttachmentAtIndex:(NSUInteger)index;
- (void)send;
@property(nonatomic, readonly) SZFriendsCommandState commandState;
// nil when the host has no assistant: `/` is then plain text.
@property(nonatomic, strong, readonly, nullable) SZFriendsComposerCommand *command;
- (BOOL)leaveCommand; // Escape: YES when it closed the command field (what was typed stays as "/<text>")
@end

// A pending request: the comparison code both screens show, with Accept, Decline and Block (or Cancel request).
@interface SZFriendsRequestCardView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyRequest:(NSDictionary *)request conversationID:(NSString *)conversationID;
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *actionButtons;
@end

@interface SZFriendsConversationPage : SZFriendsPage
- (instancetype)initWithContext:(SZFriendsContext *)context
                 conversationID:(NSString *)conversationID
               highlightMessage:(nullable NSString *)messageID;
@property(nonatomic, copy, readonly) NSString *conversationID;
@property(nonatomic, strong, readonly) SZFriendsHeaderView *header;
@property(nonatomic, strong, readonly) NSSearchField *searchField;
@property(nonatomic, strong, readonly) SZFriendsMessageList *messageList;
// Above the oldest item while `has_earlier` (welcome string `load_earlier`); scrolling to the top loads too.
@property(nonatomic, strong, readonly) SZFriendsButton *loadEarlierButton;
@property(nonatomic, copy, readonly) NSArray<SZFriendsItemView *> *itemViews;
@property(nonatomic, strong, readonly) SZFriendsComposerView *composer;
@property(nonatomic, strong, readonly) SZFriendsRequestCardView *requestCard;
@property(nonatomic, strong, readonly, nullable) SZFriendsAttachPicker *attachPicker;
@property(nonatomic, strong, readonly, nullable) SZFriendsSearchResultsView *searchResults;
@property(nonatomic, readonly) BOOL holdsSubscription;
- (void)highlightMessage:(NSString *)messageID;
- (void)openAttachPicker;
- (void)runSearch;
@end

NS_ASSUME_NONNULL_END
