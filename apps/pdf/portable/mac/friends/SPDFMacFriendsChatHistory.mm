#import "SPDFMacFriendsChatHistory.h"
#import "SPDFMacFriendsChatScope.h"

// Each is read by the model, which passes the gist on to the person, so each says what to do next in their terms.
NSString* const SPDFMacFriendsRedactedResultNotice = @"Friends messages read for an earlier message are not part of "
    "this request. If the user asks about them, tell them to type @ and choose the friend again.";
NSString* const SPDFMacFriendsRedactedAnswer = @"(This earlier answer used Friends messages, which are not part of "
    "this request. If the user asks about it, tell them to type @ and choose the friend again.)";
NSString* const SPDFMacFriendsRedactedStepNotice = @"This step belonged to an earlier answer that used Friends "
    "messages, so it is not part of this request.";
NSString* const SPDFMacFriendsStoredResultNotice = @"These Friends messages were read for an earlier message and are "
    "not kept. To quote one again, read it with friends_read_messages and its message_id.";

// Sorted keys, so the same stub always serializes to the same text: the chat store refuses a save whose earlier
// messages differ from the file's (SPDFMacAIChatStore.mm -saveChat:error:).
static NSString* JSONText(NSDictionary* object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

static id ParsedJSON(id content) {
    NSData* data = [content isKindOfClass:NSString.class] ? [content dataUsingEncoding:NSUTF8StringEncoding] : nil;
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

static NSString* NoticeContent(NSString* notice) {
    return JSONText(@{@"notice" : notice});
}

NSSet<NSString*>* SPDFMacFriendsExcerptConversations(NSString* content) {
    id result = ParsedJSON(content);
    // Content that is not the gate's own JSON cannot be read for conversations; it counts as one unknown conversation
    // so that only an All Friends chats scope lets it through.
    if (![result isKindOfClass:NSDictionary.class]) return [NSSet setWithObject:@""];
    NSMutableSet* conversations = [NSMutableSet set];
    for (NSString* key in @[@"results", @"messages"]) {
        id excerpts = result[key];
        if (excerpts && ![excerpts isKindOfClass:NSArray.class]) [conversations addObject:@""];
        for (id excerpt in [excerpts isKindOfClass:NSArray.class] ? excerpts : @[]) {
            NSString* conversation = nil;
            id citation = [excerpt isKindOfClass:NSDictionary.class] ? excerpt[@"citation"] : nil;
            NSURL* url = [citation isKindOfClass:NSString.class] ? [NSURL URLWithString:citation] : nil;
            if (!SPDFMacFriendsParseMessageCitationURL(url, &conversation, NULL)) conversation = @"";
            [conversations addObject:conversation ?: @""];
        }
    }
    return conversations.count ? conversations : nil;
}

static NSSet<NSString*>* FriendsToolCallIDs(NSArray<NSDictionary*>* messages) {
    NSMutableSet* identifiers = [NSMutableSet set];
    for (NSDictionary* message in messages) {
        if (![message isKindOfClass:NSDictionary.class] || ![message[@"role"] isEqual:@"assistant"]) continue;
        id calls = message[@"tool_calls"];
        for (NSDictionary* call in [calls isKindOfClass:NSArray.class] ? calls : @[]) {
            if (![call isKindOfClass:NSDictionary.class]) continue;
            id function = call[@"function"];
            id name = [function isKindOfClass:NSDictionary.class] ? function[@"name"] : nil;
            if ([name isKindOfClass:NSString.class] && SPDFMacFriendsIsChatTool(name) &&
                [call[@"id"] isKindOfClass:NSString.class])
                [identifiers addObject:call[@"id"]];
        }
    }
    return identifiers;
}

BOOL SPDFMacFriendsChatHoldsFriendsResults(NSArray<NSDictionary*>* messages) {
    return FriendsToolCallIDs(messages).count > 0;
}

// An assistant message in a redacted turn: its words, opaque reasoning and call arguments go; the calls' ids and names
// stay so every result still answers a call. The ids are added to `laterCalls`.
static NSDictionary* RedactedAssistant(NSDictionary* message, NSMutableSet<NSString*>* laterCalls) {
    NSMutableDictionary* stub = [message mutableCopy];
    [stub removeObjectForKey:@"reasoning_details"];
    id content = message[@"content"];
    BOOL empty = !content || content == NSNull.null || ([content isKindOfClass:NSString.class] && ![content length]);
    if (!empty) stub[@"content"] = SPDFMacFriendsRedactedAnswer;
    id calls = message[@"tool_calls"];
    if (![calls isKindOfClass:NSArray.class]) return stub;
    NSMutableArray* redactedCalls = [NSMutableArray arrayWithCapacity:[calls count]];
    for (id call in calls) {
        id function = [call isKindOfClass:NSDictionary.class] ? call[@"function"] : nil;
        if (![function isKindOfClass:NSDictionary.class]) { [redactedCalls addObject:call]; continue; }
        if ([call[@"id"] isKindOfClass:NSString.class]) [laterCalls addObject:call[@"id"]];
        NSMutableDictionary* redactedFunction = [function mutableCopy];
        redactedFunction[@"arguments"] = @"{}";
        NSMutableDictionary* redactedCall = [call mutableCopy];
        redactedCall[@"function"] = redactedFunction;
        [redactedCalls addObject:redactedCall];
    }
    stub[@"tool_calls"] = redactedCalls;
    return stub;
}

// How SPDFMacAIChatVision.mm names the call behind a page image in its caption: the same serializer, so the same
// escaping.
static NSString* CaptionMarker(NSString* callID) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"tool_call_id" : callID} options:0 error:nil];
    NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    return text.length > 2 ? [text substringWithRange:NSMakeRange(1, text.length - 2)] : nil;
}

// Page images arrive as a user message mid-turn: a caption text part, then its image. A caption naming a later call
// is replaced, with its image; images for anything else stay.
static NSDictionary* RedactedPageImages(NSDictionary* message, NSSet<NSString*>* laterCalls) {
    NSMutableArray* markers = [NSMutableArray array];
    for (NSString* callID in laterCalls) {
        NSString* marker = CaptionMarker(callID);
        if (marker) [markers addObject:marker];
    }
    NSMutableArray* parts = [NSMutableArray array];
    BOOL dropping = NO, changed = NO;
    for (id part in message[@"content"]) {
        id type = [part isKindOfClass:NSDictionary.class] ? part[@"type"] : nil;
        if ([type isEqual:@"text"]) {
            NSString* text = [part[@"text"] isKindOfClass:NSString.class] ? part[@"text"] : @"";
            dropping = NO;
            for (NSString* marker in markers) dropping = dropping || [text containsString:marker];
            if (dropping) {
                changed = YES;
                [parts addObject:@{@"type" : @"text", @"text" : SPDFMacFriendsRedactedStepNotice}];
                continue;
            }
        } else if (dropping) {
            continue;
        }
        [parts addObject:part];
    }
    if (!changed) return message;
    NSMutableDictionary* stub = [message mutableCopy];
    stub[@"content"] = parts;
    return stub;
}

NSArray<NSDictionary*>* SPDFMacFriendsRedactChatHistory(NSArray<NSDictionary*>* messages,
                                                        BOOL (^covers)(NSSet<NSString*>* conversationIDs),
                                                        BOOL* holdsChats) {
    if (holdsChats) *holdsChats = NO;
    NSSet* friendsCalls = FriendsToolCallIDs(messages);
    if (!friendsCalls.count) return messages;
    NSMutableArray* sent = [NSMutableArray arrayWithCapacity:messages.count];
    BOOL turnRedacted = NO;
    // Calls the model made after reading an excerpt this request may not see, in the current turn.
    NSMutableSet<NSString*>* laterCalls = [NSMutableSet set];
    for (NSDictionary* original in messages) {
        NSDictionary* message = original;
        if (![message isKindOfClass:NSDictionary.class]) { [sent addObject:message]; continue; }
        id role = message[@"role"];
        id content = message[@"content"];
        // A turn starts at what the person typed. The vision projection (SPDFMacAIChatVision.mm) also inserts user
        // messages, holding rendered pages as content arrays, in the middle of a turn; those do not end it.
        if ([role isEqual:@"user"] && [content isKindOfClass:NSString.class]) {
            turnRedacted = NO;
            [laterCalls removeAllObjects];
        }
        if ([role isEqual:@"tool"] && [friendsCalls containsObject:message[@"tool_call_id"] ?: @""]) {
            NSSet* conversations = SPDFMacFriendsExcerptConversations(content);
            if (conversations && covers && covers(conversations)) {
                if (holdsChats) *holdsChats = YES;
            } else if (conversations) {
                NSMutableDictionary* stub = [message mutableCopy];
                stub[@"content"] = NoticeContent(SPDFMacFriendsRedactedResultNotice);
                message = stub;
                turnRedacted = YES;
            }
        } else if ([role isEqual:@"tool"] && [laterCalls containsObject:message[@"tool_call_id"] ?: @""]) {
            NSMutableDictionary* stub = [message mutableCopy];
            stub[@"content"] = NoticeContent(SPDFMacFriendsRedactedStepNotice);
            message = stub;
        } else if ([role isEqual:@"assistant"] && turnRedacted) {
            message = RedactedAssistant(message, laterCalls);
        } else if ([role isEqual:@"user"] && [content isKindOfClass:NSArray.class] && laterCalls.count) {
            message = RedactedPageImages(message, laterCalls);
        }
        [sent addObject:message];
    }
    return sent;
}

// A Friends result as the chat file keeps it: for each excerpt, only its message id and citation link. Content that
// is not the gate's JSON keeps one empty entry, so the stub still counts as an excerpt from an unknown conversation
// and the answers after it stay redacted for every scope but All Friends chats.
static NSString* StoredResultContent(NSString* content) {
    id result = ParsedJSON(content);
    NSDictionary* dictionary = [result isKindOfClass:NSDictionary.class] ? result : nil;
    if ([dictionary[@"notice"] isEqual:SPDFMacFriendsStoredResultNotice]) return content;
    if (!SPDFMacFriendsExcerptConversations(content)) return content; // a refusal or an empty search
    NSMutableArray* links = [NSMutableArray array];
    for (NSString* key in @[@"results", @"messages"]) {
        id excerpts = dictionary[key];
        for (id excerpt in [excerpts isKindOfClass:NSArray.class] ? excerpts : @[]) {
            NSMutableDictionary* link = [NSMutableDictionary dictionary];
            id messageID = [excerpt isKindOfClass:NSDictionary.class] ? excerpt[@"message_id"] : nil;
            id citation = [excerpt isKindOfClass:NSDictionary.class] ? excerpt[@"citation"] : nil;
            if ([messageID isKindOfClass:NSString.class] && [messageID length] <= 64) link[@"message_id"] = messageID;
            if ([citation isKindOfClass:NSString.class] && [citation length] <= 512) link[@"citation"] = citation;
            [links addObject:link];
        }
    }
    if (!links.count) [links addObject:@{}];
    return JSONText(@{@"notice" : SPDFMacFriendsStoredResultNotice, @"results" : links});
}

NSArray<NSDictionary*>* SPDFMacFriendsStoredChatHistory(NSArray<NSDictionary*>* messages) {
    NSSet* friendsCalls = FriendsToolCallIDs(messages);
    if (!friendsCalls.count) return messages;
    NSMutableArray* stored = [NSMutableArray arrayWithCapacity:messages.count];
    for (NSDictionary* message in messages) {
        if (![message isKindOfClass:NSDictionary.class] || ![message[@"role"] isEqual:@"tool"] ||
            ![friendsCalls containsObject:message[@"tool_call_id"] ?: @""] ||
            ![message[@"content"] isKindOfClass:NSString.class]) {
            [stored addObject:message];
            continue;
        }
        NSString* content = StoredResultContent(message[@"content"]);
        if (content == message[@"content"]) { [stored addObject:message]; continue; }
        NSMutableDictionary* stub = [message mutableCopy];
        stub[@"content"] = content;
        [stored addObject:stub];
    }
    return stored;
}

NSArray<NSDictionary*>* SPDFMacFriendsTitleChatHistory(NSArray<NSDictionary*>* messages) {
    NSArray* redacted = SPDFMacFriendsRedactChatHistory(messages, nil, NULL);
    NSMutableArray* titled = [NSMutableArray arrayWithCapacity:redacted.count];
    for (NSDictionary* message in redacted) {
        if ([message isKindOfClass:NSDictionary.class] && [message[@"role"] isEqual:@"assistant"] &&
            [message[@"content"] isEqual:SPDFMacFriendsRedactedAnswer]) {
            NSMutableDictionary* empty = [message mutableCopy];
            empty[@"content"] = @"";
            [titled addObject:empty];
        } else {
            [titled addObject:message];
        }
    }
    return titled;
}
