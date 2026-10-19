#import "SPDFMacAIChatActivity.h"
#include <algorithm>
// The send check's own generated tables (Unicode's emoji data), so the card marks exactly what it refuses.
#import "friends/SPDFMacFriendsEmojiTables.h"

NSString* const SPDFMacAIActivityIDKey = @"id";
NSString* const SPDFMacAIActivityKindKey = @"kind";
NSString* const SPDFMacAIActivityAnchorKey = @"after";
NSString* const SPDFMacAIActivityTitleKey = @"title";
NSString* const SPDFMacAIActivityDetailKey = @"detail";
NSString* const SPDFMacAIActivityDetailStyleKey = @"detailStyle";
NSString* const SPDFMacAIActivityOutputKey = @"output";
NSString* const SPDFMacAIActivityNoteKey = @"note";
NSString* const SPDFMacAIActivityBodyKey = @"body";
NSString* const SPDFMacAIActivityBodyStyleKey = @"bodyStyle";
NSString* const SPDFMacAIActivityCardKindKey = @"cardKind";
NSString* const SPDFMacAIActivityStateKey = @"state";
NSString* const SPDFMacAIActivityStatusKey = @"status";
NSString* const SPDFMacAIActivityAttachmentsKey = @"attachments";
NSString* const SPDFMacAIActivityActionsKey = @"actions";
NSString* const SPDFMacAIActivityLinksKey = @"links";
NSString* const SPDFMacAIActivityImageKey = @"image";
NSString* const SPDFMacAIActivityRequestOnlyKey = @"requestOnly";
NSString* const SPDFMacAIActivityStoredNoticeKey = @"storedNotice";
NSString* const SPDFMacAIActivityStoredTitleKey = @"storedTitle";
NSString* const SPDFMacAIActivityInterruptedStatusKey = @"interruptedStatus";
NSString* const SPDFMacAIActivityKindStep = @"step";
NSString* const SPDFMacAIActivityKindCard = @"card";
NSString* const SPDFMacAIActivityKindImage = @"image";
NSString* const SPDFMacAIActivityStateRunning = @"running";
NSString* const SPDFMacAIActivityStateDone = @"done";
NSString* const SPDFMacAIActivityStateFailed = @"failed";
NSString* const SPDFMacAIActivityStateStopped = @"stopped";
NSString* const SPDFMacAIActivityActionCancel = @"cancel";
NSString* const SPDFMacAIActivityBodyStyleLiteral = @"literal";

// Marks an entry whose request-only content was already replaced, so saving it again changes nothing.
static NSString* const kRedactedKey = @"redacted";
// Enough for a long agent run. The app's providers fill far less than every field's limit; a chat that still grew
// past the store's 8 MB would fail to save, and the request would end saying so.
static const NSUInteger kMaximumEntries = 128;
// Friends' message limit (PROTOCOL.md), so a message from AI chat and one from `/` are refused at the same length.
static const NSUInteger kLiteralBodyBytes = 32768;
// What the person reads where a request-only entry's content was: the one reason every such row gives, with a Friends
// excerpt saying what was not kept.
static NSString* const kFriendsStoredNotice =
    @"The messages it read aren’t kept after this request, because it included your Friends chats.";
static NSString* const kDefaultStoredNotice = @"Not kept after this request, because it included your Friends chats.";

static NSString* Clip(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    NSString* text = value;
    if (text.length <= maximum) return text;
    return [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maximum)]];
}

static BOOL Token(id value, NSUInteger maximum) {
    static NSCharacterSet* invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"].invertedSet;
    });
    return [value isKindOfClass:NSString.class] && [value length] && [value length] <= maximum &&
        [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSArray* Rows(id value, NSUInteger maximum, id (^row)(id item)) {
    if (![value isKindOfClass:NSArray.class]) return nil;
    NSMutableArray* rows = [NSMutableArray array];
    for (id item in value) {
        id clean = row(item);
        if (clean) [rows addObject:clean];
        if (rows.count == maximum) break;
    }
    return rows.count ? rows : nil;
}

static NSArray* Actions(id value) {
    return Rows(value, 4, ^id(NSDictionary* item) {
        NSString* title = [item isKindOfClass:NSDictionary.class] ? Clip(item[@"title"], 40) : nil;
        if (!title || !Token(item[@"id"], 32)) return nil;
        if ([item[@"primary"] isEqual:@YES]) return @{@"id" : item[@"id"], @"title" : title, @"primary" : @YES};
        return @{@"id" : item[@"id"], @"title" : title};
    });
}

NSDictionary* SPDFMacAIActivitySanitizedEntry(id entry) {
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    NSString* kind = entry[SPDFMacAIActivityKindKey];
    NSArray* kinds = @[SPDFMacAIActivityKindStep, SPDFMacAIActivityKindCard, SPDFMacAIActivityKindImage];
    if (![kinds containsObject:kind] || !Token(entry[SPDFMacAIActivityIDKey], 64)) return nil;
    NSNumber* anchor = entry[SPDFMacAIActivityAnchorKey];
    if (![anchor isKindOfClass:NSNumber.class] || anchor.doubleValue < 0 || anchor.doubleValue > 100000) return nil;
    NSMutableDictionary* clean = [@{SPDFMacAIActivityIDKey : entry[SPDFMacAIActivityIDKey],
        SPDFMacAIActivityKindKey : kind, SPDFMacAIActivityAnchorKey : @(anchor.unsignedIntegerValue)} mutableCopy];
    // A literal body is text the person approves before it is sent: cut short, the card would hide its end.
    id body = entry[SPDFMacAIActivityBodyKey];
    BOOL literal = SPDFMacAIActivityBodyIsLiteral(entry);
    if (literal && [body isKindOfClass:NSString.class] &&
        [body lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kLiteralBodyBytes) return nil;
    // A literal body within its bytes is within as many UTF-16 units, so its clip below never cuts it.
    NSDictionary* limits = @{SPDFMacAIActivityTitleKey : @200, SPDFMacAIActivityDetailKey : @4000,
        SPDFMacAIActivityOutputKey : @4000, SPDFMacAIActivityNoteKey : @400,
        SPDFMacAIActivityBodyKey : @(literal ? kLiteralBodyBytes : 8000), SPDFMacAIActivityStatusKey : @200,
        SPDFMacAIActivityStoredNoticeKey : @200, SPDFMacAIActivityStoredTitleKey : @200,
        SPDFMacAIActivityInterruptedStatusKey : @200};
    for (NSString* key in limits) {
        NSString* text = Clip(entry[key], [limits[key] unsignedIntegerValue]);
        if (text) clean[key] = text;
    }
    for (NSString* key in @[SPDFMacAIActivityCardKindKey, SPDFMacAIActivityDetailStyleKey,
                            SPDFMacAIActivityBodyStyleKey])
        if (Token(entry[key], 64)) clean[key] = entry[key];
    NSArray* states = @[SPDFMacAIActivityStateRunning, SPDFMacAIActivityStateDone, SPDFMacAIActivityStateFailed,
                        SPDFMacAIActivityStateStopped];
    clean[SPDFMacAIActivityStateKey] = [states containsObject:entry[SPDFMacAIActivityStateKey]] ?
        entry[SPDFMacAIActivityStateKey] : SPDFMacAIActivityStateDone;
    NSArray* attachments = Rows(entry[SPDFMacAIActivityAttachmentsKey], 16, ^id(NSDictionary* item) {
        NSString* name = [item isKindOfClass:NSDictionary.class] ? Clip(item[@"name"], 200) : nil;
        if (!name) return nil;
        NSString* detail = Clip(item[@"detail"], 200);
        return detail ? @{@"name" : name, @"detail" : detail} : @{@"name" : name};
    });
    if (attachments) clean[SPDFMacAIActivityAttachmentsKey] = attachments;
    NSArray* actions = Actions(entry[SPDFMacAIActivityActionsKey]);
    if (actions) clean[SPDFMacAIActivityActionsKey] = actions;
    NSArray* links = Rows(entry[SPDFMacAIActivityLinksKey], 16, ^id(id item) {
        id address = [item isKindOfClass:NSDictionary.class] ? item[@"url"] : item;
        NSString* link = Clip(address, 2048);
        if (link.length != [address length] || ![NSURL URLWithString:link].scheme.length) return nil;
        if (![item isKindOfClass:NSDictionary.class]) return link;
        NSMutableDictionary* row = [@{@"url" : link} mutableCopy];
        for (NSString* key in @[@"title", @"host"]) if (Clip(item[key], 200)) row[key] = Clip(item[key], 200);
        return row.count > 1 ? [row copy] : link;
    });
    if (links) clean[SPDFMacAIActivityLinksKey] = links;
    NSDictionary* image = entry[SPDFMacAIActivityImageKey];
    if ([kind isEqual:SPDFMacAIActivityKindImage]) {
        NSString* path = [image isKindOfClass:NSDictionary.class] ? Clip(image[@"path"], 1024) : nil;
        if (!path || path.length != [image[@"path"] length]) return nil;
        clean[SPDFMacAIActivityImageKey] = @{@"path" : path, @"caption" : Clip(image[@"caption"], 200) ?: @"Image"};
    }
    if ([entry[SPDFMacAIActivityRequestOnlyKey] isEqual:@YES]) clean[SPDFMacAIActivityRequestOnlyKey] = @YES;
    if ([entry[kRedactedKey] isEqual:@YES]) clean[kRedactedKey] = @YES;
    return clean;
}

NSArray<NSDictionary*>* SPDFMacAIActivityEntriesForStorage(NSArray<NSDictionary*>* entries) {
    NSMutableArray* stored = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary* entry in entries) {
        if (![entry[SPDFMacAIActivityRequestOnlyKey] isEqual:@YES] || [entry[kRedactedKey] isEqual:@YES]) {
            [stored addObject:entry];
            continue;
        }
        // Like a Friends excerpt's stub: what it was and where it links, never what it said.
        if ([entry[SPDFMacAIActivityKindKey] isEqual:SPDFMacAIActivityKindImage]) continue;
        NSMutableDictionary* stub = [entry mutableCopy];
        NSMutableArray* addresses = [NSMutableArray array];
        BOOL friends = NO;
        for (id link in entry[SPDFMacAIActivityLinksKey]) {
            NSString* address = [link isKindOfClass:NSDictionary.class] ? link[@"url"] : link;
            friends |= [[NSURL URLWithString:address].scheme.lowercaseString isEqual:@"shenzhenpdf-friends"];
            [addresses addObject:address];  // a link's title can quote what it links to
        }
        if (addresses.count) stub[SPDFMacAIActivityLinksKey] = addresses;
        NSString* notice = entry[SPDFMacAIActivityStoredNoticeKey] ?:
            (friends ? kFriendsStoredNotice : kDefaultStoredNotice);
        // A title the model wrote (a helper's task) can quote a friend as well as a body can.
        NSString* storedTitle = entry[SPDFMacAIActivityStoredTitleKey];
        if (storedTitle) stub[SPDFMacAIActivityTitleKey] = storedTitle;
        // What a run printed can quote a friend as well as its code can.
        [stub removeObjectsForKeys:@[SPDFMacAIActivityDetailKey, SPDFMacAIActivityBodyKey,
                                     SPDFMacAIActivityStoredTitleKey, SPDFMacAIActivityAttachmentsKey,
                                     SPDFMacAIActivityDetailStyleKey, SPDFMacAIActivityOutputKey,
                                     SPDFMacAIActivityNoteKey]];
        stub[[entry[SPDFMacAIActivityKindKey] isEqual:SPDFMacAIActivityKindCard] ? SPDFMacAIActivityBodyKey :
             SPDFMacAIActivityDetailKey] = notice;
        stub[kRedactedKey] = @YES;
        [stored addObject:[stub copy]];
    }
    return stored;
}

NSString* SPDFMacAIActivityStatusText(NSDictionary* entry) {
    NSString* status = entry[SPDFMacAIActivityStatusKey];
    if (status.length) return status;
    NSString* state = entry[SPDFMacAIActivityStateKey];
    if ([state isEqual:SPDFMacAIActivityStateRunning]) return @"Working…";
    if ([state isEqual:SPDFMacAIActivityStateFailed]) return @"Didn’t finish";
    if ([state isEqual:SPDFMacAIActivityStateStopped]) return @"Stopped";
    return @"Done";
}

BOOL SPDFMacAIActivityBodyIsLiteral(NSDictionary* entry) {
    // The send card's text leaves the Mac when the person presses Send: even if its provider left the style out,
    // they never approve Markdown that hides part of what goes.
    return [entry[SPDFMacAIActivityBodyStyleKey] isEqual:SPDFMacAIActivityBodyStyleLiteral] ||
        [entry[SPDFMacAIActivityCardKindKey] isEqual:@"friends.send"];
}

// What a font draws as nothing: Unicode's Default_Ignorable_Code_Point set (DerivedCoreProperties.txt), controls
// other than tab and line breaks, the interlinear and object replacement characters, Egyptian hieroglyph format
// controls and the braille blank, which reads as a space. Private-use characters too: what they draw depends on the
// font, many draw nothing, and the send check refuses them all, so one on a card is shown by its code point.
static BOOL DrawsNothing(UTF32Char c) {
    if (c < 0x20) return c != '\t' && c != '\n' && c != '\r';
    static const UTF32Char ranges[][2] = {{0x7F, 0x9F}, {0xAD, 0xAD}, {0x34F, 0x34F}, {0x61C, 0x61C},
        {0x115F, 0x1160}, {0x17B4, 0x17B5}, {0x180B, 0x180F}, {0x200B, 0x200F}, {0x202A, 0x202E}, {0x2060, 0x206F},
        {0x2800, 0x2800}, {0x3164, 0x3164}, {0xE000, 0xF8FF}, {0xFE00, 0xFE0F}, {0xFEFF, 0xFEFF}, {0xFFA0, 0xFFA0},
        {0xFFF0, 0xFFFC}, {0x13430, 0x1343F}, {0x1BCA0, 0x1BCA3}, {0x1D173, 0x1D17A}, {0xE0000, 0xE0FFF},
        {0xF0000, 0xFFFFD}, {0x100000, 0x10FFFD}};
    for (const auto& range : ranges) if (c >= range[0] && c <= range[1]) return YES;
    return NO;
}

template <size_t count>
static BOOL InTable(UTF32Char c, const SPDFMacFriendsCodePointRange (&table)[count]) {
    auto range = std::partition_point(table, table + count, [c](const auto& entry) { return entry.high < c; });
    return range != table + count && range->low <= c;
}

// Where a non-joiner or joiner shapes an Indic conjunct, so a reader sees it: right after a script's virama before a
// consonant of its block, or, a joiner only, after such a consonant before the virama and a consonant (র‍্য, not क‍्).
static BOOL BesideVirama(UTF32Char before, UTF32Char after, BOOL joiner, UTF32Char afterNext = 0) {
    for (const SPDFMacFriendsViramaBlock& virama : kSPDFMacFriendsViramas)
        if (UTF32Char consonant = virama.virama == before ? after : joiner && virama.virama == after ? before : 0)
            return consonant >= virama.blockLow && consonant <= virama.blockHigh &&
                InTable(consonant, kSPDFMacFriendsIndicConsonants) &&
                (virama.virama == before || BesideVirama(after, afterNext, NO));
    return NO;
}

// Where a non-joiner changes what is drawn: between a dual-joining letter and a dual- or right-joining one (Arabic
// script), or beside a virama as above. Anywhere else it draws nothing; the send check refuses it there
// (SPDFMacFriendsSendText.mm, same tables).
static BOOL NonJoinerSeen(UTF32Char before, UTF32Char after) {
    return (InTable(before, kSPDFMacFriendsDualJoining) &&
            (InTable(after, kSPDFMacFriendsDualJoining) || InTable(after, kSPDFMacFriendsRightJoining))) ||
        BesideVirama(before, after, NO);
}

// A character that draws nothing yet changes what its neighbours draw, so a person sees its effect: the rule the send
// check applies before the card (ai-agent-capabilities.md § 1). `shown` holds the characters shown as themselves
// before it, newest first. Anything looser lets text ride along unseen: a variation selector after kana, CJK
// punctuation or an arrow draws exactly the text without it, and one of 256 after every letter is a byte per letter.
static BOOL ChangesDrawing(UTF32Char c, const UTF32Char shown[3], UTF32Char next, UTF32Char afterNext) {
    if (c == 0x200C) return NonJoinerSeen(shown[0], next);
    if (c == 0x200D) {
        if (BesideVirama(shown[0], next, YES, afterNext)) return YES;
        // 👩🏽‍💻: one emoji from two, its presentation selector or skin tone between the first and the joiner. A
        // selector marked as stray is not shown, so the joiner after it (👩‹U+FE0F›‹U+200D›💻) is marked too.
        int base = shown[0] == 0xFE0F ? 1 : 0;
        if (shown[base] >= 0x1F3FB && shown[base] <= 0x1F3FF) base++;
        return InTable(shown[base], kSPDFMacFriendsExtendedPictographic) &&
            InTable(next, kSPDFMacFriendsExtendedPictographic);
    }
    if (c != 0xFE0E && c != 0xFE0F) return NO;
    // Text or emoji presentation of a base Unicode lists for it. The keycap bases (# * 0-9, the only ASCII ones)
    // count only in a keycap (1️⃣): "1" and "1" with U+FE0E draw the same, which would hide a bit in every digit.
    if (!InTable(shown[0], kSPDFMacFriendsEmojiVariationBases)) return NO;
    return shown[0] >= 0x80 || next == 0x20E3;
}

static UTF32Char CodePointAt(NSString* text, NSUInteger index, NSUInteger* width) {
    unichar unit = [text characterAtIndex:index], low = index + 1 < text.length ? [text characterAtIndex:index + 1] : 0;
    *width = CFStringIsSurrogateHighCharacter(unit) && CFStringIsSurrogateLowCharacter(low) ? 2 : 1;
    return *width == 2 ? CFStringGetLongCharacterForSurrogatePair(unit, low) : unit;
}

// A combining mark (Mn, Mc, Me) shown only on a letter of its own script, once, and at most four to a letter: a mark of
// another script can draw nothing (U+3099 on Hangul), and some draw the same once or many times (U+065E after an
// Arabic letter). A Quranic pause or annotation mark may also stand on a space, as Quran text writes them ("رَيْبَ ۛ
// فِيهِ"), where they draw. The send check refuses the rest (SPDFMacFriendsSendText.mm). `letter` is the last letter
// (U+0000 before the first), `onBase` its marks from its own NFD on (U+1EC7 carries U+0323 and U+0302); a mark counts
// as NFC writes it, and a marked character or a joiner between a letter and its marks leaves them on that letter.
static BOOL MarkStacks(UTF32Char c, NSString* character, UTF32Char onBase[4], NSUInteger* count, UTF32Char* letter) {
    static NSCharacterSet* marks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ marks = NSCharacterSet.nonBaseCharacterSet; });
    if (c == 0x200D) return NO;
    if (![marks longCharacterIsMember:c]) {
        *count = 0, *letter = c;
        NSString* parts = c < 0xC0 ? nil : character.decomposedStringWithCanonicalMapping; // none decomposes below
        for (NSUInteger index = 0, width = 1; index < parts.length; index += width)
            if (UTF32Char part = CodePointAt(parts, index, &width); index && [marks longCharacterIsMember:part])
                MarkStacks(part, nil, onBase, count, nullptr); // its own marks count whatever their script
        return NO;
    }
    BOOL quranic = (c >= 0x06D6 && c <= 0x06DC) || (c >= 0x06DF && c <= 0x06E4) || c == 0x06E7 || c == 0x06E8 ||
        (c >= 0x06EA && c <= 0x06ED), space = letter && (*letter == ' ' || *letter == 0xA0 || *letter == 0x1680 ||
        (*letter >= 0x2000 && *letter <= 0x200A) || *letter == 0x202F || *letter == 0x205F);
    if (*count == 4 || (letter && !(quranic && space) && !SPDFMacFriendsMarkFitsLetter(c, *letter))) return YES;
    for (NSUInteger index = 0; index < *count; index++)
        if (onBase[index] == c) return YES;
    onBase[(*count)++] = c;
    return NO;
}

NSString* SPDFMacAIActivityVisibleText(NSString* text, NSArray<NSValue*>** markers) {
    // What Friends delivers: the send side composes the text (NFC), so e and U+0301 go, and show here, as "é".
    text = text.precomposedStringWithCanonicalMapping;
    NSMutableString* shown = [NSMutableString stringWithCapacity:text.length];
    NSMutableArray<NSValue*>* marked = [NSMutableArray array];
    // The last characters shown as themselves, newest first: a marked one is nothing to join or vary.
    UTF32Char drawn[3] = {0, 0, 0}, onBase[4] = {0, 0, 0, 0}, letter = 0;
    NSUInteger marksOnBase = 0;
    for (NSUInteger index = 0, width = 1; index < text.length; index += width) {
        UTF32Char c = CodePointAt(text, index, &width), next = 0, afterNext = 0;
        NSUInteger nextWidth = 1, later = 1;
        if (index + width < text.length) next = CodePointAt(text, index + width, &nextWidth);
        if (index + width + nextWidth < text.length) afterNext = CodePointAt(text, index + width + nextWidth, &later);
        // A lone surrogate is no character at all, and fonts draw it as nothing.
        BOOL lone = width == 1 && (CFStringIsSurrogateHighCharacter((unichar)c) ||
                                   CFStringIsSurrogateLowCharacter((unichar)c));
        BOOL hidden = lone || (DrawsNothing(c) && !ChangesDrawing(c, drawn, next, afterNext));
        NSString* character = [text substringWithRange:NSMakeRange(index, width)];
        if (hidden || MarkStacks(c, character, onBase, &marksOnBase, &letter)) {
            NSString* marker = [NSString stringWithFormat:@"‹U+%04X›", (unsigned)c];
            [marked addObject:[NSValue valueWithRange:NSMakeRange(shown.length, marker.length)]];
            [shown appendString:marker];
            drawn[0] = drawn[1] = drawn[2] = 0;
        } else {
            [shown appendString:character];
            drawn[2] = drawn[1];
            drawn[1] = drawn[0];
            drawn[0] = c;
        }
    }
    if (markers) *markers = marked;
    return shown;
}

@implementation SPDFMacAIChatActivity {
    NSMutableArray<NSDictionary*>* _entries;
    NSMutableDictionary<NSString*, SPDFMacAIActivityHandler>* _handlers;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _entries = [NSMutableArray array];
    _handlers = [NSMutableDictionary dictionary];
    return self;
}
- (NSArray<NSDictionary*>*)entries { return [_entries copy]; }
- (void)notify { if (self.changed) self.changed(); }
- (NSUInteger)indexOfEntry:(NSString*)identifier {
    return [_entries indexOfObjectPassingTest:^BOOL(NSDictionary* entry, NSUInteger index, BOOL* stop) {
        (void)index; (void)stop; return [entry[SPDFMacAIActivityIDKey] isEqual:identifier];
    }];
}

// Providers report from completion handlers; a call from a worker thread is moved to the main thread rather than
// racing the view.
static id OnMain(id (^block)(void)) {
    if (NSThread.isMainThread) return block();
    __block id result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = block(); });
    return result;
}

- (NSString*)addEntry:(NSDictionary*)fields options:(SPDFMacAIActivityOptions)options
              handler:(SPDFMacAIActivityHandler)handler {
    if (_entries.count >= kMaximumEntries) return nil;
    NSMutableDictionary* entry = [fields mutableCopy];
    entry[SPDFMacAIActivityIDKey] = NSUUID.UUID.UUIDString;
    entry[SPDFMacAIActivityAnchorKey] = @(self.anchor ? self.anchor() : 0);
    if (options & SPDFMacAIActivityRequestOnly) entry[SPDFMacAIActivityRequestOnlyKey] = @YES;
    else [entry removeObjectForKey:SPDFMacAIActivityRequestOnlyKey];
    [entry removeObjectForKey:kRedactedKey];
    NSDictionary* clean = SPDFMacAIActivitySanitizedEntry(entry);
    if (!clean) return nil;
    [_entries addObject:clean];
    if (handler) _handlers[clean[SPDFMacAIActivityIDKey]] = [handler copy];
    [self notify];
    return clean[SPDFMacAIActivityIDKey];
}

- (NSString*)beginStepWithTitle:(NSString*)title detail:(NSString*)detail options:(SPDFMacAIActivityOptions)options
                         cancel:(dispatch_block_t)cancel {
    return OnMain(^id {
        NSMutableDictionary* step = [@{SPDFMacAIActivityKindKey : SPDFMacAIActivityKindStep,
            SPDFMacAIActivityTitleKey : title ?: @"", SPDFMacAIActivityStateKey : SPDFMacAIActivityStateRunning}
            mutableCopy];
        if (detail) step[SPDFMacAIActivityDetailKey] = detail;
        if (cancel)
            step[SPDFMacAIActivityActionsKey] = @[@{@"id" : SPDFMacAIActivityActionCancel, @"title" : @"Cancel"}];
        dispatch_block_t stop = [cancel copy];
        SPDFMacAIActivityHandler handler = nil;
        if (stop) handler = ^(NSString* action) { (void)action; stop(); };
        return [self addEntry:step options:options handler:handler];
    });
}

- (NSString*)addCard:(NSDictionary*)card options:(SPDFMacAIActivityOptions)options
             handler:(SPDFMacAIActivityHandler)handler {
    return OnMain(^id {
        if (![card isKindOfClass:NSDictionary.class]) return nil;
        NSMutableDictionary* fields = [card mutableCopy];
        fields[SPDFMacAIActivityKindKey] = SPDFMacAIActivityKindCard;
        [fields removeObjectForKey:SPDFMacAIActivityImageKey];
        return [self addEntry:fields options:options handler:handler];
    });
}

- (NSString*)addImageAtPath:(NSString*)path caption:(NSString*)caption options:(SPDFMacAIActivityOptions)options {
    return OnMain(^id {
        // A saved image is a file in the chat's folder, which the file's own stub could not take back: request-only
        // content never becomes one.
        if ((options & SPDFMacAIActivityRequestOnly) || !path.length || !self.saveImage) return nil;
        NSDictionary* saved = self.saveImage(@{@"path" : path, @"caption" : caption ?: @"Image"});
        if (![saved[@"path"] isKindOfClass:NSString.class]) return nil;
        return [self addEntry:@{SPDFMacAIActivityKindKey : SPDFMacAIActivityKindImage,
            SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone, SPDFMacAIActivityImageKey :
            @{@"path" : saved[@"path"], @"caption" : caption ?: @"Image"}} options:options handler:nil];
    });
}

- (void)updateEntry:(NSString*)identifier changes:(NSDictionary*)changes {
    OnMain(^id {
        NSUInteger index = [self indexOfEntry:identifier];
        if (index == NSNotFound || ![changes isKindOfClass:NSDictionary.class]) return nil;
        NSMutableDictionary* entry = [self->_entries[index] mutableCopy];
        NSMutableDictionary* allowed = [changes mutableCopy];
        [allowed removeObjectsForKeys:@[SPDFMacAIActivityIDKey, SPDFMacAIActivityKindKey, SPDFMacAIActivityAnchorKey,
            SPDFMacAIActivityImageKey, SPDFMacAIActivityRequestOnlyKey, kRedactedKey]];
        [entry addEntriesFromDictionary:allowed];
        BOOL ended = allowed[SPDFMacAIActivityStateKey] &&
            ![allowed[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateRunning];
        if (ended && !allowed[SPDFMacAIActivityActionsKey]) {
            [entry removeObjectForKey:SPDFMacAIActivityActionsKey];
            [self->_handlers removeObjectForKey:identifier];
        }
        NSDictionary* clean = SPDFMacAIActivitySanitizedEntry(entry);
        if (!clean || [clean isEqual:self->_entries[index]]) return nil;
        self->_entries[index] = clean;
        [self notify];
        return nil;
    });
}

- (void)setHandler:(SPDFMacAIActivityHandler)handler forEntry:(NSString*)identifier {
    OnMain(^id {
        if ([self indexOfEntry:identifier] == NSNotFound) return nil;
        if (handler) self->_handlers[identifier] = [handler copy];
        else [self->_handlers removeObjectForKey:identifier];
        [self notify];
        return nil;
    });
}

- (void)loadEntries:(id)entries {
    [_entries removeAllObjects];
    [_handlers removeAllObjects];
    for (id item in [entries isKindOfClass:NSArray.class] ? entries : @[]) {
        NSMutableDictionary* entry = [SPDFMacAIActivitySanitizedEntry(item) mutableCopy];
        if (!entry || _entries.count >= kMaximumEntries) continue;
        if ([entry[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateRunning]) {
            entry[SPDFMacAIActivityStateKey] = SPDFMacAIActivityStateStopped;
            entry[SPDFMacAIActivityStatusKey] = entry[SPDFMacAIActivityInterruptedStatusKey] ?: @"Stopped";
        }
        [_entries addObject:[entry copy]];
    }
}

- (void)adoptStoredEntries:(NSArray<NSDictionary*>*)entries {
    if ([entries isEqual:_entries]) return;
    [_entries setArray:entries];
}

- (void)endRunningSteps {
    BOOL changed = NO;
    for (NSUInteger index = 0; index < _entries.count; index++) {
        NSDictionary* entry = _entries[index];
        if (![entry[SPDFMacAIActivityKindKey] isEqual:SPDFMacAIActivityKindStep] ||
            ![entry[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateRunning]) continue;
        NSMutableDictionary* stopped = [entry mutableCopy];
        stopped[SPDFMacAIActivityStateKey] = SPDFMacAIActivityStateStopped;
        // Its progress ("Reading page 4…") is no longer true; shown whole under the title, it would say it still is.
        stopped[SPDFMacAIActivityStatusKey] = entry[SPDFMacAIActivityInterruptedStatusKey] ?: @"Stopped";
        [stopped removeObjectForKey:SPDFMacAIActivityActionsKey];
        [_handlers removeObjectForKey:entry[SPDFMacAIActivityIDKey]];
        _entries[index] = [stopped copy];
        changed = YES;
    }
    if (changed) [self notify];
}

- (NSArray<NSDictionary*>*)liveActionsForEntry:(NSString*)identifier {
    NSUInteger index = [self indexOfEntry:identifier];
    if (index == NSNotFound || !_handlers[identifier]) return @[];
    return _entries[index][SPDFMacAIActivityActionsKey] ?: @[];
}

- (BOOL)performAction:(NSString*)actionID forEntry:(NSString*)identifier {
    SPDFMacAIActivityHandler handler = _handlers[identifier];
    if (!handler || ![[[self liveActionsForEntry:identifier] valueForKey:@"id"] containsObject:actionID]) return NO;
    handler(actionID);
    return YES;
}
@end
