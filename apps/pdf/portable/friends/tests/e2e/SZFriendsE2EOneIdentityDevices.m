// friends-one-identity-check, two computers of one person (SZFriendsE2EOneIdentity.h): what one computer changes,
// the other shows, both ways, nearby and online, and after one of them was away.

#import "SZFriendsE2EOneIdentity.h"

#import "SZFriendsE2EOnline.h"

#import "service/online/SZFriendsOnlineTransport.h"

// Ana's two computers and her friends, as the scenarios leave them.
@interface SZFOProfile : NSObject
@property(nonatomic) SZFE2EComputer *studio, *laptop, *ben, *cara;
@property(nonatomic, nullable) SZFE2EOnlineHost *host;
@end

@implementation SZFOProfile
@end

static BOOL SZFORename(SZFE2EComputer *computer, NSString *name) {
    NSDictionary *reply = [computer.client intent:@"rename_device" fields:@{@"name" : name}];
    CHECK([reply[@"ok"] boolValue], "rename %@: %@", name, reply);
    return YES;
}

static NSString *SZFOProfileName(SZFE2EComputer *computer) {
    id name = [computer.client dataFor:computer.profile][@"name"][@"value"];
    return [name isKindOfClass:NSString.class] ? name : nil;
}

static NSString *SZFOConversation(SZFE2EComputer *computer, NSString *title) {
    return SZFE2EListRow(computer, title)[@"conversation_id"];
}

// `title`'s chat on `computer` shows `text` (or, with `shown` NO, no longer does) within `timeout`. It opens the chat,
// which reads it, as looking at it in an app does.
static BOOL SZFOChatShows(SZFE2EComputer *computer, NSString *title, NSString *text, BOOL shown,
                          NSTimeInterval timeout) {
    __block NSString *subscription = nil, *conversation = nil;
    BOOL ok = SZFE2EWaitUntil(timeout, ^BOOL {
        NSString *now = [title isEqual:@"You"] ? @"you" : SZFOConversation(computer, title);
        if (now == nil) return !shown;
        if (![now isEqual:conversation]) {
            if (subscription) [computer.client intent:@"unsubscribe" fields:@{@"subscription" : subscription}];
            conversation = now;
            subscription = [computer.client openConversation:now];
        }
        return subscription != nil && [SZFE2ETexts(computer.client, subscription) containsObject:text] == shown;
    });
    NSArray *texts = subscription ? SZFE2ETexts(computer.client, subscription) : @[];
    if (subscription) [computer.client intent:@"unsubscribe" fields:@{@"subscription" : subscription}];
    CHECK(ok, "%@: %@'s chat %@ \"%@\": %@", computer.helper.name, title, shown ? @"shows" : @"no longer shows", text,
          texts);
    return YES;
}

static BOOL SZFOIsFriend(SZFE2EComputer *computer, NSString *title, BOOL friend, NSTimeInterval timeout) {
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
              NSDictionary *row = SZFE2EListRow(computer, title);
              BOOL isFriend = [row[@"drop_label"] isKindOfClass:NSString.class];
              return isFriend == friend;
          }),
          "%@ %@ %@ as a friend: %@", computer.helper.name, friend ? @"lists" : @"no longer lists", title,
          SZFE2EListRow(computer, title));
    return YES;
}

static BOOL SZFONamed(NSArray<SZFE2EComputer *> *computers, NSString *name, NSTimeInterval timeout) {
    for (SZFE2EComputer *computer in computers) {
        CHECK(SZFE2EWaitUntil(timeout, ^BOOL { return [SZFOProfileName(computer) isEqual:name]; }),
              "%@ is named %@: %@", computer.helper.name, name, SZFOProfileName(computer));
    }
    return YES;
}

static BOOL SZFOUnread(SZFE2EComputer *computer, NSString *title, BOOL unread, NSTimeInterval timeout) {
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
              NSDictionary *row = SZFE2EListRow(computer, title);
              return row != nil && [row[@"unread"] boolValue] == unread;
          }),
          "%@: %@ %@: %@", computer.helper.name, title, unread ? @"unread" : @"read", SZFE2EListRow(computer, title));
    return YES;
}

// Both computers stopped, their stores hold the same history, friends, name and settings (SZFE2EStoreDump).
static BOOL SZFOSameStores(SZFOProfile *profile) {
    if (!SZFE2EStopComputer(profile.studio) || !SZFE2EStopComputer(profile.laptop)) return NO;
    NSString *studio = SZFE2EStoreDump(profile.studio.helper), *laptop = SZFE2EStoreDump(profile.laptop.helper);
    CHECK(studio != nil && [studio isEqual:laptop], "the two stores are one:\n%@\n--- laptop\n%@", studio, laptop);
    return YES;
}

// Ana on the studio with Ben as a friend, the laptop joined with the code; Cara a stranger for now. Online, the
// studio and the laptop browse Bonjour types of their own, so they meet only through the host; Ben and Cara are
// nearby: Ben to the studio, Cara to the laptop.
static SZFOProfile *SZFOStart(SZFE2EWorld *world, BOOL online, BOOL relay, BOOL *skipped) {
    SZFOProfile *profile = [SZFOProfile new];
    if (skipped) *skipped = NO;
    NSDictionary *studioEnv = nil, *laptopEnv = nil;
    NSString *serviceType = world.serviceType;
    if (online) {
        NSString *why = nil;
        profile.host = [SZFE2EOnlineHost startInWorld:world relay:relay skip:&why];
        if (profile.host == nil) {
            if (why != nil) printf("skip two computers online: %s\n", why.UTF8String);
            if (skipped) *skipped = why != nil;
            return nil;
        }
        studioEnv = [profile.host environmentForHelper:@"studio"];
        laptopEnv = [profile.host environmentForHelper:@"laptop"];
    }
    // Every helper here dials from 127.0.0.1, and a listener admits at most 3 XX handshakes a minute from one address
    // (SZFriendsNearbyLimits.m): Ben is befriended before the others start looking around.
    profile.studio = SZFE2EStartComputer(world, @"studio", @"Ana", studioEnv, NO);
    // Ben meets the studio, Cara the laptop.
    NSDictionary *benEnv = online ? @{@"SZFRIENDS_TEST_SERVICE_TYPE" : studioEnv[@"SZFRIENDS_TEST_SERVICE_TYPE"]} : nil;
    NSDictionary *caraEnv = online ? @{@"SZFRIENDS_TEST_SERVICE_TYPE" : laptopEnv[@"SZFRIENDS_TEST_SERVICE_TYPE"]}
                                   : nil;
    (void)serviceType;
    profile.ben = SZFE2EStartComputer(world, @"ben", @"Ben", benEnv, NO);
    if (!profile.studio || !profile.ben) return nil;
    NSString *benAtStudio = nil, *anaAtBen = nil;
    if (!SZFE2EBefriendNearby(profile.studio, profile.ben, &benAtStudio, &anaAtBen)) return nil;
    profile.laptop = SZFE2EStartComputer(world, @"laptop", @"Ana", laptopEnv, YES);
    profile.cara = SZFE2EStartComputer(world, @"cara", @"Cara", caraEnv, NO);
    if (!profile.laptop || !profile.cara) return nil;
    if (relay) {
        // From here on only the relay connects the two computers: no direct candidate, no TCP path.
        for (SZFE2EComputer *computer in @[ profile.studio, profile.laptop ])
            [[NSData data] writeToFile:SZFE2EOnlineBlockPath(computer.helper) atomically:YES];
    }
    if (!SZFE2EJoin(profile.studio, profile.laptop, 30)) return nil;
    if (!SZFORename(profile.studio, @"Studio Mac") || !SZFORename(profile.laptop, @"Travel Laptop")) return nil;
    if (!SZFE2EComputersListed(@[ profile.studio, profile.laptop ], @[ @"Studio Mac", @"Travel Laptop" ], 20))
        return nil;
    return profile;
}

// Everything the person does on one computer, seen on the other, both ways.
static BOOL SZFOBothWays(SZFOProfile *profile, NSTimeInterval wait) {
    SZFE2EComputer *studio = profile.studio, *laptop = profile.laptop;
    // Friends: Ben, befriended on the studio, is the laptop's friend too; Cara, befriended on the laptop, the studio's.
    if (!SZFOIsFriend(laptop, @"Ben", YES, wait)) return NO;
    NSString *caraAtLaptop = nil, *anaAtCara = nil;
    if (!SZFE2EBefriendNearby(laptop, profile.cara, &caraAtLaptop, &anaAtCara)) return NO;
    if (!SZFOIsFriend(studio, @"Cara", YES, wait)) return NO;

    // Chats, both ways, and a friend's message reaches both computers.
    CHECK(SZFE2ESay(studio, SZFOConversation(studio, @"Ben"), @"From the studio to Ben") &&
          SZFE2ESay(laptop, SZFOConversation(laptop, @"Ben"), @"From the laptop to Ben"));
    NSString *anaAtBen = SZFOConversation(profile.ben, @"Ana");
    NSString *atBen = [profile.ben.client openConversation:anaAtBen];
    CHECK(SZFE2EWaitUntil(wait, ^BOOL {
              NSArray *texts = SZFE2ETexts(profile.ben.client, atBen);
              return [texts containsObject:@"From the studio to Ben"] &&
                     [texts containsObject:@"From the laptop to Ben"];
          }),
          "Ben has both: %@", SZFE2ETexts(profile.ben.client, atBen));
    CHECK(SZFE2ESay(profile.ben, anaAtBen, @"Ben to Ana, wherever she is"));
    CHECK(SZFE2ESay(profile.cara, anaAtCara, @"Cara to Ana, wherever she is"));
    // Unread on both computers until it is read on one: then read on both (nothing has opened Cara's chat yet).
    if (!SZFOUnread(studio, @"Cara", YES, wait) || !SZFOUnread(laptop, @"Cara", YES, wait)) return NO;
    NSString *caraOpen = [laptop.client openConversation:SZFOConversation(laptop, @"Cara")];
    CHECK(caraOpen != nil);
    if (!SZFOUnread(laptop, @"Cara", NO, 5) || !SZFOUnread(studio, @"Cara", NO, wait)) return NO;
    [laptop.client intent:@"unsubscribe" fields:@{@"subscription" : caraOpen}];
    for (SZFE2EComputer *computer in @[ studio, laptop ]) {
        if (!SZFOChatShows(computer, @"Ben", @"From the studio to Ben", YES, wait) ||
            !SZFOChatShows(computer, @"Ben", @"From the laptop to Ben", YES, wait) ||
            !SZFOChatShows(computer, @"Ben", @"Ben to Ana, wherever she is", YES, wait) ||
            !SZFOChatShows(computer, @"Cara", @"Cara to Ana, wherever she is", YES, wait))
            return NO;
    }

    // The name, both ways.
    CHECK([[laptop.client intent:@"set_name" fields:@{@"name" : @"Ana Lee"}][@"ok"] boolValue]);
    if (!SZFONamed(@[ laptop, studio ], @"Ana Lee", wait)) return NO;
    CHECK([[studio.client intent:@"set_name" fields:@{@"name" : @"Ana L."}][@"ok"] boolValue]);
    if (!SZFONamed(@[ studio, laptop ], @"Ana L.", wait)) return NO;

    // You, both ways.
    CHECK(SZFE2ESay(studio, @"you", @"Studio note: order the brackets") &&
          SZFE2ESay(laptop, @"you", @"Laptop note: bring the samples"));
    for (SZFE2EComputer *computer in @[ studio, laptop ]) {
        if (!SZFOChatShows(computer, @"You", @"Studio note: order the brackets", YES, wait) ||
            !SZFOChatShows(computer, @"You", @"Laptop note: bring the samples", YES, wait))
            return NO;
    }

    // Deletions, both ways: Cara's chat deleted on the laptop, Ben's on the studio; then Cara removed on the studio.
    CHECK([[laptop.client intent:@"delete_history" fields:@{@"conversation_id" : SZFOConversation(laptop, @"Cara")}]
              [@"ok"] boolValue]);
    if (!SZFOChatShows(studio, @"Cara", @"Cara to Ana, wherever she is", NO, wait)) return NO;
    CHECK([[studio.client intent:@"delete_history" fields:@{@"conversation_id" : SZFOConversation(studio, @"Ben")}]
              [@"ok"] boolValue]);
    if (!SZFOChatShows(laptop, @"Ben", @"Ben to Ana, wherever she is", NO, wait) ||
        !SZFOChatShows(laptop, @"Ben", @"From the laptop to Ben", NO, wait))
        return NO;
    CHECK([[studio.client intent:@"remove_friend" fields:@{@"conversation_id" : SZFOConversation(studio, @"Cara")}]
              [@"ok"] boolValue]);
    if (!SZFOIsFriend(laptop, @"Cara", NO, wait)) return NO;
    // After all that, Ben still writes, and both computers have it.
    CHECK(SZFE2ESay(profile.ben, anaAtBen, @"Ben again, after the deletions"));
    for (SZFE2EComputer *computer in @[ studio, laptop ])
        if (!SZFOChatShows(computer, @"Ben", @"Ben again, after the deletions", YES, wait)) return NO;
    return YES;
}

BOOL SZFE2EOneIDScenarioComputersNearby(SZFE2EWorld *world) {
    SZFOProfile *profile = SZFOStart(world, NO, NO, NULL);
    if (profile == nil) return NO;
    return SZFOBothWays(profile, 15) && SZFOSameStores(profile);
}

// Whether `helper` ever had a session through the relay (its technique log, ADR 0011: numbers only, one entry as each
// attempt ends).
static BOOL SZFOWentThroughRelay(SZFE2EHelper *helper) {
    NSString *path = [helper.stateDirectory stringByAppendingPathComponent:@"online-techniques.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id entries = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![entries isKindOfClass:NSArray.class]) return NO;
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"final"] integerValue] == SZFriendsOnlineTechniqueRelay &&
            [entry[@"seconds_to_first_stream"] integerValue] >= 0)
            return YES;
    }
    return NO;
}

BOOL SZFE2EOneIDScenarioComputersOnline(SZFE2EWorld *world) {
    NSString *coturn = NSProcessInfo.processInfo.environment[@"FRIENDS_TEST_COTURN"];
    BOOL relay = coturn.length > 0;
    if (!relay) printf("note: two computers online runs without the relay: set FRIENDS_TEST_COTURN\n");
    BOOL skipped = NO;
    SZFOProfile *profile = SZFOStart(world, YES, relay, &skipped);
    if (profile == nil) return skipped;
    @try {
        if (!SZFOBothWays(profile, 30) || !SZFOSameStores(profile)) return NO;
        // Written as each attempt ends, so read once both have stopped.
        if (relay) {
            CHECK(SZFOWentThroughRelay(profile.studio.helper) && SZFOWentThroughRelay(profile.laptop.helper),
                  "the two computers met through the relay");
        }
        return YES;
    } @finally {
        [profile.host stop];
    }
}

// One computer away while the other changes things; back, it catches up. Then the other way round.
static BOOL SZFOAway(SZFOProfile *profile, NSTimeInterval wait) {
    SZFE2EComputer *studio = profile.studio, *laptop = profile.laptop;
    NSString *caraAtLaptop = nil, *anaAtCara = nil;
    if (!SZFE2EBefriendNearby(laptop, profile.cara, &caraAtLaptop, &anaAtCara)) return NO;
    if (!SZFOIsFriend(studio, @"Cara", YES, wait) || !SZFOIsFriend(laptop, @"Ben", YES, wait)) return NO;
    NSString *anaAtBen = SZFOConversation(profile.ben, @"Ana");
    for (int round = 0; round < 2; round++) {
        SZFE2EComputer *away = round == 0 ? laptop : studio, *home = round == 0 ? studio : laptop;
        SZFE2EComputer *friendThere = round == 0 ? profile.ben : profile.cara;
        NSString *friendName = round == 0 ? @"Ben" : @"Cara";
        NSString *anaThere = round == 0 ? anaAtBen : anaAtCara;
        NSString *name = [NSString stringWithFormat:@"Ana, renamed while the %@ was away", away.helper.name];
        NSString *note = [NSString stringWithFormat:@"Note written while the %@ was away", away.helper.name];
        NSString *mine = [NSString stringWithFormat:@"To %@ while my other computer was away", friendName];
        NSString *theirs = [NSString stringWithFormat:@"%@ while one of Ana's computers was away", friendName];
        if (!SZFE2EStopComputer(away)) return NO;
        CHECK([[home.client intent:@"set_name" fields:@{@"name" : name}][@"ok"] boolValue]);
        CHECK(SZFE2ESay(home, @"you", note));
        CHECK(SZFE2ESay(home, SZFOConversation(home, friendName), mine));
        CHECK(SZFE2ESay(friendThere, anaThere, theirs));
        if (!SZFOChatShows(home, friendName, theirs, YES, wait)) return NO;
        // And a deletion while it is away: the other friend's chat.
        NSString *other = round == 0 ? @"Cara" : @"Ben";
        CHECK([[home.client intent:@"delete_history" fields:@{@"conversation_id" : SZFOConversation(home, other)}]
                  [@"ok"] boolValue]);
        if (!SZFE2ERestartComputer(away)) return NO;
        if (!SZFONamed(@[ away ], name, wait) || !SZFOChatShows(away, @"You", note, YES, wait) ||
            !SZFOChatShows(away, friendName, mine, YES, wait) || !SZFOChatShows(away, friendName, theirs, YES, wait))
            return NO;
        CHECK(SZFE2EWaitUntil(wait, ^BOOL {
                  NSString *conversation = SZFOConversation(away, other);
                  if (conversation == nil) return NO;
                  NSString *subscription = [away.client openConversation:conversation];
                  BOOL empty = SZFE2ETexts(away.client, subscription).count == 0;
                  [away.client intent:@"unsubscribe" fields:@{@"subscription" : subscription}];
                  return empty;
              }),
              "the chat deleted while %@ was away is empty there too", away.helper.name);
    }
    return YES;
}

BOOL SZFE2EOneIDScenarioComputersAway(SZFE2EWorld *world) {
    SZFOProfile *nearby = SZFOStart(world, NO, NO, NULL);
    if (nearby == nil || !SZFOAway(nearby, 20) || !SZFOSameStores(nearby)) return NO;
    // Online: a new world's worth of helpers, in the same scenario directory under new names.
    [world endScenario];
    [world beginScenario:@"o08-online"];
    BOOL skipped = NO;
    SZFOProfile *online = SZFOStart(world, YES, NO, &skipped);
    if (online == nil) return skipped;
    @try {
        return SZFOAway(online, 30) && SZFOSameStores(online);
    } @finally {
        [online.host stop];
    }
}
