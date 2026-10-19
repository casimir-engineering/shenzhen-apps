// The `@` scope chip in AI chat's composer, as text: what a message brought in, and what the composer says about it.
//
// A chip is an attachment character in the composer's text carrying its SPDFMacFriendsScopeRequest. When the
// message is sent, each chip becomes "@Name" in the text the model reads, and the chips' union becomes that one
// request's scope (brief § AI boundaries: "What did @Mei say about delivery dates?"). The chips go when the
// composer clears, so a follow-up message has no scope unless the person adds a chip again.

#import <AppKit/AppKit.h>
#import "SPDFMacAIRequestContext.h"
#import "SPDFMacFriendsChatScope.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsAllChatsChoiceID; // "all"

@interface SPDFMacFriendsScopeToken : NSTextAttachment
@property(nonatomic, readonly) SPDFMacFriendsScopeRequest* scope;
@property(nonatomic, readonly, copy) NSString* label; // "Mei", "All Friends chats"
// One attachment character drawn as a chip reading "@label", sized to sit on `font`'s baseline.
+ (NSAttributedString*)chipWithScope:(SPDFMacFriendsScopeRequest*)scope font:(NSFont*)font;
@end

// A file the person attached to this one message: a `#` choice (bound to the exact revision on screen) or a dropped
// file. It reads "#Title" to the model, and the request carries it as a chip, so it is one of the files a send in
// that request may carry (SPDFMacFriendsSendRules.h). Like `@` chips, it goes when the composer clears.
@interface SPDFMacFriendsFileToken : NSTextAttachment
@property(nonatomic, readonly) SPDFMacAIRequestChip* file; // document or attachment kind
+ (NSAttributedString*)chipWithFile:(SPDFMacAIRequestChip*)file font:(NSFont*)font;
@end

// A `#` item or a dropped file as a request chip: a document chip when it carries a revision, else an attachment.
// nil without a file URL.
SPDFMacAIRequestChip* _Nullable SPDFMacFriendsFileChip(NSURL* _Nullable fileURL, NSString* _Nullable title,
                                                       NSDictionary<NSString*, id>* _Nullable revision);
// The `#` picker's choices for the host's attachable items ({"id", "name", "file"}), in the host's order.
NSArray<NSDictionary<NSString*, id>*>* SPDFMacFriendsFileChoices(NSArray<SZFriendsAttachableItem*>* items);
// The file chips in `text`, in order.
NSArray<SPDFMacAIRequestChip*>* SPDFMacFriendsFileChipsInText(NSAttributedString* text);
// YES when `text` holds any chip, `@` or file.
BOOL SPDFMacFriendsTextHasChips(NSAttributedString* text);

// The picker's choices from a Friends `list` snapshot's rows: All Friends chats first, then each friend by name.
// Incoming friend requests are left out, since there is no conversation to read yet. Each choice is
// {"id": conversation id or "all", "name": display name}.
NSArray<NSDictionary<NSString*, NSString*>*>* SPDFMacFriendsScopeChoices(NSArray<NSDictionary*>* rows);
SPDFMacFriendsScopeRequest* _Nullable SPDFMacFriendsScopeForChoice(NSDictionary<NSString*, NSString*>* choice);

// YES when an "@" was just typed at `caret` (the character before the caret) at the start of a word, so the picker
// opens; an "@" inside an email address or a word does not.
BOOL SPDFMacFriendsCaretFollowsMentionTrigger(NSString* text, NSUInteger caret);
// The same for any trigger character ("#" opens the file picker).
BOOL SPDFMacFriendsCaretFollowsTrigger(NSString* text, NSUInteger caret, unichar trigger);

// The union of every chip in `text`, or nil when it has none.
SPDFMacFriendsScopeRequest* _Nullable SPDFMacFriendsScopeInText(NSAttributedString* text);
// `text` with each chip written as "@label" or "#Title", trimmed: what the assistant receives and what the chat
// history keeps.
NSString* SPDFMacFriendsPlainTextReplacingChips(NSAttributedString* text);

// The composer's note while chips are present, written for the person about to send; nil without a scope. For
// friends named one by one the assistant may also write messages, which the person sends (SPDFMacFriendsSendRules.h);
// All Friends chats is for reading only, so the note says so only for named friends.
NSString* _Nullable SPDFMacFriendsScopeNote(SPDFMacFriendsScopeRequest* _Nullable scope);
// The note for the composer's text: its chips' scope, naming as recipients only the friends chosen one by one, so
// "All Friends chats" beside "@Mei" says the assistant may write to Mei and to no one else.
NSString* _Nullable SPDFMacFriendsComposerNote(NSAttributedString* text);

typedef BOOL (^SPDFMacFriendsSendText)(NSString* text);

// Ties one AI chat session's requests to the gate. -sendTextWrapping: wraps the chat view's sendText: it reads the
// chips from the composer, begins the gate's request with their scope (or with none) and the time grant running
// now, if any (SPDFMacFriendsChatGrant.h), sends "@Name" and "#Title"
// text in their place, and ends the request again if the reader refused to send. -sessionDidChange (from the session's
// `changed`) ends the request as soon as the session stops running, so the scope never outlives its request.
@interface SPDFMacFriendsChatRequestScoper : NSObject
- (instancetype)initWithGate:(SPDFMacFriendsChatScopeGate*)gate
                     running:(BOOL (^)(void))running
                composerText:(NSAttributedString* _Nullable (^)(void))composerText NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (SPDFMacFriendsSendText)sendTextWrapping:(SPDFMacFriendsSendText)original;
- (void)sessionDidChange;
@end

NS_ASSUME_NONNULL_END
