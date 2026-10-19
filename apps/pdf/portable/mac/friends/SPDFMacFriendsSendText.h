// The text of a message the assistant prepares for a friend, made so that the card the person approves shows every
// character Friends will deliver (ai-agent-capabilities.md § 1, "The person sends").
//
// The card shows the text literally, as plain wrapping text, so no Markdown can hide a part of it. A character can
// still be there and not be seen: zero-width and other invisible format characters, Unicode tag characters,
// stacked variation selectors, private-use and unassigned code points, blank-looking fillers, and spaces at the end
// of a line all draw nothing, yet a friend's app can read them back. A friend's planted instruction could have the
// model hide document text in them inside a message the person approves. So what draws the same either way is made
// one way (line breaks, the different widths of space, trailing spaces, runs of blank lines), and a message that
// still holds an invisible character is refused, never cleaned: the model writes it again and the person sees what
// goes. What the person reads on the card, Send queues, and the friend receives, are then the same characters.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// `text` with what draws the same either way made one way: composed (NFC), so "e" with U+0301 becomes "é" and the
// Angstrom sign "Å"; compatibility spellings that draw like their letters (ﬁ, µ, ĳ, Arabic and Hebrew presentation
// forms) become those letters (NFKC for them only), U+2010 and U+2011 become "-", and Thai and Lao sara am written in
// two parts becomes the one character; CR, CRLF and the Unicode line and paragraph separators become "\n"; every space
// separator but U+0020 and the ideographic space becomes U+0020; spaces and tabs at the end of a line go; three or more
// line breaks in a row become two (Markdown shows one blank line either way). nil, and *refusal written for the
// model, when it holds a character the card cannot show, or a combining mark (Mn, Mc, Me) of another script than its
// letter's (SPDFMacFriendsMarkFitsLetter; a Quranic pause or annotation mark may also stand on a space), its letter
// already carries, or that would be a fifth on it. What changes how the characters beside it draw stays (the tables
// are in SPDFMacFriendsEmojiTables.h): a presentation selector after a base Unicode's emoji-variation-sequences.txt
// lists (after a keycap base only right before U+20E3); a zero-width joiner between Extended_Pictographic code points,
// past the first one's own seen selector or skin tone, or in an Indic conjunct (after a virama before a consonant of
// its block, or after such a consonant before the virama and a consonant); a zero-width non-joiner between a
// dual-joining letter and a dual- or right-joining one, or after a virama before a consonant of its block. Tag
// characters are always refused.
// The same rule marks characters on the card (SPDFMacAIActivityVisibleText); both run the cases in
// friends/fixtures/text/invisible-cases.json.
NSString* _Nullable SPDFMacFriendsVisibleText(NSString* text, NSString* _Nullable* _Nullable refusal);

// A `/` draft for the composer, where the person edits and sends it as their own: made one way like the above, with
// every character that draws nothing, and every mark the rule above refuses, removed rather than refused, and
// composed again after. Without this a friend's
// planted instruction could have the model hide document text in a draft the person sends without seeing it.
NSString* SPDFMacFriendsDraftText(NSString* text);

// `text` as a friend receives it: links to the person's own documents and chats (anything but http, https and
// mailto) become their plain label, because the friend's app cannot open them.
NSString* SPDFMacFriendsTextForFriend(NSString* text);

NS_ASSUME_NONNULL_END
