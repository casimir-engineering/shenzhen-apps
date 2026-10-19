// friends-e2e-devices-check: the steps the scenarios share (SZFriendsE2EDevices.h).

#import "SZFriendsE2EDevices.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSyncInternal.h"

@implementation SZFE2EComputer
@end

NSString *SZFE2ERandomToken(void) {
    return [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
}

static BOOL SZFE2ESubscribeViews(SZFE2EComputer *computer) {
    computer.list = [computer.client subscribe:@"list" params:nil];
    computer.profile = [computer.client subscribe:@"profile" params:nil];
    CHECK(computer.list != nil && computer.profile != nil, "%@ subscribes to its list and profile",
          computer.helper.name);
    return YES;
}

SZFE2EComputer *SZFE2EStartComputer(SZFE2EWorld *world, NSString *name, NSString *displayName, NSDictionary *env,
                                    BOOL join) {
    SZFE2EComputer *computer = [SZFE2EComputer new];
    computer.helper = [world helperNamed:name];
    computer.helper.extraEnvironment = env ?: @{};
    computer.displayName = displayName;
    if (![computer.helper start]) {
        SZFE2EFail(__FILE__, __LINE__, "the helper starts", name);
        return nil;
    }
    computer.client = [SZFE2EClient clientForHelper:computer.helper];
    if (computer.client == nil || ![computer.client.welcome[@"capabilities"] containsObject:@"devices"]) {
        SZFE2EFail(__FILE__, __LINE__, "a client reaches READY on a helper with devices",
                   [computer.client.welcome description] ?: name);
        return nil;
    }
    if (![[computer.client intent:@"activate" fields:nil][@"ok"] boolValue]) {
        SZFE2EFail(__FILE__, __LINE__, "activate", name);
        return nil;
    }
    if (!join && ![[computer.client intent:@"set_name" fields:@{@"name" : displayName}][@"ok"] boolValue]) {
        SZFE2EFail(__FILE__, __LINE__, "set_name", displayName);
        return nil;
    }
    return SZFE2ESubscribeViews(computer) ? computer : nil;
}

BOOL SZFE2ERestartComputer(SZFE2EComputer *computer) {
    CHECK([computer.helper start], "%@ starts again", computer.helper.name);
    computer.client = [SZFE2EClient clientForHelper:computer.helper];
    CHECK(computer.client != nil, "%@'s client reaches READY again", computer.helper.name);
    CHECK([[computer.client intent:@"activate" fields:nil][@"ok"] boolValue], "activate again");
    return SZFE2ESubscribeViews(computer);
}

BOOL SZFE2EStopComputer(SZFE2EComputer *computer) {
    [computer.client close];
    computer.client = nil;
    CHECK([computer.helper terminate], "%@ stops", computer.helper.name);
    return YES;
}

BOOL SZFE2EMoveComputer(SZFE2EComputer *computer, NSString *serviceType) {
    if (!SZFE2EStopComputer(computer)) return NO;
    NSMutableDictionary *env = [computer.helper.extraEnvironment mutableCopy];
    env[@"SZFRIENDS_TEST_SERVICE_TYPE"] = serviceType;
    computer.helper.extraEnvironment = env;
    return SZFE2ERestartComputer(computer);
}

NSString *SZFE2EPartitionType(void) {
    return [NSString stringWithFormat:@"_szfp%08x._tcp", arc4random()];
}

NSString *SZFE2EFriendsID(SZFE2EComputer *computer) {
    id value = [computer.client dataFor:computer.profile][@"id"][@"friends_id"];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSArray<NSDictionary *> *SZFE2EComputerRows(SZFE2EComputer *computer) {
    id rows = [computer.client dataFor:computer.profile][@"devices"][@"rows"];
    return [rows isKindOfClass:NSArray.class] ? rows : @[];
}

NSString *SZFE2EThisDeviceID(SZFE2EComputer *computer) {
    for (NSDictionary *row in SZFE2EComputerRows(computer)) {
        if ([row[@"this_computer"] isEqual:@YES]) return row[@"device_id"];
    }
    return nil;
}

static NSDictionary *SZFE2EJoinRow(SZFE2EComputer *computer, NSString *state) {
    for (NSDictionary *row in [computer.client dataFor:computer.list][@"join_requests"]) {
        if ([row[@"state"] isEqual:state]) return row;
    }
    return nil;
}

BOOL SZFE2EJoin(SZFE2EComputer *existing, SZFE2EComputer *newcomer, NSTimeInterval timeout) {
    return SZFE2EJoinWatched(existing, newcomer, @[], timeout);
}

BOOL SZFE2EJoinWatched(SZFE2EComputer *existing, SZFE2EComputer *newcomer, NSArray<SZFE2EComputer *> *others,
                       NSTimeInterval timeout) {
    SZFE2EClient *old = existing.client, *fresh = newcomer.client;
    NSString *friendsID = SZFE2EFriendsID(existing);
    CHECK(friendsID.length > 0, "the profile has an ID: %@", [old dataFor:existing.profile][@"id"]);
    CHECK([[fresh dataFor:newcomer.list][@"name_prompt"][@"join_label"] isKindOfClass:NSString.class],
          "a fresh computer offers joining: %@", [fresh dataFor:newcomer.list][@"name_prompt"]);
    NSString *join = [fresh subscribe:@"join" params:nil];
    CHECK([[fresh dataFor:join][@"state"] isEqual:@"idle"], "the join view starts idle: %@", [fresh dataFor:join]);
    NSDictionary *reply = [fresh intent:@"join_profile" fields:@{@"friends_id" : friendsID}];
    CHECK([reply[@"ok"] boolValue], "join_profile: %@", reply);
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL { return SZFE2EJoinRow(existing, @"waiting") != nil; }),
          "the request shows on %@: %@", existing.helper.name, [old dataFor:existing.list][@"join_requests"]);
    NSDictionary *row = SZFE2EJoinRow(existing, @"waiting");
    CHECK([[old dataFor:existing.list][@"join_requests"] count] == 1, "one row for one computer");
    for (SZFE2EComputer *other in others) {
        CHECK(SZFE2EWaitUntil(timeout, ^BOOL { return SZFE2EJoinRow(other, @"waiting") != nil; }),
              "the request shows on %@ too: %@", other.helper.name,
              [other.client dataFor:other.list][@"join_requests"]);
    }
    reply = [old intent:@"approve_join" fields:@{@"join_id" : row[@"join_id"]}];
    CHECK([reply[@"ok"] boolValue], "approve_join: %@", reply);
    CHECK(SZFE2EWaitUntil(5, ^BOOL { return [SZFE2EJoinRow(existing, @"approved")[@"code"] length] > 0; }),
          "the code shows: %@", [old dataFor:existing.list][@"join_requests"]);
    NSString *code = SZFE2EJoinRow(existing, @"approved")[@"code"];
    reply = [fresh intent:@"enter_join_code" fields:@{@"code" : code}];
    CHECK([reply[@"ok"] boolValue], "enter_join_code: %@", reply);
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL { return [[fresh dataFor:join][@"state"] isEqual:@"joined"]; }),
          "joined: %@", [fresh dataFor:join]);
    [fresh intent:@"unsubscribe" fields:@{@"subscription" : join}];
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
              return [SZFE2EFriendsID(newcomer) isEqual:friendsID] &&
                     [[fresh dataFor:newcomer.profile][@"name"][@"value"] isEqual:existing.displayName] &&
                     [[old dataFor:existing.list][@"join_requests"] count] == 0;
          }),
          "the new computer holds the profile's ID and name, and the row is gone: %@ / %@",
          [fresh dataFor:newcomer.profile][@"id"], [old dataFor:existing.list][@"join_requests"]);
    // The computers that did not approve drop the row once the profile's computers include the new one.
    for (SZFE2EComputer *other in others) {
        CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
                  return [[other.client dataFor:other.list][@"join_requests"] count] == 0;
              }),
              "the row clears on %@: %@", other.helper.name, [other.client dataFor:other.list][@"join_requests"]);
    }
    newcomer.displayName = existing.displayName;
    return YES;
}

BOOL SZFE2EComputersListed(NSArray<SZFE2EComputer *> *computers, NSArray<NSString *> *names, NSTimeInterval timeout) {
    __block SZFE2EComputer *wrong = nil;
    BOOL listed = SZFE2EWaitUntil(timeout, ^BOOL {
        for (SZFE2EComputer *computer in computers) {
            NSArray<NSDictionary *> *rows = SZFE2EComputerRows(computer);
            NSArray *listedNames = [rows valueForKey:@"name"];
            if (rows.count != names.count || ![rows[0][@"this_computer"] isEqual:@YES] ||
                ![[NSSet setWithArray:listedNames] isEqualToSet:[NSSet setWithArray:names]]) {
                wrong = computer;
                return NO;
            }
        }
        return YES;
    });
    CHECK(listed, "%@ lists %@: %@", wrong.helper.name, names, wrong ? SZFE2EComputerRows(wrong) : @[]);
    return YES;
}

BOOL SZFE2EShowsTexts(SZFE2EComputer *computer, NSString *subscription, NSArray<NSString *> *texts,
                      NSTimeInterval timeout) {
    NSSet *wanted = [NSSet setWithArray:texts];
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
              NSArray *shown = SZFE2ETexts(computer.client, subscription);
              return shown.count == texts.count && [[NSSet setWithArray:shown] isEqualToSet:wanted];
          }),
          "%@ shows %@: %@", computer.helper.name, texts, SZFE2ETexts(computer.client, subscription));
    return YES;
}

static BOOL SZFE2ERename(SZFE2EComputer *computer, NSString *name) {
    NSDictionary *reply = [computer.client intent:@"rename_device" fields:@{@"name" : name}];
    CHECK([reply[@"ok"] boolValue], "rename %@: %@", name, reply);
    return YES;
}

BOOL SZFE2EStartProfile(SZFE2EWorld *world, SZFE2EComputer **studio, SZFE2EComputer **laptop, SZFE2EComputer **ben,
                        NSString **benAtStudio, NSString **benAtLaptop, NSString **anaAtBen) {
    *studio = SZFE2EStartComputer(world, @"studio", @"Ana", nil, NO);
    *ben = SZFE2EStartComputer(world, @"ben", @"Ben", nil, NO);
    CHECK(*studio != nil && *ben != nil);
    if (!SZFE2EBefriendNearby(*studio, *ben, benAtStudio, anaAtBen)) return NO;
    *laptop = SZFE2EStartComputer(world, @"laptop", @"Ana", nil, YES);
    CHECK(*laptop != nil);
    if (!SZFE2EJoin(*studio, *laptop, 25)) return NO;
    if (!SZFE2ERename(*studio, @"Studio Mac") || !SZFE2ERename(*laptop, @"Travel Laptop")) return NO;
    if (!SZFE2EComputersListed(@[ *studio, *laptop ], @[ @"Studio Mac", @"Travel Laptop" ], 15)) return NO;
    SZFE2EComputer *joined = *laptop;
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return SZFE2EListRow(joined, @"Ben") != nil; }), "Ben reaches the laptop: %@",
          [joined.client dataFor:joined.list][@"rows"]);
    *benAtLaptop = SZFE2EListRow(joined, @"Ben")[@"conversation_id"];
    return YES;
}

NSDictionary *SZFE2EListRow(SZFE2EComputer *computer, NSString *title) {
    for (NSDictionary *row in [computer.client dataFor:computer.list][@"rows"]) {
        if ([row[@"title"] isEqual:title]) return row;
    }
    return nil;
}

BOOL SZFE2EBefriendNearby(SZFE2EComputer *asker, SZFE2EComputer *visible, NSString **visibleAtAsker,
                          NSString **askerAtVisible) {
    SZFE2EClient *a = asker.client, *b = visible.client;
    CHECK([[b intent:@"start_visibility" fields:nil][@"ok"] boolValue], "%@ is visible", visible.displayName);
    NSString *nearby = [a subscribe:@"nearby" params:nil];
    __block NSString *nearbyID = nil;
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              for (NSDictionary *person in [a dataFor:nearby][@"people"]) {
                  if ([person[@"title"] isEqual:visible.displayName] &&
                      [person[@"nearby_id"] isKindOfClass:NSString.class]) {
                      nearbyID = person[@"nearby_id"];
                  }
              }
              return nearbyID != nil;
          }),
          "%@ shows in Nearby: %@", visible.displayName, [a dataFor:nearby]);
    CHECK([[a intent:@"send_request" fields:@{@"nearby_id" : nearbyID}][@"ok"] boolValue], "send_request");
    [a intent:@"unsubscribe" fields:@{@"subscription" : nearby}];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              return [SZFE2EListRow(visible, asker.displayName)[@"waiting"] isKindOfClass:NSDictionary.class];
          }),
          "the request arrives: %@", [b dataFor:visible.list]);
    *askerAtVisible = SZFE2EListRow(visible, asker.displayName)[@"conversation_id"];
    *visibleAtAsker = SZFE2EListRow(asker, visible.displayName)[@"conversation_id"];
    CHECK(*askerAtVisible != nil && *visibleAtAsker != nil, "both rows");
    CHECK([[b intent:@"accept_request" fields:@{@"conversation_id" : *askerAtVisible}][@"ok"] boolValue], "accept");
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return [SZFE2EListRow(asker, visible.displayName)[@"drop_label"] isKindOfClass:NSString.class] &&
                     [SZFE2EListRow(visible, asker.displayName)[@"drop_label"] isKindOfClass:NSString.class];
          }),
          "friends on both sides: %@", [a dataFor:asker.list]);
    CHECK([[b intent:@"stop_visibility" fields:nil][@"ok"] boolValue], "hidden again");
    return YES;
}

NSArray<NSDictionary *> *SZFE2EKindItems(NSDictionary *conversation, NSString *kind) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *item in conversation[@"items"]) {
        if ([item[@"kind"] isEqual:kind]) [items addObject:item];
    }
    return items;
}

NSArray<NSString *> *SZFE2ETexts(SZFE2EClient *client, NSString *subscription) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *item in SZFE2EKindItems([client dataFor:subscription], @"message")) {
        if ([item[@"text"] isKindOfClass:NSString.class]) [texts addObject:item[@"text"]];
    }
    return texts;
}

BOOL SZFE2ESay(SZFE2EComputer *computer, NSString *conversationID, NSString *text) {
    NSDictionary *reply = [computer.client intent:@"send_message" fields:@{@"conversation_id" : conversationID,
                                                                           @"text" : text,
                                                                           @"client_token" : SZFE2ERandomToken()}];
    CHECK([reply[@"ok"] boolValue], "%@ sends %@: %@", computer.helper.name, text, reply);
    return YES;
}

#pragma mark - Stores

static NSString *SZFE2EHex(NSData *data) {
    if (data.length == 0) return @"-";
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", ((const uint8_t *)data.bytes)[i]];
    return hex;
}

static SZFriendsStore *SZFE2EOpenStore(SZFE2EHelper *helper) {
    NSError *error = nil;
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:helper.stateDirectory error:&error];
    if (store == nil) SZFE2EFail(__FILE__, __LINE__, "the store opens", error.description ?: helper.name);
    return store;
}

NSString *SZFE2EStoreDump(SZFE2EHelper *helper) {
    SZFriendsStore *store = SZFE2EOpenStore(helper);
    if (store == nil) return nil;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    SZFriendsPicture *own = store.profilePicture;
    [lines addObject:[NSString stringWithFormat:@"profile %@ %@ pic %ld/%ld/%ld presence %@ devices %@",
                                                store.profileName ?: @"-", store.friendsID ?: @"-", (long)own.kind,
                                                (long)own.animalSet, (long)own.animalIndex,
                                                SZFE2EHex(store.ownPresenceSecret),
                                                SZFE2EHex([SZFriendsSyncEngine ownDevicesSecretInStore:store
                                                                                              creating:NO])]];
    NSMutableDictionary<NSString *, NSString *> *refs = [NSMutableDictionary dictionary];
    for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
        NSString *ref = SZFriendsSyncRefForPerson(person);
        refs[person.conversationID] = ref;
        [lines addObject:[NSString stringWithFormat:@"person %@ rel %ld name %@ id %@ static %@ presence %@ "
                                                    @"verified %d auto %d unread %ld",
                                                    ref, (long)person.relation, person.name ?: @"-",
                                                    person.friendsID ?: @"-", SZFE2EHex(person.staticKey),
                                                    SZFE2EHex(person.presenceSecret), person.verified,
                                                    person.autoAccept, (long)person.unreadCount]];
        for (SZFriendsItemRecord *item in [store itemsInConversation:person.conversationID beforeItemID:nil
                                                                limit:100000 hasEarlier:NULL]) {
            [lines addObject:[NSString stringWithFormat:@"item %@ %@ kind %ld dir %ld sent %.6f recv %.6f %@ %@",
                                                        ref, item.itemID, (long)item.kind, (long)item.direction,
                                                        item.sentAt.timeIntervalSince1970,
                                                        item.receivedAt.timeIntervalSince1970, item.text ?: @"-",
                                                        item.transferID ?: @"-"]];
        }
    }
    for (SZFriendsOutboxEntry *entry in [store syncableOutboxEntries]) {
        [lines addObject:[NSString stringWithFormat:@"outbox %@ %@ kind %ld state %ld item %@", entry.entryID,
                                                    refs[entry.conversationID] ?: @"?", (long)entry.kind,
                                                    (long)SZFriendsSyncOutboxFoldedState(entry.state),
                                                    entry.itemID ?: @"-"]];
    }
    for (SZFriendsSyncFileRecord *file in [store syncFiles]) {
        [lines addObject:[NSString stringWithFormat:@"file %@ %@ state %ld %@ %llu holders %lu", file.transferID,
                                                    refs[file.conversationID] ?: @"?", (long)file.state,
                                                    file.fileName, file.size, (unsigned long)file.holders.count]];
    }
    [store close];
    [lines sortUsingSelector:@selector(compare:)];
    return [lines componentsJoinedByString:@"\n"];
}

NSString *SZFE2EStorePresenceSecret(SZFE2EHelper *helper) {
    SZFriendsStore *store = SZFE2EOpenStore(helper);
    NSString *secret = store.ownPresenceSecret.length > 0 ? SZFE2EHex(store.ownPresenceSecret) : nil;
    [store close];
    return secret;
}

NSString *SZFE2EStoreFriendPresenceSecret(SZFE2EHelper *helper, NSString *name) {
    SZFriendsStore *store = SZFE2EOpenStore(helper);
    NSString *secret = nil;
    for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
        if ([person.name isEqual:name] && person.presenceSecret.length > 0) secret = SZFE2EHex(person.presenceSecret);
    }
    [store close];
    return secret;
}

NSString *SZFE2EStoreFriendComputers(SZFE2EHelper *helper, NSString *name) {
    SZFriendsStore *store = SZFE2EOpenStore(helper);
    NSString *standing = nil;
    for (SZFriendsPersonRecord *person in [store peopleByLatestInteraction]) {
        if (![person.name isEqual:name] || person.identityKey == nil) continue;
        NSUInteger authorized = 0, revoked = 0;
        for (SZFriendsDeviceRecord *device in [store devicesOfRootKey:person.identityKey]) {
            authorized += device.state == SZFriendsChainDeviceAuthorized;
            revoked += device.state == SZFriendsChainDeviceRevoked;
        }
        standing = [NSString stringWithFormat:@"authorized %lu revoked %lu", (unsigned long)authorized,
                                              (unsigned long)revoked];
    }
    [store close];
    return standing;
}
