// friends-ui-e2e's Mac half of a test with a phone (SPDFMacFriendsUIE2E.h): the person's Mac, ShenzhenPDF's real
// Friends dropdown on a real helper in a test home, driven step by step by a script on the other side (Shenzhen 3D's
// scripts/friends/phones-get-again.mjs and phones-join.mjs, which drive the phone in an emulator). Only when
// FRIENDS_UI_E2E_PHONE_IN and FRIENDS_UI_E2E_PHONE_OUT name two FIFOs; any other run skips it. SZFRIENDS_TEST_HOST_LIST
// and _KEYS, when set, reach its helper, which then goes online.
//
// The script writes one JSON command per line to the first and reads one JSON answer per line from the second:
//   intent {type, fields}       through another app's client on the same helper (setting up: joining, sending)
//   data {view, params}         that view's snapshot as the helper sends it
//   conversation {id}           a conversation's snapshot
//   open {title}                the dropdown opens and the person clicks that row, as a person does
//   press {near, label}         clicks the button titled `label` on the item showing `near` (a file's name)
//   text {near, text, seconds}  waits until the item showing `near` says `text`
//   list                        the dropdown opens on its list, as a person comes back to it
//   click {label}               clicks the visible button titled `label` on the page showing (Approve, Use my
//                               existing profile…, Continue, Join), then waits for the page to settle
//   fill {placeholder, text}    clicks the field showing `placeholder` and types `text` into it
//   join_code                   the code a join request shows, as drawn ("4831 2207"), once Approve has drawn one
//   see {text, seconds}         waits until the page showing says `text` (scrolled into sight)
//   shot {name}                 a screenshot of the popover
//   log                         the end of the helper's log (what a failing step leaves to read)
//   end                         stops
// Every answer has "ok"; a failed step adds "why" and what the popover shows.

#import "SPDFMacFriendsUIPairInternal.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDevices.h"

static NSDictionary* UIPhoneRead(FILE* in) {
    char* line = NULL;
    size_t capacity = 0;
    ssize_t length = getline(&line, &capacity, in);
    NSDictionary* command = nil;
    if (length > 0) {
        NSData* data = [NSData dataWithBytes:line length:(NSUInteger)length];
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        command = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{@"cmd" : @"?"};
    }
    free(line);
    return command;
}

static void UIPhoneWrite(FILE* out, NSDictionary* answer) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:answer options:0 error:nil] ?: [NSData data];
    fwrite(data.bytes, 1, data.length, out);
    fputc('\n', out);
    fflush(out);
}

// The item view (one message or file of the conversation) whose words include `near`, scrolled into sight.
static SZFriendsItemView* UIPhoneItem(UIRig* rig, NSString* near) {
    NSView* view = UIReveal(rig.content, near);
    while (view && ![view isKindOfClass:SZFriendsItemView.class]) view = view.superview;
    return (SZFriendsItemView*)view;
}

static NSDictionary* UIPhoneFailed(UIRig* rig, NSString* why) {
    return @{@"ok" : @NO, @"why" : why, @"shows" : UIDescribe(rig.content)};
}

static NSDictionary* UIPhoneData(SZFE2EClient* client, NSString* subscription) {
    __block NSDictionary* data = nil;
    UIWait(10, ^BOOL { return (data = [client dataFor:subscription]) != nil; });
    [client intent:@"unsubscribe" fields:@{@"subscription" : subscription}];
    return data ? @{@"ok" : @YES, @"data" : data} : @{@"ok" : @NO, @"why" : @"no snapshot"};
}

// The dropdown open on its list: closed and opened again, then Back until the list shows.
static NSString* _Nullable UIPhoneToList(UIRig* rig) {
    UICloseDropdown(rig);
    if (!UIOpenDropdown(rig)) return @"the dropdown does not open";
    if (rig.dropdown.currentView == SZFriendsDropdownViewList) return nil;
    NSString* why = nil;
    // The pages with a badge say "Back to Friends"; the join page's header has a plain Back.
    NSButton* back = UIFindButton(rig.content, @"Back to Friends") ?: UIFindButton(rig.content, @"Back");
    if (!back || !UIClick(back, &why)) return why ?: @"no way back to the list";
    if (!UIWait(5, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewList; }))
        return @"Back does not reach the list";
    return nil;
}

// The field whose placeholder is `placeholder`, visible on the page showing.
static NSTextField* _Nullable UIPhoneField(UIRig* rig, NSString* placeholder) {
    for (NSView* view in UIAllViews(rig.content))
        if ([view isKindOfClass:NSTextField.class] && [((NSTextField*)view).placeholderString isEqual:placeholder] &&
            UIVisible(view))
            return (NSTextField*)view;
    return nil;
}

// Joining's steps on the Mac (PROTOCOL.md § Joining): a button, a field, the code a request shows, words on the page.
static NSDictionary* _Nullable UIPhoneJoinStep(UIRig* rig, NSDictionary* command) {
    NSString* cmd = command[@"cmd"];
    if ([cmd isEqual:@"list"]) {
        NSString* why = UIPhoneToList(rig);
        return why ? UIPhoneFailed(rig, why) : @{@"ok" : @YES};
    }
    if ([cmd isEqual:@"click"]) {
        __block NSButton* button = nil;
        if (!UIWait(30, ^BOOL { return (button = UIFindButton(rig.content, command[@"label"])) != nil; }))
            return UIPhoneFailed(rig, [NSString stringWithFormat:@"no button %@", command[@"label"]]);
        NSString* why = nil;
        if (!UIClick(button, &why)) return UIPhoneFailed(rig, why ?: @"the button takes no click");
        UISpin(0.3);
        return @{@"ok" : @YES};
    }
    if ([cmd isEqual:@"fill"]) {
        __block NSTextField* field = nil;
        if (!UIWait(15, ^BOOL { return (field = UIPhoneField(rig, command[@"placeholder"])) != nil; }))
            return UIPhoneFailed(rig, [NSString stringWithFormat:@"no field %@", command[@"placeholder"]]);
        NSString* why = nil;
        if (!UIClick(field, &why) && ![field.window makeFirstResponder:field])
            return UIPhoneFailed(rig, why ?: @"the field takes no typing");
        UIClearField(field.window);
        return UIType(field.window, command[@"text"]) ? @{@"ok" : @YES} : UIPhoneFailed(rig, @"typing went nowhere");
    }
    if ([cmd isEqual:@"join_code"]) {
        __block NSString* code = nil;
        UIWait(30, ^BOOL {
            for (SZFriendsJoinRequestView* request in rig.listPage.devicesView.requestViews)
                if (!request.codeLabel.hidden && request.codeLabel.stringValue.length)
                    code = request.codeLabel.stringValue;
            return code != nil;
        });
        return code ? @{@"ok" : @YES, @"code" : code} : UIPhoneFailed(rig, @"no code shows");
    }
    if ([cmd isEqual:@"see"]) {
        NSString* text = command[@"text"];
        NSTimeInterval seconds = [command[@"seconds"] doubleValue] ?: 30;
        BOOL shown = UIWait(seconds, ^BOOL { return UIReveal(rig.content, text) != nil; });
        return shown ? @{@"ok" : @YES} : UIPhoneFailed(rig, [NSString stringWithFormat:@"never says %@", text]);
    }
    return nil;
}

static NSDictionary* UIPhoneStep(UIRig* rig, SZFE2EClient* client, NSDictionary* command) {
    NSDictionary* joining = UIPhoneJoinStep(rig, command);
    if (joining) return joining;
    NSString* cmd = command[@"cmd"];
    if ([cmd isEqual:@"intent"]) {
        NSDictionary* reply = [client intent:command[@"type"] fields:command[@"fields"]];
        return reply ? @{@"ok" : reply[@"ok"] ?: @NO, @"reply" : reply} : @{@"ok" : @NO, @"why" : @"no reply"};
    }
    if ([cmd isEqual:@"data"]) {
        id params = command[@"params"];
        NSString* view = command[@"view"];
        return UIPhoneData(client, [client subscribe:view params:params == NSNull.null ? nil : params]);
    }
    if ([cmd isEqual:@"conversation"]) return UIPhoneData(client, [client openConversation:command[@"id"]]);
    if ([cmd isEqual:@"open"]) {
        // Back to the list first, as a person coming back to the chat does: the conversation is opened anew.
        NSString* away = UIPhoneToList(rig);
        if (away) return UIPhoneFailed(rig, away);
        __block SZFriendsRowView* row = nil;
        if (!UIWait(15, ^BOOL { return (row = UIRow(rig, command[@"title"])) != nil; }))
            return UIPhoneFailed(rig, @"no such row");
        NSString* why = nil;
        if (!UIClick(row, &why)) return UIPhoneFailed(rig, why ?: @"the row takes no click");
        if (!UIWait(10, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewConversation; }))
            return UIPhoneFailed(rig, @"the conversation does not open");
        return @{@"ok" : @YES};
    }
    if ([cmd isEqual:@"press"]) {
        NSString* near = command[@"near"], *label = command[@"label"];
        __block NSButton* button = nil;
        BOOL found = UIWait(30, ^BOOL {
            SZFriendsItemView* item = UIPhoneItem(rig, near);
            return item && (button = UIFindButton(item, label)) != nil;
        });
        if (!found) return UIPhoneFailed(rig, [NSString stringWithFormat:@"no %@ on %@", label, near]);
        NSString* why = nil;
        if (!UIClick(button, &why)) return UIPhoneFailed(rig, why ?: @"the button takes no click");
        return @{@"ok" : @YES};
    }
    if ([cmd isEqual:@"text"]) {
        NSString* near = command[@"near"], *text = command[@"text"];
        NSTimeInterval seconds = [command[@"seconds"] doubleValue] ?: 30;
        BOOL shown = UIWait(seconds, ^BOOL {
            SZFriendsItemView* item = UIPhoneItem(rig, near);
            return item && UIFindText(item, text) != nil;
        });
        return shown ? @{@"ok" : @YES} : UIPhoneFailed(rig, [NSString stringWithFormat:@"%@ never says %@", near, text]);
    }
    if ([cmd isEqual:@"shot"]) return @{@"ok" : @(UIShot(rig, command[@"name"]))};
    if ([cmd isEqual:@"log"]) return @{@"ok" : @YES, @"log" : rig.helper.log ?: @""};
    return @{@"ok" : @NO, @"why" : [NSString stringWithFormat:@"unknown command %@", cmd]};
}

BOOL UIFlowPhone(SZFE2EWorld* world, UIVariant* variant) {
    const char *inPath = getenv("FRIENDS_UI_E2E_PHONE_IN"), *outPath = getenv("FRIENDS_UI_E2E_PHONE_OUT");
    if (!inPath || !outPath || !*inPath || !*outPath) return YES; // only with the phone's script
    FILE* out = fopen(outPath, "w");
    FILE* in = out ? fopen(inPath, "r") : NULL;
    if (!in) return NO;
    [world beginScenario:[@"phone-" stringByAppendingString:variant.name]];
    // Online (phones-join.mjs --route online): the helper checks in with the script's local host.
    NSMutableDictionary<NSString*, NSString*>* online = [NSMutableDictionary dictionary];
    for (NSString* key in @[ @"SZFRIENDS_TEST_HOST_LIST", @"SZFRIENDS_TEST_HOST_KEYS" ]) {
        const char* value = getenv(key.UTF8String);
        if (value && *value) online[key] = @(value);
    }
    UIRig* rig = UIStartRig(world, variant, @"mac", online);
    SZFE2EClient* client = rig ? [SZFE2EClient clientForHelper:rig.helper] : nil;
    BOOL passed = client != nil && [[client intent:@"activate" fields:nil][@"ok"] boolValue];
    if (rig) UIBeginFlow(rig, @"phone");
    BOOL stepsPassed = YES;
    UIPhoneWrite(out, @{@"ok" : @(passed), @"downloads" : rig.helper.downloadsDirectory ?: @"",
                        @"service_type" : world.serviceType});
    while (passed) {
        NSDictionary* command = UIPhoneRead(in);
        if (!command || [command[@"cmd"] isEqual:@"end"]) break;
        NSDictionary* answer = UIPhoneStep(rig, client, command);
        stepsPassed = stepsPassed && [answer[@"ok"] boolValue];
        if (![answer[@"ok"] boolValue]) fprintf(stderr, "phone step %s: %s\n", [command[@"cmd"] UTF8String],
                                                 [answer.description UTF8String]);
        UIPhoneWrite(out, answer);
    }
    UIPhoneWrite(out, @{@"ok" : @YES, @"ended" : @YES});
    fclose(in);
    fclose(out);
    [client close];
    if (rig) UIStopRig(rig);
    [world endScenario];
    UIRecord(variant, @"phone: the Mac half, step by step", passed && stepsPassed);
    return passed && stepsPassed;
}
