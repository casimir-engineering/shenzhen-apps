// Failed items and the states the contracts pass added: the words for each of the store's failure keys and when Try
// again shows, an outgoing message with no delivery record, blocked rows drawn muted, and back arrows below the list
// counting what waits in it.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsTransfers.h"

NSString *SZPFriendsDirectory = @"friends";

static SZFriendsPersonFacts *Mei(void) {
    SZFriendsPersonFacts *mei = [[SZFriendsPersonFacts alloc] init];
    mei.conversationID = @"c_mei5";
    mei.name = @"Mei Lin";
    mei.friendsID = @"jasmine-street";
    mei.picture = [SZFriendsPicture animalWithSet:1 index:7];
    mei.routeKind = SZFriendsRouteKindOffline;
    mei.lastInteractionAt = SZPHongKong(@"2026-10-12 10:00");
    return mei;
}

static NSDictionary *Built(SZFriendsPersonFacts *person, SZFriendsItemFacts *item) {
    NSDictionary *data = [SZPBuilder(SZPAudience()) conversationForPerson:person items:@[ item ] hasEarlier:NO
                                                          highlightItemID:nil waitingElsewhere:0 now:SZPNow()];
    SZPValidateSnapshot(data, @"conversation", [NSString stringWithFormat:@"%@ %@", item.itemID, item.failureReason]);
    return [data[@"items"] lastObject];
}

static BOOL Retries(NSDictionary *item) {
    return [[item[@"actions"] valueForKey:@"action"] containsObject:@"retry_item"];
}

static SZFriendsItemFacts *FailedMessage(NSString *reason) {
    SZFriendsItemFacts *item = SZPMessage(@"m_f", YES, @"2026-09-04 10:15", @"Are you free on Thursday?",
                                          SZFriendsOutboxStateFailed);
    item.failureReason = reason;
    return item;
}

static SZFriendsItemFacts *FailedTransfer(BOOL outgoing, NSString *reason) {
    SZFriendsItemFacts *item = SZPTransfer(@"t_f", outgoing, @"2026-09-04 10:15", @"Plan.pdf", 5000000,
                                           SZFriendsTransferStateFailed);
    item.failureReason = reason;
    return item;
}

static void TestMessageFailures(void) {
    SZFriendsPersonFacts *mei = Mei();
    NSDictionary *item = Built(mei, FailedMessage(SZFriendsFailureNotDelivered30Days));
    SZPExpect([item[@"status"][@"state"] isEqual:@"failed"] &&
                  [item[@"status"][@"label"] isEqual:@"Not delivered. Stopped trying after 30 days."] &&
                  Retries(item) &&
                  [item[@"accessibility_label"]
                      isEqual:@"You, 10:15: Are you free on Thursday? Not delivered. Stopped trying after 30 days."],
              @"30 days: says it stopped, not that it is late; one period when spoken; Try again: %@", item);
    item = Built(mei, FailedMessage(SZFriendsFailureRefused));
    SZPExpect([item[@"status"][@"label"] isEqual:@"Mei couldn’t receive this"] && !Retries(item),
              @"refused: no Try again, since the answer would be the same: %@", item);
    item = Built(mei, FailedMessage(SZFriendsFailureSourceMissing));
    SZPExpect([item[@"status"][@"label"] isEqual:@"Not sent because an attachment is no longer available"] &&
                  !Retries(item),
              @"an attachment gone: %@", item);
    for (NSString *reason in @[ @"", @"a_reason_from_the_future" ]) {
        item = Built(mei, FailedMessage(reason.length ? reason : nil));
        SZPExpect([item[@"status"][@"label"] isEqual:@"Not delivered"] && Retries(item),
                  @"unknown reason %@ keeps the general words and Try again: %@", reason, item);
    }
    // A failure reason means nothing until the item has failed.
    SZFriendsItemFacts *queued = FailedMessage(SZFriendsFailureNotDelivered30Days);
    queued.outboxState = SZFriendsOutboxStateQueued;
    SZPExpect([Built(mei, queued)[@"status"][@"label"] isEqual:@"Sends when Mei is nearby"], @"queued ignores it");

    // Try again sends to the person: not to someone blocked, removed, or whose new key is still to be reviewed.
    for (NSNumber *relation in @[ @(SZFriendsPersonRelationBlocked), @(SZFriendsPersonRelationRemoved) ]) {
        SZFriendsPersonFacts *other = Mei();
        other.relation = relation.integerValue;
        SZPExpect(!Retries(Built(other, FailedMessage(SZFriendsFailureNotDelivered30Days))),
                  @"relation %@: no Try again", relation);
        SZPExpect(!Retries(Built(other, FailedTransfer(YES, nil))), @"relation %@: no Try again on a file", relation);
    }
    SZFriendsPersonFacts *changed = Mei();
    changed.keyChangePending = YES;
    SZPExpect(!Retries(Built(changed, FailedMessage(nil))), @"a key change to review: no Try again");

    // An outgoing message the store has no delivery record for (-1) claims nothing at all.
    SZFriendsItemFacts *unknown = SZPMessage(@"m_u", YES, @"2026-10-12 09:00", @"Hello", -1);
    item = Built(mei, unknown);
    SZPExpect(item[@"status"] == [NSNull null] && [item[@"actions"] count] == 0 &&
                  [item[@"accessibility_label"] isEqual:@"You, 09:00: Hello"],
              @"no delivery record, no status: %@", item);
}

static void TestTransferFailures(void) {
    SZFriendsPersonFacts *mei = Mei();
    NSDictionary *expected = @{
        SZFriendsFailureNotDelivered30Days : @[ @"Not delivered. Stopped trying after 30 days.", @YES ],
        SZFriendsFailureRefused : @[ @"Mei couldn’t receive this file", @NO ],
        SZFriendsFailureSourceMissing : @[ @"Not sent because this version of the file is no longer available", @NO ],
        SZFriendsFailureDigestMismatch : @[ @"Arrived damaged for Mei, so it wasn’t saved", @YES ],
    };
    for (NSString *reason in expected) {
        NSDictionary *item = Built(mei, FailedTransfer(YES, reason));
        BOOL retries = [expected[reason][1] boolValue];
        SZPExpect([item[@"status_label"] isEqual:expected[reason][0]] && Retries(item) == retries,
                  @"outgoing %@: %@ %@", reason, item[@"status_label"], item[@"actions"]);
        NSString *status = expected[reason][0];
        if ([status hasSuffix:@"."]) status = [status substringToIndex:status.length - 1];
        NSString *spoken = [NSString stringWithFormat:@"You tried to send Plan.pdf, PDF, 5 MB. %@.", status];
        SZPExpect([item[@"accessibility_label"] isEqual:spoken], @"outgoing %@ spoken: %@", reason,
                  item[@"accessibility_label"]);
    }
    NSDictionary *item = Built(mei, FailedTransfer(NO, SZFriendsFailureDigestMismatch));
    SZPExpect([item[@"status_label"] isEqual:@"Arrived damaged, so it wasn’t saved"] && Retries(item) &&
                  [item[@"accessibility_label"]
                      isEqual:@"Mei Lin sent Plan.pdf, PDF, 5 MB. It arrived damaged, so it wasn’t saved"],
              @"incoming damaged file can be fetched again: %@", item);
    item = Built(mei, FailedTransfer(NO, nil));
    SZPExpect([item[@"status_label"] isEqual:@"Didn’t arrive"] && !Retries(item),
              @"any other incoming failure: the sender offers it again: %@", item);
}

// Every failure key the store declares (its headers mark each with the stored value in a comment) has words here,
// so a key added to the store without words fails this test instead of showing the general line forever.
static void TestStoreKeysHaveWords(void) {
    NSSet *known = [NSSet setWithArray:@[ SZFriendsFailureNotDelivered30Days, SZFriendsFailureRefused,
                                          SZFriendsFailureSourceMissing, SZFriendsFailureDigestMismatch ]];
    NSRegularExpression *declaration = [NSRegularExpression
        regularExpressionWithPattern:@"^extern NSString \\*const SZFriends(Outbox|Transfer)Failure\\w+;"
                                     @"\\s*// \"(\\w+)\""
                             options:NSRegularExpressionAnchorsMatchLines
                               error:NULL];
    NSMutableSet *declared = [NSMutableSet set];
    for (NSString *header in @[ @"SZFriendsOutbox.h", @"SZFriendsTransfers.h" ]) {
        NSString *path = [SZPFriendsDirectory stringByAppendingPathComponent:
                                                  [@"service/store" stringByAppendingPathComponent:header]];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        SZPExpect(text.length > 0, @"cannot read %@", path);
        for (NSTextCheckingResult *match in [declaration matchesInString:text ?: @"" options:0
                                                                   range:NSMakeRange(0, text.length)])
            [declared addObject:[text substringWithRange:[match rangeAtIndex:2]]];
    }
    SZPExpect([declared isEqualToSet:known], @"the store declares %@, the presentation knows %@", declared, known);
    NSDictionary<NSString *, NSString *> *catalog = SZFriendsEnglishCatalog();
    for (NSString *key in declared) {
        BOOL words = catalog[[@"message.status.failed." stringByAppendingString:key]] ||
                     catalog[[@"transfer.status.failed.out." stringByAppendingString:key]] ||
                     catalog[[@"transfer.status.failed.in." stringByAppendingString:key]];
        SZPExpect(words, @"no words for the store’s failure key %@", key);
    }
}

static void TestRowsAndBackArrows(void) {
    NSDictionary *people = SZPPeople();
    NSDictionary *list = [SZPBuilder(SZPAudience()) listWithPeople:people.allValues previewItems:SZPPreviewItems()
                                                           profile:SZPProfileRaph() query:@"" now:SZPNow()];
    for (NSDictionary *row in list[@"rows"]) {
        NSString *style = [row[@"blocked"] boolValue] ? @"muted" : @"normal";
        SZPExpect([row[@"style"] isEqual:style], @"%@ is drawn %@", row[@"conversation_id"], row[@"style"]);
    }
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSDictionary *back = [builder detailsForPerson:people[@"c_mei"] waitingElsewhere:1 now:SZPNow()][@"back"];
    SZPExpect([back[@"badge_label"] isEqual:@"1"] &&
                  [back[@"accessibility_label"]
                      isEqual:@"Back to the conversation with Mei, 1 waiting for you in Friends"],
              @"details says where the waiting row is: %@", back);
    back = [builder profileWithFacts:SZPProfileRaph() waitingElsewhere:3][@"back"];
    SZPExpect([back[@"badge_count"] isEqual:@3] && [back[@"accessibility_label"] isEqual:@"Back to Friends, 3 waiting"],
              @"profile counts like the list: %@", back);
}

// Remove and block withdraw everything still waiting to go, and the store records that as refused. The person ended
// the friendship themselves, so the words say that, never that the other Mac turned anything down.
static void TestWithdrawnByRemoveOrBlock(void) {
    NSDictionary *expected = @{
        @(SZFriendsPersonRelationRemoved) : @"Not sent because you removed Mei",
        @(SZFriendsPersonRelationBlocked) : @"Not sent because you blocked Mei",
    };
    for (NSNumber *relation in expected) {
        SZFriendsPersonFacts *mei = Mei();
        mei.relation = relation.integerValue;
        NSDictionary *message = Built(mei, FailedMessage(SZFriendsFailureRefused));
        NSDictionary *file = Built(mei, FailedTransfer(YES, SZFriendsFailureRefused));
        SZPExpect([message[@"status"][@"label"] isEqual:expected[relation]] && !Retries(message),
                  @"message to someone you %@: %@", relation, message[@"status"]);
        SZPExpect([file[@"status_label"] isEqual:expected[relation]] && !Retries(file) &&
                      [file[@"accessibility_label"] hasSuffix:[expected[relation] stringByAppendingString:@"."]],
                  @"file to someone you %@: %@ / %@", relation, file[@"status_label"], file[@"accessibility_label"]);
        SZPExpect(![message[@"status"][@"label"] containsString:@"couldn’t accept"], @"never blames their Mac");
    }
}

void SZPRunFailureTests(void) {
    TestMessageFailures();
    TestWithdrawnByRemoveOrBlock();
    TestTransferFailures();
    TestStoreKeysHaveWords();
    TestRowsAndBackArrows();
}
