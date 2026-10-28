#import "SPDFMacFriendsComposerText.h"
#import "../SPDFMacCollectionStyle.h"

NSString* const SPDFMacFriendsAllChatsChoiceID = @"all";

// One attachment character drawn as a chip reading `text`, sized to sit on `font`'s baseline.
static NSAttributedString* Chip(NSTextAttachment* token, NSString* text, NSFont* font) {
    NSFont* chipFont = [NSFont systemFontOfSize:MAX(10.0, font.pointSize - 1.0) weight:NSFontWeightMedium];
    NSDictionary* attributes = @{NSFontAttributeName : chipFont};
    NSSize textSize = [text sizeWithAttributes:attributes];
    NSSize size = NSMakeSize(ceil(textSize.width) + 12.0, ceil(font.ascender - font.descender) + 2.0);
    // Drawn on demand, so the chip follows the composer's light or dark appearance like the text around it.
    token.image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5) xRadius:5 yRadius:5];
        [[SPDFCollectionColor(@"focus") colorWithAlphaComponent:0.16] setFill];
        [shape fill];
        NSDictionary* drawn = @{NSFontAttributeName : chipFont, NSForegroundColorAttributeName : SPDFCollectionColor(@"text")};
        [text drawAtPoint:NSMakePoint(6.0, floor((NSHeight(rect) - textSize.height) / 2.0)) withAttributes:drawn];
        return YES;
    }];
    token.bounds = NSMakeRect(0, floor(font.descender) - 1.0, size.width, size.height);
    NSMutableAttributedString* chip = [[NSAttributedString attributedStringWithAttachment:token] mutableCopy];
    [chip addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, chip.length)];
    return chip;
}

@implementation SPDFMacFriendsScopeToken
+ (NSAttributedString*)chipWithScope:(SPDFMacFriendsScopeRequest*)scope font:(NSFont*)font {
    SPDFMacFriendsScopeToken* token = [SPDFMacFriendsScopeToken new];
    token->_scope = scope;
    token->_label = [scope.labels componentsJoinedByString:@", "] ?: @"";
    return Chip(token, [@"@" stringByAppendingString:token->_label], font);
}
@end

@implementation SPDFMacFriendsFileToken
+ (NSAttributedString*)chipWithFile:(SPDFMacAIRequestChip*)file font:(NSFont*)font {
    SPDFMacFriendsFileToken* token = [SPDFMacFriendsFileToken new];
    token->_file = file;
    return Chip(token, [@"#" stringByAppendingString:file.displayName], font);
}
@end

SPDFMacAIRequestChip* SPDFMacFriendsFileChip(NSURL* fileURL, NSString* title, NSDictionary<NSString*, id>* revision) {
    if (!fileURL.isFileURL) return nil;
    NSString* name = title.length ? title : fileURL.lastPathComponent;
    return revision ? [SPDFMacAIRequestChip documentChipWithFileURL:fileURL identifier:nil revision:revision
                                                        displayName:name]
                    : [SPDFMacAIRequestChip attachmentChipWithFileURL:fileURL displayName:name];
}

NSArray<NSDictionary<NSString*, NSString*>*>* SPDFMacFriendsScopeChoices(NSArray<NSDictionary*>* rows) {
    NSMutableArray* choices = [NSMutableArray arrayWithObject:@{@"id" : SPDFMacFriendsAllChatsChoiceID,
                                                                @"name" : @"All Friends chats"}];
    for (NSDictionary* row in [rows isKindOfClass:NSArray.class] ? rows : @[]) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString* conversationID = row[@"conversation_id"], *title = row[@"title"];
        if (![conversationID isKindOfClass:NSString.class] || !conversationID.length ||
            ![title isKindOfClass:NSString.class] || !title.length)
            continue;
        id waiting = row[@"waiting"];
        if ([waiting isKindOfClass:NSDictionary.class] && [waiting[@"kind"] isEqual:@"request"]) continue;
        [choices addObject:@{@"id" : conversationID, @"name" : title}];
    }
    return choices;
}

SPDFMacFriendsScopeRequest* SPDFMacFriendsScopeForChoice(NSDictionary<NSString*, NSString*>* choice) {
    NSString* identifier = choice[@"id"], *name = choice[@"name"];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;
    if ([identifier isEqual:SPDFMacFriendsAllChatsChoiceID]) return SPDFMacFriendsScopeRequest.allChats;
    return [SPDFMacFriendsScopeRequest conversationIDs:@[identifier] labels:@[name.length ? name : identifier]];
}

BOOL SPDFMacFriendsCaretFollowsMentionTrigger(NSString* text, NSUInteger caret) {
    return SPDFMacFriendsCaretFollowsTrigger(text, caret, '@');
}

BOOL SPDFMacFriendsCaretFollowsTrigger(NSString* text, NSUInteger caret, unichar trigger) {
    if (caret == 0 || caret > text.length || [text characterAtIndex:caret - 1] != trigger) return NO;
    if (caret == 1) return YES;
    unichar before = [text characterAtIndex:caret - 2];
    // After a space, a line break, an opening bracket or a chip: the start of a word. After a letter or digit it is
    // part of something else ("mei@example.com").
    return [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:before] || before == '(' ||
        before == '[' || before == '"' || before == NSAttachmentCharacter;
}

static void EnumerateChips(NSAttributedString* text, void (^body)(SPDFMacFriendsScopeToken* token, NSRange range)) {
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
        (void)stop;
        if ([value isKindOfClass:SPDFMacFriendsScopeToken.class]) body(value, range);
    }];
}

SPDFMacFriendsScopeRequest* SPDFMacFriendsScopeInText(NSAttributedString* text) {
    NSMutableArray* scopes = [NSMutableArray array];
    EnumerateChips(text, ^(SPDFMacFriendsScopeToken* token, NSRange range) {
        (void)range;
        if (token.scope) [scopes addObject:token.scope];
    });
    return [SPDFMacFriendsScopeRequest union:scopes];
}

NSArray<NSDictionary<NSString*, id>*>* SPDFMacFriendsFileChoices(NSArray<SZFriendsAttachableItem*>* items) {
    NSMutableArray* choices = [NSMutableArray array];
    for (SZFriendsAttachableItem* item in items) {
        SPDFMacAIRequestChip* file = SPDFMacFriendsFileChip(item.fileURL, item.title, item.revision);
        if (file) [choices addObject:@{@"id" : [NSString stringWithFormat:@"file:%lu", (unsigned long)choices.count],
                                       @"name" : file.displayName, @"file" : file}];
    }
    return choices;
}

NSArray<SPDFMacAIRequestChip*>* SPDFMacFriendsFileChipsInText(NSAttributedString* text) {
    NSMutableArray* files = [NSMutableArray array];
    if (!text.length) return files;
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
        (void)range; (void)stop;
        if ([value isKindOfClass:SPDFMacFriendsFileToken.class] && [value file]) [files addObject:[value file]];
    }];
    return files;
}

BOOL SPDFMacFriendsTextHasChips(NSAttributedString* text) {
    __block BOOL found = NO;
    if (!text.length) return NO;
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
        (void)range;
        if ([value isKindOfClass:SPDFMacFriendsScopeToken.class] || [value isKindOfClass:SPDFMacFriendsFileToken.class])
            *stop = found = YES;
    }];
    return found;
}

NSString* SPDFMacFriendsPlainTextReplacingChips(NSAttributedString* text) {
    NSMutableString* plain = [text.string mutableCopy];
    __block NSInteger shift = 0;
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL* stop) {
        (void)stop;
        NSString* written = nil;
        if ([value isKindOfClass:SPDFMacFriendsScopeToken.class])
            written = [@"@" stringByAppendingString:[value label]];
        else if ([value isKindOfClass:SPDFMacFriendsFileToken.class])
            written = [@"#" stringByAppendingString:[value file].displayName];
        if (!written) return;
        [plain replaceCharactersInRange:NSMakeRange((NSUInteger)((NSInteger)range.location + shift), range.length)
                             withString:written];
        shift += (NSInteger)written.length - (NSInteger)range.length;
    }];
    // Any other attachment character (a pasted image cannot reach this plain-text composer, but be safe) is dropped.
    [plain replaceOccurrencesOfString:[NSString stringWithFormat:@"%C", (unichar)NSAttachmentCharacter] withString:@""
                              options:0 range:NSMakeRange(0, plain.length)];
    return [plain stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString* JoinNames(NSArray<NSString*>* names) {
    if (names.count <= 1) return names.firstObject ?: @"";
    NSArray* head = [names subarrayWithRange:NSMakeRange(0, names.count - 1)];
    return [NSString stringWithFormat:@"%@ and %@", [head componentsJoinedByString:@", "], names.lastObject];
}

// `named`: the friends chips name one by one, for whom the assistant may also write messages in this request
// (SPDFMacFriendsSendRules.h); All Friends chats writes to no one. The assistant only writes them: each waits on a
// card for the person's Send, so the note never says it sends.
static NSString* Note(SPDFMacFriendsScopeRequest* scope, NSArray<NSString*>* named) {
    if (!scope) return nil;
    NSString* chats = !scope.conversationIDs ? @"all your Friends chats"
        : [NSString stringWithFormat:@"your %@ with %@", scope.labels.count > 1 ? @"chats" : @"chat",
                                     JoinNames(scope.labels)];
    NSString* send = @"";
    if (named.count)
        send = scope.conversationIDs && named.count > 1 ? @" and write messages to them for you to send"
            : [NSString stringWithFormat:@" and write messages to %@ for you to send", JoinNames(named)];
    return [NSString stringWithFormat:@"With this message, the assistant may read %@%@. What it reads goes to "
                                      @"OpenRouter, with no training and nothing kept.", chats, send];
}

NSString* SPDFMacFriendsScopeNote(SPDFMacFriendsScopeRequest* scope) {
    return Note(scope, scope.conversationIDs ? scope.labels : @[]);
}

NSString* SPDFMacFriendsComposerNote(NSAttributedString* text) {
    NSMutableArray* named = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    EnumerateChips(text, ^(SPDFMacFriendsScopeToken* token, NSRange range) {
        (void)range;
        NSString* conversation = token.scope.conversationIDs.count == 1 ? token.scope.conversationIDs[0] : nil;
        if (!conversation || [seen containsObject:conversation]) return;
        [seen addObject:conversation];
        [named addObject:token.label];
    });
    return Note(SPDFMacFriendsScopeInText(text), named);
}

@implementation SPDFMacFriendsChatRequestScoper {
    SPDFMacFriendsChatScopeGate* _gate;
    BOOL (^_running)(void);
    NSAttributedString* (^_composerText)(void);
    BOOL _sending;
}

- (instancetype)initWithGate:(SPDFMacFriendsChatScopeGate*)gate running:(BOOL (^)(void))running
                composerText:(NSAttributedString* (^)(void))composerText {
    if (!(self = [super init])) return nil;
    _gate = gate;
    _running = [running copy];
    _composerText = [composerText copy];
    return self;
}

- (SPDFMacFriendsSendText)sendTextWrapping:(SPDFMacFriendsSendText)original {
    __weak SPDFMacFriendsChatRequestScoper* weakSelf = self;
    return ^BOOL(NSString* text) {
        SPDFMacFriendsChatRequestScoper* scoper = weakSelf;
        // A send while a request runs is refused by the session; it must not replace that request's scope.
        if (!scoper || scoper->_running()) return original(text);
        NSAttributedString* composed = scoper->_composerText ? scoper->_composerText() : nil;
        SPDFMacFriendsScopeRequest* scope = composed ? SPDFMacFriendsScopeInText(composed) : nil;
        BOOL chips = composed && SPDFMacFriendsTextHasChips(composed);
        NSString* plain = chips ? SPDFMacFriendsPlainTextReplacingChips(composed) : text;
        // A message sent while the AI chat's time grant runs reads under it (SPDFMacFriendsChatGrant.h).
        [scoper->_gate beginRequestWithScope:scope grantToken:scoper->_gate.grant.activeToken];
        scoper->_sending = YES;
        BOOL sent = original(plain);
        scoper->_sending = NO;
        if (!sent || !scoper->_running()) [scoper->_gate endRequest];
        return sent;
    };
}

- (void)sessionDidChange {
    if (!_sending && !_running()) [_gate endRequest];
}

@end
