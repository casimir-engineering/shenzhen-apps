// friends-e2e-check: what the assistant sends shows on both sides, AI chat follows it to Delivered without reading the
// conversation, a message withdrawn before it left never arrives, one that may have arrived cannot be withdrawn, and
// the step shared by the Add by ID scenarios since the wave-4 re-check: an answer the host did not vouch for waits as
// a request until the requester accepts it.

#import "SZFriendsE2EScenarios.h"

#include <signal.h>

NSDictionary *SZFE2EUnconfirmedAnswer(NSDictionary *list, NSString *title) {
    NSDictionary *row = SZFE2ERowTitled(list, title);
    BOOL waits = [row[@"waiting"] isKindOfClass:[NSDictionary class]] &&
                 [row[@"waiting"][@"kind"] isEqual:@"request"];
    return waits && [row[@"subtitle"] hasPrefix:@"Answered your request for "] ? row : nil;
}

BOOL SZFE2EAcceptAnswer(SZFE2EClient *client, NSString *list, NSString *title) {
    CHECK(SZFE2EWaitUntil(30, ^BOOL { return SZFE2EUnconfirmedAnswer([client dataFor:list], title) != nil; }),
          "%@'s answer waits for acceptance: %@", title, [client dataFor:list][@"rows"]);
    NSString *conversation = SZFE2EUnconfirmedAnswer([client dataFor:list], title)[@"conversation_id"];
    NSString *card = [client openConversation:conversation];
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              NSDictionary *request = [client dataFor:card][@"request"];
              return [request isKindOfClass:[NSDictionary class]] &&
                     [request[@"footnote"] hasPrefix:@"Friends couldn’t confirm that "];
          }),
          "its card says why it waits: %@", [client dataFor:card][@"request"]);
    [client intent:@"unsubscribe" fields:@{@"subscription" : card}];
    CHECK([[client intent:@"accept_request" fields:@{@"conversation_id" : conversation}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return [SZFE2ERowWithID([client dataFor:list], conversation)[@"drop_label"] isKindOfClass:NSString.class];
          }),
          "%@ is a friend once accepted: %@", title, SZFE2ERowWithID([client dataFor:list], conversation));
    return YES;
}

static NSDictionary *SZFE2EItemWithText(NSDictionary *conversation, NSString *text) {
    for (NSDictionary *item in SZFE2EItems(conversation, @"message"))
        if ([item[@"text"] isEqual:text]) return item;
    return nil;
}

static NSDictionary *SZFE2EFileItem(NSDictionary *conversation, NSString *name) {
    for (NSDictionary *item in SZFE2EItems(conversation, @"transfer"))
        if ([item[@"file"][@"name"] isEqual:name]) return item;
    return nil;
}

// PROTOCOL.md § Intents, Via the assistant: a message and a file Ana's assistant wrote arrive marked on Ben's side,
// named as Ana's assistant, and show as via the assistant on Ana's own; a client whose app has no assistant cannot
// claim one wrote anything.
BOOL SZFE2EScenarioViaAssistant(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSString *text = @"Pages 3–5 changed: the bracket moved **4 mm**.";
    NSDictionary *refused = [pair.a intent:@"send_message"
                                    fields:@{@"conversation_id" : pair.bAtA, @"text" : text,
                                             @"client_token" : SZFE2EToken(), @"via_assistant" : @YES}];
    CHECK(![refused[@"ok"] boolValue] && [refused[@"error"][@"code"] isEqual:@"not_allowed"],
          "a view without an assistant cannot say the assistant sent it: %@", refused);
    SZFE2EClient *assistant = [SZFE2EClient clientForHelper:pair.helperA capabilities:@[ @"assistant.chats" ]];
    CHECK(assistant != nil, "Ana's AI chat connects");
    NSDictionary *sent = [assistant intent:@"send_message"
                                    fields:@{@"conversation_id" : pair.bAtA, @"text" : text,
                                             @"client_token" : SZFE2EToken(), @"via_assistant" : @YES}];
    CHECK([sent[@"ok"] boolValue], "the assistant sends a message: %@", sent);
    NSString *file = [world fileOfSize:2048 named:@"Bracket drawing rev B.pdf"];
    NSDictionary *offered = [assistant intent:@"send_files"
                                       fields:@{@"conversation_id" : pair.bAtA, @"files" : @[ @{@"path" : file} ],
                                                @"client_token" : SZFE2EToken(), @"via_assistant" : @YES}];
    CHECK([offered[@"ok"] boolValue], "and a file: %@", offered);
    NSString *atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              NSDictionary *data = [pair.b dataFor:atB];
              return SZFE2EItemWithText(data, text) != nil && SZFE2EFileItem(data, file.lastPathComponent) != nil;
          }),
          "both reach Ben: %@", [pair.b dataFor:atB][@"items"]);
    NSDictionary *atBen = SZFE2EItemWithText([pair.b dataFor:atB], text);
    CHECK([atBen[@"assistant_label"] isEqual:@"Via Ana’s assistant"] &&
              [atBen[@"text_format"] isEqual:@"markdown"],
          "Ben sees whose assistant sent it, and the Markdown Ana's assistant wrote: %@", atBen);
    CHECK([SZFE2EFileItem([pair.b dataFor:atB], file.lastPathComponent)[@"assistant_label"]
              isEqual:@"Via Ana’s assistant"],
          "the file says so too: %@", SZFE2EFileItem([pair.b dataFor:atB], file.lastPathComponent));
    NSString *atA = [pair.a openConversation:pair.bAtA];
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return [SZFE2EItemWithText([pair.a dataFor:atA], text)[@"assistant_label"]
                  isEqual:@"Via the assistant"];
          }),
          "Ana's own view: %@", SZFE2EItemWithText([pair.a dataFor:atA], text));
    NSDictionary *typed = [pair.a intent:@"send_message" fields:@{@"conversation_id" : pair.bAtA, @"text" : @"Thanks",
                                                                  @"client_token" : SZFE2EToken()}];
    CHECK([typed[@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EItemWithText([pair.b dataFor:atB], @"Thanks") != nil; }));
    CHECK(SZFE2EItemWithText([pair.b dataFor:atB], @"Thanks")[@"assistant_label"] == [NSNull null],
          "what Ana typed herself carries no label");
    [assistant close];
    return YES;
}

// PROTOCOL.md § Views, message_status: Ana's AI chat follows what she sent from it. It reads queued while Ben is away
// and delivered once he is back, without opening the conversation, so Ben's question to Ana stays unread. The real
// welcome it connected with carries the link menu's words.
BOOL SZFE2EScenarioMessageStatus(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    SZFE2EClient *assistant = [SZFE2EClient clientForHelper:pair.helperA capabilities:@[ @"assistant.chats" ]];
    CHECK(assistant != nil, "Ana's AI chat connects");
    NSDictionary *strings = assistant.welcome[@"strings"];
    CHECK([strings[@"link_open"] isEqual:@"Open in Browser"] && [strings[@"link_open_email"] isEqual:@"New Email"] &&
              [strings[@"link_elsewhere"] isEqual:@"Goes to {host}, not {shown}"],
          "the link menu's words: %@", strings);
    CHECK([assistant.welcome[@"capabilities"] containsObject:@"messages.status"], "%@",
          assistant.welcome[@"capabilities"]);
    NSDictionary *asked = [pair.b intent:@"send_message"
                                  fields:@{@"conversation_id" : pair.aAtB, @"text" : @"Are pages 3–5 ready?",
                                           @"client_token" : SZFE2EToken()}];
    CHECK([asked[@"ok"] boolValue], "Ben asks: %@", asked);
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return [SZFE2ERowWithID([pair.a dataFor:pair.listA], pair.bAtA)[@"unread"] boolValue];
          }),
          "Ben's question waits unread: %@", SZFE2ERowWithID([pair.a dataFor:pair.listA], pair.bAtA));
    [pair.b close];
    CHECK([pair.helperB terminate], "Ben's Mac goes away");
    NSDictionary *sent = [assistant intent:@"send_message"
                                    fields:@{@"conversation_id" : pair.bAtA, @"text" : @"Yes, sending them now.",
                                             @"client_token" : SZFE2EToken(), @"via_assistant" : @YES}];
    NSString *messageID = sent[@"result"][@"message_id"];
    CHECK(messageID.length > 0, "Ana sends from AI chat: %@", sent);
    NSString *watch = [assistant subscribe:@"message_status" params:@{@"message_ids" : @[ messageID ]}];
    CHECK(watch != nil, "AI chat follows it");
    NSDictionary * (^status)(void) = ^NSDictionary * {
        return [[assistant dataFor:watch][@"messages"] firstObject][@"status"];
    };
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return [status()[@"state"] isEqual:@"queued"]; }), "queued while Ben is away: %@",
          [assistant dataFor:watch]);
    CHECK([status()[@"label"] isEqual:@"Sends when Ben is nearby"], "%@", status());
    pair.helperB.extraEnvironment = @{};
    CHECK([pair.helperB start], "Ben is back");
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.b != nil, "with ShenzhenPDF open");
    CHECK(SZFE2EWaitUntil(30, ^BOOL { return [status()[@"state"] isEqual:@"delivered"]; }),
          "delivered once Ben is back: %@", [assistant dataFor:watch]);
    CHECK([status()[@"label"] isEqual:@"Delivered"], "%@", status());
    CHECK([SZFE2ERowWithID([pair.a dataFor:pair.listA], pair.bAtA)[@"unread"] boolValue],
          "following the send read nothing: %@", SZFE2ERowWithID([pair.a dataFor:pair.listA], pair.bAtA));
    [assistant close];
    return YES;
}

static NSDictionary *SZFE2EItemWithID(NSDictionary *conversation, NSString *itemID) {
    for (NSDictionary *item in SZFE2EItems(conversation, @"message"))
        if ([item[@"item_id"] isEqual:itemID]) return item;
    return nil;
}

static BOOL SZFE2EOffersCancel(NSDictionary *item) {
    return [[item[@"actions"] valueForKey:@"action"] containsObject:@"cancel_message"];
}

// PROTOCOL.md § Intents, cancel_message: a message Ana withdraws while Ben is away says Cancelled on her side, in her
// conversation and in AI chat's message_status, and never reaches Ben when he is back, while the one she kept does.
// One that already reached Ben cannot be withdrawn: the reply says so, and it stays Delivered.
BOOL SZFE2EScenarioCancelMessage(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    SZFE2EClient *assistant = [SZFE2EClient clientForHelper:pair.helperA capabilities:@[ @"assistant.chats" ]];
    CHECK(assistant != nil, "Ana's AI chat connects");
    CHECK([assistant.welcome[@"capabilities"] containsObject:@"messages.cancel"], "%@",
          assistant.welcome[@"capabilities"]);
    NSDictionary *early = [assistant intent:@"send_message"
                                     fields:@{@"conversation_id" : pair.bAtA, @"text" : @"Pages 3–5 are ready.",
                                              @"client_token" : SZFE2EToken(), @"via_assistant" : @YES}];
    NSString *earlyID = early[@"result"][@"message_id"];
    CHECK(earlyID.length > 0, "Ana sends while Ben is nearby: %@", early);
    NSString *watch = [assistant subscribe:@"message_status" params:@{@"message_ids" : @[ earlyID ]}];
    NSDictionary * (^status)(NSString *) = ^NSDictionary *(NSString *subscription) {
        return [[assistant dataFor:subscription][@"messages"] firstObject][@"status"];
    };
    CHECK(watch && SZFE2EWaitUntil(10, ^BOOL { return [status(watch)[@"state"] isEqual:@"delivered"]; }),
          "it reaches Ben: %@", [assistant dataFor:watch]);
    NSDictionary *late = [assistant intent:@"cancel_message" fields:@{@"message_id" : earlyID}];
    CHECK(![late[@"ok"] boolValue] && [late[@"error"][@"code"] isEqual:@"stale"] &&
              [late[@"error"][@"details"][@"state"] isEqual:@"delivered"] &&
              [late[@"error"][@"message"] isEqual:@"Ben already has it, so it can’t be cancelled."],
          "too late, and the reply says why: %@", late);
    CHECK([status(watch)[@"state"] isEqual:@"delivered"], "it stays Delivered: %@", status(watch));
    [pair.b close];
    CHECK([pair.helperB terminate], "Ben's Mac goes away");
    NSDictionary *wrong = [assistant intent:@"send_message"
                                     fields:@{@"conversation_id" : pair.bAtA, @"text" : @"The dates are on page 5.",
                                              @"client_token" : SZFE2EToken(), @"via_assistant" : @YES}];
    NSDictionary *kept = [pair.a intent:@"send_message" fields:@{@"conversation_id" : pair.bAtA,
                                                                 @"text" : @"The dates are on page 4.",
                                                                 @"client_token" : SZFE2EToken()}];
    NSString *wrongID = wrong[@"result"][@"message_id"], *keptID = kept[@"result"][@"message_id"];
    CHECK(wrongID.length > 0 && keptID.length > 0, "both wait for Ben: %@ %@", wrong, kept);
    NSString *atA = [pair.a openConversation:pair.bAtA];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *item = SZFE2EItemWithID([pair.a dataFor:atA], wrongID);
              return [item[@"status"][@"state"] isEqual:@"queued"] && SZFE2EOffersCancel(item);
          }),
          "a queued message offers Cancel: %@", SZFE2EItemWithID([pair.a dataFor:atA], wrongID));
    NSDictionary *cancelled = [pair.a intent:@"cancel_message" fields:@{@"message_id" : wrongID}];
    CHECK([cancelled[@"ok"] boolValue], "Ana cancels it from the conversation: %@", cancelled);
    NSDictionary *withdrawn = SZFE2EItemWithID([pair.a dataFor:atA], wrongID);
    CHECK([withdrawn[@"status"][@"state"] isEqual:@"cancelled"] &&
              [withdrawn[@"status"][@"label"] isEqual:@"Cancelled"] && !SZFE2EOffersCancel(withdrawn),
          "the snapshot before the reply says Cancelled and offers nothing: %@", withdrawn);
    NSString *followed = [assistant subscribe:@"message_status" params:@{@"message_ids" : @[ wrongID ]}];
    CHECK(followed && SZFE2EWaitUntil(10, ^BOOL { return [status(followed)[@"state"] isEqual:@"cancelled"]; }),
          "AI chat's card hears it: %@", [assistant dataFor:followed]);
    CHECK([[assistant intent:@"cancel_message" fields:@{@"message_id" : wrongID}][@"ok"] boolValue],
          "cancelling again, as after a lost reply, is fine");
    CHECK(SZFE2EOffersCancel(SZFE2EItemWithID([pair.a dataFor:atA], keptID)), "the other still waits, with Cancel");
    pair.helperB.extraEnvironment = @{};
    CHECK([pair.helperB start], "Ben is back");
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.b != nil, "with ShenzhenPDF open");
    NSString *atB = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return SZFE2EItemWithText([pair.b dataFor:atB], @"The dates are on page 4.") != nil;
          }),
          "the kept message reaches Ben: %@", [pair.b dataFor:atB][@"items"]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2EItemWithID([pair.a dataFor:atA], keptID)[@"status"][@"state"] isEqual:@"delivered"];
          }),
          "and Ana sees it delivered: %@", SZFE2EItemWithID([pair.a dataFor:atA], keptID));
    CHECK(!SZFE2EItemWithText([pair.b dataFor:atB], @"The dates are on page 5.") &&
              [SZFE2EItemWithID([pair.a dataFor:atA], wrongID)[@"status"][@"state"] isEqual:@"cancelled"],
          "the cancelled one never left: %@", [pair.b dataFor:atB][@"items"]);
    [assistant close];
    return YES;
}

// Review (wave 5, round 3): a message written to Ben's helper whose acknowledgement never came goes back to Queued
// when the session drops, yet Ben's Mac may have stored it. Cancel is then refused with details.state `sent` and words
// for Ana, and her conversation no longer offers it.
BOOL SZFE2EScenarioCancelAfterLostAck(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSString *atA = [pair.a openConversation:pair.bAtA];
    NSDictionary *first = [pair.a intent:@"send_message" fields:@{@"conversation_id" : pair.bAtA,
                                                                  @"text" : @"Pages 3–5 are ready.",
                                                                  @"client_token" : SZFE2EToken()}];
    NSString *firstID = first[@"result"][@"message_id"];
    CHECK(firstID.length && SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2EItemWithID([pair.a dataFor:atA], firstID)[@"status"][@"state"] isEqual:@"delivered"];
          }),
          "a session to Ben is live: %@", [pair.a dataFor:atA][@"items"]);
    // Ben's helper stops answering: the next message is written to the live session, and no acknowledgement comes.
    CHECK(kill(pair.helperB.pid, SIGSTOP) == 0, "Ben's helper pauses");
    NSDictionary *second = [pair.a intent:@"send_message" fields:@{@"conversation_id" : pair.bAtA,
                                                                   @"text" : @"The dates are on page 4.",
                                                                   @"client_token" : SZFE2EToken()}];
    NSString *secondID = second[@"result"][@"message_id"];
    NSDictionary * (^item)(void) = ^NSDictionary * { return SZFE2EItemWithID([pair.a dataFor:atA], secondID); };
    CHECK(secondID.length && SZFE2EWaitUntil(10, ^BOOL { return [item()[@"status"][@"state"] isEqual:@"sending"]; }),
          "written to Ben's helper: %@", item());
    // Ben's Mac goes away before it answers: the session drops and the message waits again.
    [pair.helperB kill9];
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              NSString *state = item()[@"status"][@"state"];
              return [state isEqual:@"queued"] || [state isEqual:@"connecting"];
          }),
          "it waits for Ben again: %@", item());
    CHECK(!SZFE2EOffersCancel(item()), "but offers no Cancel, since Ben's Mac may have it: %@", item());
    NSDictionary *refused = [pair.a intent:@"cancel_message" fields:@{@"message_id" : secondID}];
    CHECK(![refused[@"ok"] boolValue] && [refused[@"error"][@"code"] isEqual:@"stale"] &&
              [refused[@"error"][@"details"][@"state"] isEqual:@"sent"] &&
              [refused[@"error"][@"message"] isEqual:@"Ben may already have it, so it can’t be cancelled."],
          "Cancel is refused, and the reply says why: %@", refused);
    CHECK(![item()[@"status"][@"state"] isEqual:@"cancelled"], "it still waits to be delivered: %@", item());
    return YES;
}
