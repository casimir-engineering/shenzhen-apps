// Mentions in message text: finding Friends links and writing a mention (SZFriendsMentions.h, PROTOCOL.md § Mentions).
// SZFriendsMentionChecks.m turns every Friends link that is not a kept mention into plain text.
//
// The search starts from each place a renderer reads as "szfriends:" (escaped, spelled with character references, or
// broken by tabs and line breaks) and looks around it for the link structure, so a message without one costs a
// substring search or two, and a hostile 32 KB message costs a bounded amount of work per occurrence rather than a
// pass per bracket.

#import "service/presentation/SZFriendsMentions.h"

const NSUInteger SZFriendsMentionsMax = 20;
const NSUInteger SZFriendsMentionNameMax = 64;
NSString *const SZFriendsMentionPlaceholder = @"￼";

static NSString *const SZFriendsMentionDestination = @"szfriends:mention?id=";
static NSString *const SZFriendsMentionKeyField = @"&key=";
// How far around an occurrence a link's text and destination are looked for. Honest mentions are under 200 characters;
// the bounds keep a message full of brackets from costing more than a few thousand steps per occurrence.
static const NSUInteger SZFriendsLinkTextMax = 1024;
static const NSUInteger SZFriendsLinkDestinationMax = 2048;
static const NSUInteger SZFriendsKeyCharacters = 43;

@interface SZFriendsTextLink ()
@property(nonatomic, readwrite) NSRange range;
@property(nonatomic, readwrite, copy) NSString *shownText;
@property(nonatomic, readwrite, copy, nullable) NSString *name;
@property(nonatomic, readwrite, copy, nullable) NSString *friendsID;
@property(nonatomic, readwrite, copy, nullable) NSData *identityKey;
@property(nonatomic, readwrite) BOOL isMention;
@end

@implementation SZFriendsTextLink
@end

#pragma mark - Characters

static BOOL IsASCIIPunctuation(unichar c) {
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~');
}

// What could start Markdown structure inside a line: emphasis, code, links, images, HTML, entities, strikethrough,
// tables, math, superscript and highlight in the engines hosts use. Escaping only these keeps ordinary names readable.
static BOOL NeedsEscape(unichar c) {
    switch (c) {
    case '\\': case '`': case '*': case '_': case '[': case ']': case '<': case '>': case '!': case '&': case '~':
    case '|': case '$': case '^': case '=':
        return YES;
    default:
        return NO;
    }
}

NSString *SZFriendsMarkdownLiteral(NSString *plain) {
    NSMutableString *escaped = [NSMutableString stringWithCapacity:plain.length + 8];
    for (NSUInteger i = 0; i < plain.length; i++) {
        unichar c = [plain characterAtIndex:i];
        if (NeedsEscape(c)) [escaped appendString:@"\\"];
        [escaped appendFormat:@"%C", c];
    }
    return escaped;
}

// CommonMark's backslash escapes: before ASCII punctuation the backslash goes; before anything else it stays.
static NSString *Unescaped(NSString *markdown) {
    NSMutableString *plain = [NSMutableString stringWithCapacity:markdown.length];
    for (NSUInteger i = 0; i < markdown.length; i++) {
        unichar c = [markdown characterAtIndex:i];
        if (c == '\\' && i + 1 < markdown.length && IsASCIIPunctuation([markdown characterAtIndex:i + 1])) {
            c = [markdown characterAtIndex:++i];
        }
        [plain appendFormat:@"%C", c];
    }
    return plain;
}

static NSUInteger ScalarCount(NSString *text) {
    return [text lengthOfBytesUsingEncoding:NSUTF32StringEncoding] / 4;
}

static BOOL NameIsValid(NSString *name) {
    if (name.length == 0 || ScalarCount(name) > SZFriendsMentionNameMax) return NO;
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if ([spaces characterIsMember:[name characterAtIndex:0]] ||
        [spaces characterIsMember:[name characterAtIndex:name.length - 1]]) {
        return NO;
    }
    // A name is one line of text: no control characters and no line or paragraph separators.
    NSMutableCharacterSet *refused = [NSCharacterSet.controlCharacterSet mutableCopy];
    [refused addCharactersInString:@"  "];
    return [name rangeOfCharacterFromSet:refused].location == NSNotFound;
}

// Two or three words of 3 to 8 lowercase letters (ADR 0006 rule 1); the word list itself is the helper's to check.
static BOOL IDIsWellFormed(NSString *friendsID) {
    NSArray<NSString *> *words = [friendsID componentsSeparatedByString:@"-"];
    if (words.count < 2 || words.count > 3) return NO;
    for (NSString *word in words) {
        if (word.length < 3 || word.length > 8) return NO;
        for (NSUInteger i = 0; i < word.length; i++) {
            unichar c = [word characterAtIndex:i];
            if (c < 'a' || c > 'z') return NO;
        }
    }
    return YES;
}

#pragma mark - Keys

NSString *SZFriendsMentionKeyString(NSData *identityKey) {
    NSString *base64 = [identityKey base64EncodedStringWithOptions:0];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [base64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

NSData *SZFriendsMentionKeyFromString(NSString *text) {
    if (text.length != SZFriendsKeyCharacters) return nil;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        BOOL alphabet = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' ||
                        c == '_';
        if (!alphabet) return nil;
    }
    NSString *standard = [[text stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_"
                                  withString:@"/"];
    NSData *key = [[NSData alloc] initWithBase64EncodedString:[standard stringByAppendingString:@"="] options:0];
    // Canonical only: the last character's two spare bits must be zero, so one key has exactly one spelling and two
    // mentions of one person compare equal as text.
    if (key.length != 32 || ![SZFriendsMentionKeyString(key) isEqualToString:text]) return nil;
    return key;
}

#pragma mark - Writing

NSString *SZFriendsMentionName(NSString *name, NSString *friendsID) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *chosen = trimmed.length ? trimmed : [friendsID stringByReplacingOccurrencesOfString:@"-"
                                                                                       withString:@"‑"] ?: @"";
    if (ScalarCount(chosen) <= SZFriendsMentionNameMax) return chosen;
    // Cut on a composed character, never through one, below the limit.
    NSMutableString *cut = [NSMutableString string];
    [chosen enumerateSubstringsInRange:NSMakeRange(0, chosen.length)
                               options:NSStringEnumerationByComposedCharacterSequences
                            usingBlock:^(NSString *piece, NSRange range, NSRange enclosing, BOOL *stop) {
                              (void)range;
                              (void)enclosing;
                              if (ScalarCount(cut) + ScalarCount(piece) > SZFriendsMentionNameMax) *stop = YES;
                              else [cut appendString:piece];
                            }];
    return [cut stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *SZFriendsMentionLink(NSString *name, NSString *friendsID, NSData *identityKey) {
    if (!NameIsValid(name) || !IDIsWellFormed(friendsID) || identityKey.length != 32) return nil;
    return [NSString stringWithFormat:@"[%@](%@%@%@%@)", SZFriendsMarkdownLiteral([@"@" stringByAppendingString:name]),
                                      SZFriendsMentionDestination, friendsID, SZFriendsMentionKeyField,
                                      SZFriendsMentionKeyString(identityKey)];
}

#pragma mark - Finding links

// HTML tag readings (HTMLTag): a state is a quote (none, double, single) and whether an "=" has come.
enum { Outside, InDouble, InSingle, Quotes, TagStates = 2 * Quotes };

// The text as UTF-16 units with, for each, whether a backslash escapes it (so looking backward from an occurrence never
// recounts a run of backslashes), and the tag readings open at `tags.position`, carried forward as occurrences come.
typedef struct {
    const unichar *chars;
    const BOOL *escaped;
    NSUInteger length;
    struct {
        NSUInteger position, open[TagStates];
    } tags;
} SZFriendsScan;

static BOOL IsUnescaped(SZFriendsScan *scan, NSUInteger index, unichar c) {
    return index < scan->length && scan->chars[index] == c && !scan->escaped[index];
}

// The unescaped "[" matching the unescaped "]" at `close`, within SZFriendsLinkTextMax, or NSNotFound.
static NSUInteger OpeningBracket(SZFriendsScan *scan, NSUInteger close) {
    NSInteger depth = 0;
    NSUInteger floor = close > SZFriendsLinkTextMax ? close - SZFriendsLinkTextMax : 0;
    for (NSUInteger i = close; i > floor; i--) {
        NSUInteger j = i - 1;
        if (scan->escaped[j]) continue;
        if (scan->chars[j] == ']') depth++;
        else if (scan->chars[j] == '[') {
            if (depth == 0) return j;
            depth--;
        }
    }
    return NSNotFound;
}

static NSString *Substring(SZFriendsScan *scan, NSUInteger from, NSUInteger to) {
    return [NSString stringWithCharacters:scan->chars + from length:to - from];
}

// The well-formed mention whose destination starts at `start`, preceded by "](" and the link text at `open`; nil when
// anything differs from what SZFriendsMentionLink writes.
static SZFriendsTextLink *_Nullable StrictMention(SZFriendsScan *scan, NSUInteger open, NSUInteger close,
                                                   NSUInteger start) {
    NSUInteger prefix = SZFriendsMentionDestination.length;
    if (start + prefix > scan->length) return nil;
    if (![Substring(scan, start, start + prefix) isEqualToString:SZFriendsMentionDestination]) return nil;
    NSUInteger idEnd = start + prefix;
    while (idEnd < scan->length && idEnd - start < 64 &&
           ((scan->chars[idEnd] >= 'a' && scan->chars[idEnd] <= 'z') || scan->chars[idEnd] == '-')) {
        idEnd++;
    }
    NSUInteger keyStart = idEnd + SZFriendsMentionKeyField.length, keyEnd = keyStart + SZFriendsKeyCharacters;
    if (keyEnd >= scan->length || ![Substring(scan, idEnd, keyStart) isEqualToString:SZFriendsMentionKeyField] ||
        scan->chars[keyEnd] != ')') {
        return nil;
    }
    NSString *friendsID = Substring(scan, start + prefix, idEnd);
    NSData *key = SZFriendsMentionKeyFromString(Substring(scan, keyStart, keyEnd));
    NSString *label = Substring(scan, open + 1, close);
    if (![label hasPrefix:@"@"] || !IDIsWellFormed(friendsID) || key == nil) return nil;
    NSString *written = [label substringFromIndex:1], *name = Unescaped(written);
    // Exactly the writer's escaping, so one name has one spelling and nothing hides in an unusual escape.
    if (!NameIsValid(name) || ![SZFriendsMarkdownLiteral(name) isEqualToString:written]) return nil;
    SZFriendsTextLink *link = [[SZFriendsTextLink alloc] init];
    link.range = NSMakeRange(open, keyEnd + 1 - open);
    link.shownText = [@"@" stringByAppendingString:name];
    link.name = name;
    link.friendsID = friendsID;
    link.identityKey = key;
    link.isMention = YES;
    return link;
}

// Where an inline link whose destination starts at `start` ends (just past its ")"), or NSNotFound. Angle-bracketed
// destinations end at ">", bare ones at the first unescaped ")" outside parentheses; a title is skipped up to the
// closing ")". Never past a blank line, as no renderer continues a link there.
static NSUInteger InlineLinkEnd(SZFriendsScan *scan, NSUInteger start, BOOL angled) {
    NSInteger depth = 0;
    NSUInteger limit = MIN(scan->length, start + SZFriendsLinkDestinationMax);
    BOOL inDestination = YES;
    for (NSUInteger i = start; i < limit; i++) {
        unichar c = scan->chars[i];
        if (c == '\n' && i + 1 < limit && scan->chars[i + 1] == '\n') return NSNotFound;
        if (scan->escaped[i]) continue;
        if (angled && inDestination) {
            if (c == '>') inDestination = NO;
            continue;
        }
        if (c == '(') depth++;
        else if (c == ')') {
            if (depth == 0) return i + 1;
            depth--;
        }
    }
    return NSNotFound;
}

// An autolink, <szfriends:...>, whose address starts at `at`; nil when no ">" closes it on the same line.
static SZFriendsTextLink *_Nullable Autolink(SZFriendsScan *scan, NSUInteger at) {
    if (at == 0 || !IsUnescaped(scan, at - 1, '<')) return nil;
    for (NSUInteger i = at; i < scan->length && i < at + SZFriendsLinkDestinationMax; i++) {
        unichar c = scan->chars[i];
        if (c == ' ' || c == '\n' || c == '\t' || c == '<') return nil;
        if (c == '>') {
            SZFriendsTextLink *link = [[SZFriendsTextLink alloc] init];
            link.range = NSMakeRange(at - 1, i + 2 - at);
            link.shownText = Substring(scan, at, i);
            return link;
        }
    }
    return nil;
}

// An inline link or a reference definition whose destination starts at `at`, or nil.
static SZFriendsTextLink *_Nullable DestinationLink(SZFriendsScan *scan, NSUInteger at) {
    // Back over an optional "<" and spaces (one line break at most) to "(" or, for a reference definition, ":".
    NSUInteger i = at;
    BOOL angled = NO;
    if (i > 0 && IsUnescaped(scan, i - 1, '<')) {
        angled = YES;
        i--;
    }
    NSUInteger breaks = 0;
    while (i > 0 && (scan->chars[i - 1] == ' ' || scan->chars[i - 1] == '\t' || scan->chars[i - 1] == '\n')) {
        if (scan->chars[i - 1] == '\n' && ++breaks > 1) return nil;
        i--;
    }
    if (i < 2) return nil;
    unichar marker = scan->chars[i - 1];
    NSUInteger close = i - 2;
    if (scan->escaped[i - 1] || (marker != '(' && marker != ':') || !IsUnescaped(scan, close, ']')) return nil;
    NSUInteger open = OpeningBracket(scan, close);
    if (open == NSNotFound) return nil;
    if (marker == ':') {
        // A reference definition: "[label]: szfriends:..." opening its line after at most three spaces.
        NSUInteger lineStart = open;
        while (lineStart > 0 && scan->chars[lineStart - 1] == ' ' && open - lineStart < 3) lineStart--;
        if (lineStart > 0 && scan->chars[lineStart - 1] != '\n') return nil;
        NSUInteger lineEnd = at;
        while (lineEnd < scan->length && scan->chars[lineEnd] != '\n') lineEnd++;
        SZFriendsTextLink *link = [[SZFriendsTextLink alloc] init];
        link.range = NSMakeRange(lineStart, lineEnd - lineStart);
        link.shownText = Substring(scan, lineStart, lineEnd);
        return link;
    }
    if (!angled && breaks == 0 && i == at) {
        SZFriendsTextLink *mention = StrictMention(scan, open, close, at);
        if (mention) return mention;
    }
    NSUInteger end = InlineLinkEnd(scan, at, angled);
    if (end == NSNotFound) return nil;
    SZFriendsTextLink *link = [[SZFriendsTextLink alloc] init];
    link.range = NSMakeRange(open, end - open);
    link.shownText = Unescaped(Substring(scan, open + 1, close));
    return link;
}

// A wikilink, [[szfriends:...]] or [[szfriends:...|words]], whose target starts at `at` after spaces: the host's
// engine reads them (md4c with MD_FLAG_WIKILINKS) and links the target. Nil unless "]]" closes it, with no line break
// in the target and no blank line after.
static SZFriendsTextLink *_Nullable Wikilink(SZFriendsScan *scan, NSUInteger at) {
    NSUInteger start = at;
    while (start > 0 && (scan->chars[start - 1] == ' ' || scan->chars[start - 1] == '\t')) start--;
    if (start < 2 || !IsUnescaped(scan, start - 1, '[') || !IsUnescaped(scan, start - 2, '[')) return nil;
    NSUInteger pipe = NSNotFound;
    for (NSUInteger i = at; i + 1 < scan->length && i < at + SZFriendsLinkDestinationMax; i++) {
        unichar c = scan->chars[i];
        if (c == '\n' && (pipe == NSNotFound || scan->chars[i + 1] == '\n')) return nil;
        if (scan->escaped[i]) continue;
        if (c == '|' && pipe == NSNotFound) pipe = i;
        if (c != ']' || !IsUnescaped(scan, i + 1, ']')) continue;
        SZFriendsTextLink *link = [[SZFriendsTextLink alloc] init];
        link.range = NSMakeRange(start - 2, i + 2 - (start - 2));
        link.shownText = Unescaped(pipe == NSNotFound ? Substring(scan, start, i) : Substring(scan, pipe + 1, i));
        return link;
    }
    return nil;
}

// One character, at `i`, of every HTML tag reading in `open` (the earliest start in each state), for a destination at
// `at` (NSNotFound: none yet). Read as loosely as any reader reads a tag: a tag opens at any "<" before a letter,
// even one a backslash escapes or one inside a quoted value (HTML blocks pass both through raw); a quote opens a
// value, or is part of a name as HTML5 reads <a x" href=...>; neither a blank line nor another "<" ends it (blocks of
// CommonMark types 1-5 run past blank lines); only an unquoted ">" closes it. A reading counts only once an "=" with no
// backslash before it has come before the destination, since only that gives an attribute a value: the form a refused
// tag shows as writes every "=" as "\=", so it is never found again. Readings in the same state read the rest alike,
// so the one opened farthest back stands for them all and the work stays linear. A valued reading closed after the
// destination sets `found` and `end`.
static void ReadTag(SZFriendsScan *scan, NSUInteger i, NSUInteger at, NSUInteger open[TagStates],
                    NSUInteger *found, NSUInteger *end) {
    NSUInteger next[TagStates];
    unichar c = scan->chars[i];
    BOOL before = at == NSNotFound || i < at, equals = c == '=' && before && (i == 0 || scan->chars[i - 1] != '\\');
    for (int state = 0; state < TagStates; state++) next[state] = NSNotFound;
    for (int state = 0; state < TagStates; state++) {
        NSUInteger start = open[state];
        if (start >= *found) continue; // nothing to follow, or no better than the tag already found
        int quote = state % Quotes, valued = state - quote;
        if (quote != Outside) {
            int to = valued + (c == (quote == InDouble ? '"' : '\'') ? Outside : quote);
            next[to] = MIN(next[to], start);
            continue;
        }
        if (c == '>') {
            if (!before && i > at && valued) { // closed after the destination, it is the tag holding it
                *found = start;
                *end = i + 1;
            }
            continue;
        }
        if (c == '"' || c == '\'') { // a value opens, or the quote is part of a name and the reading stays outside
            int to = valued + (c == '"' ? InDouble : InSingle);
            next[to] = MIN(next[to], start);
        }
        int stay = equals ? Quotes : valued;
        next[stay] = MIN(next[stay], start);
    }
    unichar name = i + 1 < scan->length ? scan->chars[i + 1] | 0x20 : 0;
    if (before && c == '<' && name >= 'a' && name <= 'z') next[Outside] = MIN(next[Outside], i);
    memcpy(open, next, sizeof next);
}

// An HTML tag holding the destination at `at` (<a href="szfriends:...">), which inline HTML and HTML blocks make a
// link; it shows as the text it is. The readings open a reach before `at` are those carried in `scan`, however long
// ago they opened, each followed to its ">" within a reach after `at`; one with a value still open there counts as the
// tag up to that point, its "<" and "=" losing their power as text. The tag found starts at or before the renderer's:
// showing a little more as text is harmless, where showing less would leave a link.
static SZFriendsTextLink *_Nullable HTMLTag(SZFriendsScan *scan, NSUInteger at) {
    NSUInteger open[TagStates], found = NSNotFound, end = 0, none = NSNotFound;
    NSUInteger from = at > SZFriendsLinkDestinationMax ? at - SZFriendsLinkDestinationMax : 0;
    NSUInteger limit = MIN(scan->length, at + SZFriendsLinkDestinationMax), i = from;
    for (; scan->tags.position < from; scan->tags.position++)
        ReadTag(scan, scan->tags.position, NSNotFound, scan->tags.open, &none, &end);
    memcpy(open, scan->tags.open, sizeof open);
    for (; i < limit; i++) {
        ReadTag(scan, i, at, open, &found, &end);
        NSUInteger earliest = NSNotFound;
        for (int state = 0; state < TagStates; state++) earliest = MIN(earliest, open[state]);
        if (i >= at && earliest >= found) break;
    }
    if (found == NSNotFound && i == limit && limit < scan->length) {
        for (int state = Quotes; state < TagStates; state++) found = MIN(found, open[state]);
        end = limit;
    }
    if (found == NSNotFound) return nil;
    SZFriendsTextLink *link = [[SZFriendsTextLink alloc] init];
    link.range = NSMakeRange(found, end - found);
    link.shownText = Substring(scan, found, end);
    return link;
}

// The Friends link around the "szfriends:" at `at` (any case), or nil when that text is not part of a link. An
// angle-bracketed destination is part of an inline link, so links are looked for before autolinks.
static SZFriendsTextLink *_Nullable LinkAround(SZFriendsScan *scan, NSUInteger at) {
    return DestinationLink(scan, at) ?: Autolink(scan, at) ?: Wikilink(scan, at) ?: HTMLTag(scan, at);
}

// The character a reference at `at` stands for, with its length in `used` (0: none there). Only ASCII can spell
// "szfriends:", so anything else is U+FFFD. Named: "&colon;", "&Tab;" and "&NewLine;" (the URL parser drops the
// last two), in that case and with the semicolon, as HTML reads them; no other HTML5 name gives a character of the
// scheme. A numeric one has any number of digits and ends at its semicolon or first non-digit ("szfriends&#58x").
static unichar EntityAt(const unichar *chars, NSUInteger length, NSUInteger at, NSUInteger *used) {
    static const char *const names[] = {"&colon;", "&Tab;", "&NewLine;"};
    static const unichar named[] = {':', '\t', '\n'};
    NSUInteger i = (*used = 0);
    for (size_t n = 0; n < 3; n++) {
        for (i = 0; names[n][i] && at + i < length && chars[at + i] == (unichar)names[n][i];) i++;
        if (!names[n][i]) return *used = i, named[n];
    }
    if (at + 2 >= length || chars[at + 1] != '#') return 0;
    BOOL hex = (chars[at + 2] | 0x20) == 'x';
    uint32_t value = 0, digit = 0;
    NSUInteger first = i = at + (hex ? 3 : 2);
    for (; i < length; i++) {
        unichar c = chars[i], lower = c | 0x20;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (hex && lower >= 'a' && lower <= 'f') digit = lower - 'a' + 10;
        else break;
        value = MIN(value * (hex ? 16 : 10) + digit, 0x110000u); // past Unicode stays past it
    }
    if (i == first) return 0;
    *used = i + (i < length && chars[i] == ';') - at;
    return value > 0 && value < 0x80 ? (unichar)value : 0xFFFD;
}

NSArray<SZFriendsTextLink *> *SZFriendsTextLinks(NSString *text) {
    // Every spelling holds "szfriends", a reference, or a tab or line break: without any, one search or two.
    if ([text rangeOfString:@"szfriends" options:NSCaseInsensitiveSearch].location == NSNotFound &&
        [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"&\t\n\r"]].location ==
            NSNotFound)
        return @[];
    NSUInteger length = text.length, count = 0, found = 0;
    unichar *chars = malloc(sizeof(unichar) * length), *decoded = malloc(sizeof(unichar) * length);
    BOOL *escaped = calloc(length, sizeof(BOOL));
    NSUInteger *source = malloc(sizeof(NSUInteger) * length);
    NSMutableArray<SZFriendsTextLink *> *links = [NSMutableArray array];
    if (chars && escaped && decoded && source) {
        [text getCharacters:chars range:NSMakeRange(0, length)];
        for (NSUInteger i = 1; i < length; i++) escaped[i] = chars[i - 1] == '\\' && !escaped[i - 1];
        // The text as a renderer reads the scheme in it: ASCII letters in any case; a backslash before ":", which
        // CommonMark drops; any character as a reference, which CommonMark decodes in destinations, md4c in wikilink
        // targets and HTML in attribute values; and no ASCII tab or line break, raw or as a reference, which the
        // WHATWG URL parser removes ("sz&#9;friends:"). `source` holds where each character read starts.
        for (NSUInteger i = 0, used = 0; i < length; i += MAX(used, 1)) {
            used = chars[i] == '\\' && i + 1 < length && IsASCIIPunctuation(chars[i + 1]) ? 2 : 0;
            unichar c = used ? chars[i + 1] : chars[i];
            if (!used && c == '&') c = EntityAt(chars, length, i, &used) ?: '&';
            if (c != '\t' && c != '\n' && c != '\r') source[count] = i, decoded[count++] = c;
        }
        // Where each "szfriends:" so read starts, over `source` (never ahead of the match being read).
        for (NSUInteger i = 0, matched = 0; i + 10 <= count; i++, matched = 0) {
            while (matched < 10 && (decoded[i + matched] | (matched < 9 ? 0x20 : 0)) == (unichar)"szfriends:"[matched])
                matched++;
            if (matched == 10) source[found++] = source[i];
        }
    }
    SZFriendsScan scan = {chars, escaped, length, {0, {0}}};
    for (int state = 0; state < TagStates; state++) scan.tags.open[state] = NSNotFound;
    for (NSUInteger next = 0, after = 0; next < found; next++) {
        SZFriendsTextLink *link = source[next] >= after ? LinkAround(&scan, source[next]) : nil;
        // A link whose text holds links found before it ("[[@Mei](...)](szfriends:x)") replaces them: it is one link,
        // refused whole, so none of it can turn back into a link once the inner one shows as text.
        while (link && links.count && links.lastObject.range.location >= link.range.location &&
               NSMaxRange(links.lastObject.range) <= NSMaxRange(link.range)) {
            [links removeLastObject];
        }
        // Otherwise links never overlap: one that starts inside the previous one is part of it.
        NSUInteger floor = links.count ? NSMaxRange(links.lastObject.range) : 0;
        if (link && link.range.location >= floor) {
            [links addObject:link];
            after = NSMaxRange(link.range);
        }
    }
    free(chars);
    free(escaped);
    free(decoded);
    free(source);
    return links;
}
