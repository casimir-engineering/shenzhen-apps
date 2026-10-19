// Shenzhen Friends mentions: the form a mention takes inside a message's text, read and written in one place
// (PROTOCOL.md § Mentions, ADR 0007).
//
// A mention travels in the message text as a Markdown link with Friends' own scheme:
//
//     [@Mei Lin](szfriends:mention?id=jasmine-street&key=C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E)
//
// The link text is "@" and the name the sender sees for that person, Markdown-escaped; the destination carries their
// Friends ID and identity key (32 bytes, base64url without padding). Kept inside the text, a message stays one string
// for the store, search and the session frame. Only a sending helper writes this form, from the friends the composer
// named (views never write IDs or keys); every reader resolves it against its own Friends list, so a sender cannot make
// a stranger look like a friend, and a receiving helper turns every Friends link that is not a well-formed mention into
// plain text before storing it.
//
// Foundation only: the helper's router, its nearby service and the presentation builder all use it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// At most this many mentions in one message; the receiving helper shows any beyond them as plain text.
extern const NSUInteger SZFriendsMentionsMax;
// A mention's name is at most this many characters (Unicode scalar values), so a label cannot fill a screen.
extern const NSUInteger SZFriendsMentionNameMax;
// Where send_message's text puts each mention, in the order of its `mentions` array: U+FFFC OBJECT REPLACEMENT
// CHARACTER, the character both AppKit and GTK text views already use for an inline chip.
extern NSString *const SZFriendsMentionPlaceholder;

// One link to Friends' own scheme found in a text: a mention, or anything else that points at szfriends:.
@interface SZFriendsTextLink : NSObject
@property(nonatomic, readonly) NSRange range;               // the whole link in the text it was found in
// The words a renderer would show for it, unescaped: an inline link's text ("@Mei Lin"), an autolink's address, or a
// reference definition's whole line. Plain text in their place keeps what the sender meant to say.
@property(nonatomic, readonly, copy) NSString *shownText;
// Set only for a well-formed mention: the name without its "@", the Friends ID as written, the 32-byte key.
@property(nonatomic, readonly, copy, nullable) NSString *name;
@property(nonatomic, readonly, copy, nullable) NSString *friendsID;
@property(nonatomic, readonly, copy, nullable) NSData *identityKey;
@property(nonatomic, readonly) BOOL isMention;
@end

// Every link to szfriends: in `text`, in order: inline links, autolinks, link reference definitions, wikilinks and
// HTML tags, with the scheme as a renderer reads it (a backslash before ":", character references such as "&#58;").
NSArray<SZFriendsTextLink *> *SZFriendsTextLinks(NSString *text);

// The well-formed mention link for one person, or nil when the name is empty or too long, the ID is not two or three
// words, or the key is not 32 bytes.
NSString *_Nullable SZFriendsMentionLink(NSString *name, NSString *friendsID, NSData *identityKey);

// What a mention calls someone the sender sees as `name` and `friendsID`: the name, trimmed, or else the Friends ID
// with U+2011 between its words, as Friends shows IDs; cut to SZFriendsMentionNameMax characters.
NSString *SZFriendsMentionName(NSString *_Nullable name, NSString *_Nullable friendsID);

// An arriving message: every Friends link kept only if it is a well-formed mention whose ID `validID` accepts (the
// helper passes its word list) and among the first SZFriendsMentionsMax; everything else becomes plain text.
NSString *SZFriendsMentionsChecked(NSString *text, BOOL (^validID)(NSString *friendsID));
// What a person typed into the composer: every Friends link becomes plain text, so the only mentions a message
// carries are the ones its helper writes from send_message's `mentions`.
NSString *SZFriendsMentionsNeutralized(NSString *text);

// Markdown that shows `plain` exactly: the punctuation that could start emphasis, a link, code, math or HTML is
// backslash-escaped.
NSString *SZFriendsMarkdownLiteral(NSString *plain);

// A key as mentions and add_from_mention carry it (base64url, no padding), and back; nil unless exactly 32 bytes in
// the canonical 43-character form.
NSString *SZFriendsMentionKeyString(NSData *identityKey);
NSData *_Nullable SZFriendsMentionKeyFromString(NSString *text);

NS_ASSUME_NONNULL_END
