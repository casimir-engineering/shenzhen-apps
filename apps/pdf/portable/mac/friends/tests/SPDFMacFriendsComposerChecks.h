// The `@` chip as text: choices, extraction, the "@Name" the model reads, and the composer's note.
// Included by SPDFMacFriendsScopeTests.mm.

#pragma once

static void CheckComposerText(void) {
    NSArray* rows = @[@{@"conversation_id" : @"c_mei", @"title" : @"Mei", @"waiting" : NSNull.null},
                      @{@"conversation_id" : @"c_new", @"title" : @"Stranger", @"waiting" : @{@"kind" : @"request"}},
                      @{@"conversation_id" : @"c_kenji", @"title" : @"Kenji", @"waiting" : @{@"kind" : @"offer"}},
                      @{@"conversation_id" : @"", @"title" : @"broken"}];
    NSArray* choices = SPDFMacFriendsScopeChoices(rows);
    NSArray* names = [choices valueForKey:@"name"];
    Expect(([names isEqual:@[@"All Friends chats", @"Mei", @"Kenji"]]), @"choices %@", names);
    Expect(SPDFMacFriendsScopeForChoice(choices[0]).conversationIDs == nil, @"All Friends chats must mean all");

    NSFont* font = [NSFont systemFontOfSize:13];
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] initWithString:@"Ask "];
    [text appendAttributedString:[SPDFMacFriendsScopeToken chipWithScope:SPDFMacFriendsScopeForChoice(choices[1])
                                                                     font:font]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" and "]];
    [text appendAttributedString:[SPDFMacFriendsScopeToken chipWithScope:SPDFMacFriendsScopeForChoice(choices[2])
                                                                     font:font]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" about it  "]];
    SPDFMacFriendsScopeRequest* scope = SPDFMacFriendsScopeInText(text);
    Expect(([scope.conversationIDs isEqual:@[@"c_mei", @"c_kenji"]]), @"scope %@", scope.conversationIDs);
    Expect([SPDFMacFriendsPlainTextReplacingChips(text) isEqual:@"Ask @Mei and @Kenji about it"],
           @"plain %@", SPDFMacFriendsPlainTextReplacingChips(text));
    // The assistant may write messages to named friends (ai-agent-capabilities.md § 1), and the person sends them.
    Expect([SPDFMacFriendsComposerNote(text) isEqual:@"With this message, the assistant may read your chats with Mei "
                                                      "and Kenji and write messages to them for you to send. What it "
                                                      "reads goes to OpenRouter, with no training and nothing kept."],
           @"note %@", SPDFMacFriendsComposerNote(text));
    [text appendAttributedString:[SPDFMacFriendsScopeToken chipWithScope:SPDFMacFriendsScopeRequest.allChats
                                                                     font:font]];
    Expect(SPDFMacFriendsScopeInText(text).conversationIDs == nil, @"any All Friends chats chip makes it all");
    // All Friends chats reads everything but writes to no one; the friends chosen one by one may still be written to.
    Expect([SPDFMacFriendsComposerNote(text) isEqual:@"With this message, the assistant may read all your Friends "
                                                      "chats and write messages to Mei and Kenji for you to send. What "
                                                      "it reads goes to OpenRouter, with no training and nothing "
                                                      "kept."],
           @"all note %@", SPDFMacFriendsComposerNote(text));
    NSAttributedString* all = [SPDFMacFriendsScopeToken chipWithScope:SPDFMacFriendsScopeRequest.allChats font:font];
    Expect(![SPDFMacFriendsComposerNote(all) containsString:@"send"],
           @"All Friends chats alone must not claim sending");
    Expect(!SPDFMacFriendsScopeInText([[NSAttributedString alloc] initWithString:@"no chips"]) &&
           !SPDFMacFriendsScopeNote(nil), @"no chip, no scope and no note");
    SPDFMacFriendsScopeRequest* one = [SPDFMacFriendsScopeRequest conversationIDs:@[@"c_priya"] labels:@[@"Priya"]];
    Expect([SPDFMacFriendsScopeNote(one) containsString:@"your chat with Priya and write messages to Priya for you "
                                                         "to send."],
           @"one-friend note %@", SPDFMacFriendsScopeNote(one));

    // `#` file chips: "#Title" for the model, the file (and its revision) for the request, nothing typed counts.
    SPDFMacAIRequestChip* file = SPDFMacFriendsFileChip([NSURL fileURLWithPath:@"/tmp/attach/Contract.pdf"],
                                                        @"Contract.pdf", @{@"source" : @"file", @"size" : @1});
    NSMutableAttributedString* attached = [[NSMutableAttributedString alloc] initWithString:@"Send "];
    [attached appendAttributedString:[SPDFMacFriendsFileToken chipWithFile:file font:font]];
    [attached appendAttributedString:[[NSAttributedString alloc] initWithString:@" to #Kenji"]];
    NSArray* files = SPDFMacFriendsFileChipsInText(attached);
    Expect([file.kind isEqual:SPDFMacAIChipKindDocument] && files.count == 1 && files[0] == file &&
           SPDFMacFriendsTextHasChips(attached) &&
           [SPDFMacFriendsPlainTextReplacingChips(attached) isEqual:@"Send #Contract.pdf to #Kenji"] &&
           !SPDFMacFriendsScopeInText(attached), @"file chips: %@", SPDFMacFriendsPlainTextReplacingChips(attached));
    Expect([SPDFMacFriendsFileChip([NSURL fileURLWithPath:@"/tmp/a.jpg"], nil, nil).kind
               isEqual:SPDFMacAIChipKindAttachment] && !SPDFMacFriendsFileChip(nil, @"x", nil) &&
           !SPDFMacFriendsTextHasChips([[NSAttributedString alloc] initWithString:@"#typed @typed"]),
           @"a dropped file is an attachment; typed # and @ are only text");

    Expect(SPDFMacFriendsCaretFollowsMentionTrigger(@"@", 1) && SPDFMacFriendsCaretFollowsMentionTrigger(@"hi @", 4) &&
           SPDFMacFriendsCaretFollowsMentionTrigger(@"(@", 2), @"an @ starting a word opens the picker");
    Expect(!SPDFMacFriendsCaretFollowsMentionTrigger(@"mei@", 4) &&
           !SPDFMacFriendsCaretFollowsMentionTrigger(@"a", 1) &&
           !SPDFMacFriendsCaretFollowsMentionTrigger(@"@x", 2), @"an @ inside a word or address does not");
}
