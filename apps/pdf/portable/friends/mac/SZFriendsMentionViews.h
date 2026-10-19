// Shenzhen Friends mentions in the AppKit views (internal): `@` chips in the composer, the `@` picker over it, mention
// links in bubbles and the card a stranger's mention opens (PROTOCOL.md § Mentions, brief § Interface, Mentions).
//
// Views never write IDs or keys: a chip names a friend by conversation_id and the helper writes the mention in its
// place; a bubble matches a click by comparing the link with mentions[n].url and never parses it. `@` is offered only
// while the helper announces `mentions`, since an older helper would send each chip as a bare U+FFFC.

#import "mac/SZFriendsConversationPage.h"

NS_ASSUME_NONNULL_BEGIN

// The helper announces `mentions`: it writes chips as mentions and answers add_from_mention.
BOOL SZFriendsHelperTakesMentions(SZFriendsContext *context);

#pragma mark - Composer

// One `@` chip in the composer's text: an attachment character drawn as a pill reading its label ("@Mei Lin").
@interface SZFriendsMentionChip : NSTextAttachment
@property(nonatomic, copy, readonly) NSString *conversationID;
@property(nonatomic, copy, readonly) NSString *label;
// The chip as the composer inserts it: one attachment character in the composer's font and colour.
+ (NSAttributedString *)chipForConversation:(NSString *)conversationID
                                      label:(NSString *)label
                                 appearance:(SZFriendsAppearance *)appearance;
@end

// What Send sends for the composer's text. Each chip becomes U+FFFC with one `{conversation_id}` in `*mentions`, in
// order. Any other U+FFFC (pasted, not a chip) stays as typed when there is no chip and is dropped when there is one,
// since the helper requires one U+FFFC per mention. A helper without `mentions` gets each chip as its label.
NSString *SZFriendsComposerMessage(NSAttributedString *text, BOOL helperTakesMentions,
                                   NSArray<NSDictionary *> *_Nullable *_Nonnull mentions);
BOOL SZFriendsTextHoldsMentionChip(NSAttributedString *text);

#pragma mark - Bubbles

// A message's segments joined with each mention's link source left out: what decides whether the host's Markdown
// engine draws anything that plain segments would not.
NSString *SZFriendsTextOutsideMentions(NSArray *segments);
// Links each segment that carries `mention` n (plain text, as SZFriendsRichText laid the segments out) to
// mentions[n].url, so plain text and the host's rendering reach SZFriendsStyleMentions alike.
void SZFriendsLinkMentionSegments(NSMutableAttributedString *text, NSArray *segments, NSArray *mentions);
// Draws every link that is one of `mentions` as that mention: a friend's or a stranger's as a link in the accent
// colour with the mention's tooltip, the reader's own highlighted with nothing to click. Any other `szfriends:` link,
// and a mention of a kind this view does not know, becomes plain text.
void SZFriendsStyleMentions(NSMutableAttributedString *text, NSArray *mentions, SZFriendsAppearance *appearance);
// The mention a link names: the entry whose url is the link's destination, character for character, and whose
// label is the link's words, so a second link to the same destination under other words names nobody. nil otherwise.
NSDictionary *_Nullable SZFriendsMentionForLink(id _Nullable link, NSString *words, NSArray *mentions);
BOOL SZFriendsIsFriendsLink(id _Nullable link); // the szfriends: scheme, which nothing but a mention may act on
// A click on a Friends link at `charIndex` in a bubble's `textView`: a friend's mention opens the reader's chat with
// them, a stranger's opens their card under the link (the conversation page around it shows it); anything else does
// nothing. `mentions` and `itemID` are the message's.
void SZFriendsOpenMentionLink(SZFriendsContext *_Nullable context, id _Nullable link, NSTextView *textView,
                              NSUInteger charIndex, NSArray *mentions, NSString *itemID);

#pragma mark - The `@` picker

// A searchable list of the friends a mention may name, over the composer: a second `list` subscription whose filter
// follows the search field, showing rows whose `mentionable` is true, with the composer's mention_note under it.
// Choosing one adds a chip; it sends nothing. Up and Down move, Return chooses, Escape closes it (and only it).
@interface SZFriendsMentionPicker : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context note:(nullable NSString *)note;
@property(nonatomic, strong, readonly) NSSearchField *searchField;
@property(nonatomic, strong, readonly) NSTextField *noteLabel;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *rows; // the mentionable rows shown, best first
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *rowButtons;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy, nullable) void (^onChoose)(NSDictionary *row);
@property(nonatomic, readonly) BOOL subscribed;
- (void)start; // subscribes; the dropdown keeps it only while the picker is open
- (void)stop;
- (void)applyList:(NSDictionary *)data; // PROTOCOL.md snapshot.list data
- (void)chooseSelected;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

#pragma mark - A stranger's card

// What a click on a stranger's mention opens: the name the sender wrote, shown literally (characters that draw
// nothing show as their code point, as on a proposal), "Friends ID …", the status and the card's actions; after an
// action, the helper's words about it.
@interface SZFriendsMentionCardView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyMention:(NSDictionary *)mention; // PROTOCOL.md mention object of kind stranger
@property(nonatomic, copy, readonly, nullable) NSDictionary *mention;
@property(nonatomic, copy, nullable) NSString *itemID; // the message it came from
@property(nonatomic, strong, readonly) NSTextField *titleLabel;
@property(nonatomic, strong, readonly) NSTextField *idLabel;
@property(nonatomic, strong, readonly) NSTextField *statusLabel;
@property(nonatomic, strong, readonly) NSTextField *resultLabel;
@property(nonatomic, copy, readonly) NSArray<SZFriendsButton *> *actionButtons;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

#pragma mark - The conversation's mention overlays (SZFriendsConversationMentions.m)

@interface SZFriendsConversationPage ()
@property(nonatomic, strong, nullable) SZFriendsMentionPicker *mentionPicker;
@property(nonatomic, strong, nullable) SZFriendsMentionCardView *mentionCard;
- (void)closeAttachPicker; // one picker over the composer at a time
@end

@interface SZFriendsConversationPage (SZFriendsMentionViews)
- (void)openMentionPicker;
- (void)closeMentionPicker;
// A click on a stranger's mention: the card under the link (`anchor`, in the page's coordinates), above it when there
// is no room below. A click anywhere else in the page, a scroll or Escape closes it.
- (void)showMentionCard:(NSDictionary *)mention itemID:(NSString *)itemID anchor:(NSRect)anchor;
- (void)closeMentionCard;
// After a snapshot: the open card follows its mention, and closes when the message no longer shows it as a stranger.
- (void)refreshMentionCard;
- (BOOL)dismissMentionOverlay; // Escape: the card, then the picker; YES when one closed
- (void)layoutMentionOverlaysAbove:(CGFloat)composerTop;
@end

NS_ASSUME_NONNULL_END
