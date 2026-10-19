// friends-e2e-check, Add by ID online (SZFriendsE2EOnline.h): two helpers that are never nearby (each browses its own
// loopback Bonjour type) become friends through the local host. The request travels as Noise NN to whoever holds the
// Friends ID; once the person accepts (or a live invite accepts for them) the holder's IK callback completes the
// friendship and the normal online path carries messages. A friend link binds the request to the key it carries, and
// the standing link accepts at most 20 requests a day at once.

#import "SZFriendsE2EOnline.h"

#import <sodium.h>

#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHelperServices.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/links/SZFriendsLinkWire.h"
#import "service/store/SZFriendsStoreLinks.h"

// Two started helpers, Ana (the requester) and Ben (who holds the ID), with a list subscription each.
@interface SZFE2EAddPair : NSObject
@property(nonatomic) SZFE2EHelper *helperA, *helperB;
@property(nonatomic) SZFE2EClient *a, *b;
@property(nonatomic, copy) NSString *listA, *listB, *idB;
@end

@implementation SZFE2EAddPair
@end

static NSDictionary *Data(SZFE2EClient *client, NSString *subscription) {
    return [client dataFor:subscription] ?: @{};
}

static NSDictionary *Row(SZFE2EClient *client, NSString *list, BOOL (^match)(NSDictionary *row)) {
    for (NSDictionary *row in Data(client, list)[@"rows"]) {
        if (match(row)) return row;
    }
    return nil;
}

static BOOL IsFriend(NSDictionary *row) {
    return [row[@"drop_label"] isKindOfClass:[NSString class]];
}

static BOOL IsWaitingRequest(NSDictionary *row) {
    return [row[@"waiting"] isKindOfClass:[NSDictionary class]] && [row[@"waiting"][@"kind"] isEqual:@"request"];
}

// "https://host/f#<fragment>" -> "f.<fragment>": what the page's buttons hand an app.
static NSString *AppPayload(NSString *url) {
    NSRange hash = [url rangeOfString:@"#"];
    if (![url isKindOfClass:[NSString class]] || hash.location == NSNotFound || hash.location < 2) return nil;
    NSString *kind = [url substringWithRange:NSMakeRange(hash.location - 1, 1)];
    return [NSString stringWithFormat:@"%@.%@", kind, [url substringFromIndex:hash.location + 1]];
}

// Ben's store before he starts: his standing friend link has accepted `count` requests in the last hours.
static BOOL SeedLinkAccepts(SZFE2EHelper *helper, NSUInteger count) {
    NSString *state = helper.stateDirectory;
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    SZFriendsStatePaths *paths = [[SZFriendsStatePaths alloc] initWithStateDirectory:state];
    CHECK([paths prepareStateDirectoryWithError:NULL] && [paths prepareDirectoriesWithError:NULL], "%@", state);
    SZFriendsHelperServices *services = [[SZFriendsHelperServices alloc]
        initWithPaths:paths environment:@{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"file"}
            resources:[SZFriendsHelperResources loadFromBundle:[NSBundle mainBundle]]];
    [services open];
    SZFriendsStore *store = services.store;
    NSData *token = [store standingInviteCreatingIfNeeded:YES error:NULL].token;
    BOOL all = token != nil;
    NSDate *now = [NSDate date];
    for (NSUInteger i = 0; i < count; i++) {
        all = all && [store useInvite:token atDate:[now dateByAddingTimeInterval:-3600.0 + (double)i] error:NULL];
    }
    [services close];
    CHECK(all, "Ben's link has accepted %lu today", (unsigned long)count);
    return YES;
}

static BOOL StartPair(SZFE2EWorld *world, SZFE2EOnlineHost *host, SZFE2EAddPair *pair, NSUInteger linkAccepts) {
    pair.helperA = [world helperNamed:@"a"];
    pair.helperB = [world helperNamed:@"b"];
    if (linkAccepts > 0 && !SeedLinkAccepts(pair.helperB, linkAccepts)) return NO;
    for (SZFE2EHelper *helper in @[ pair.helperA, pair.helperB ]) {
        helper.extraEnvironment = [host environmentForHelper:helper.name];
        CHECK([helper start], "%@ starts", helper.name);
    }
    pair.a = [SZFE2EClient clientForHelper:pair.helperA];
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.a != nil && pair.b != nil, "both clients reach READY");
    CHECK([[pair.a intent:@"set_name" fields:@{@"name" : @"Ana Lima"}][@"ok"] isEqual:@YES] &&
              [[pair.b intent:@"set_name" fields:@{@"name" : @"Ben Okafor"}][@"ok"] isEqual:@YES],
          "names");
    NSString *profileA = [pair.a subscribe:@"profile" params:nil], *profileB = [pair.b subscribe:@"profile" params:nil];
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return [Data(pair.a, profileA)[@"id"][@"state"] isEqual:@"reserved"] &&
                     [Data(pair.b, profileB)[@"id"][@"state"] isEqual:@"reserved"];
          }),
          "both IDs reserved: %@ %@", Data(pair.a, profileA)[@"id"], Data(pair.b, profileB)[@"id"]);
    pair.idB = Data(pair.b, profileB)[@"id"][@"friends_id"];
    // Both checked in with protocol 2 and published their records: a newly connected app is told `online`.
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              SZFE2EClient *late = [SZFE2EClient clientForHelper:pair.helperB];
              BOOL online = [late.welcome[@"capabilities"] containsObject:@"online"];
              [late close];
              return online;
          }),
          "Ben is online");
    SZFE2EPump(1);
    pair.listA = [pair.a subscribe:@"list" params:nil];
    pair.listB = [pair.b subscribe:@"list" params:nil];
    return pair.idB != nil;
}

// Both lists show the other as a friend, and a message from Ana reaches Ben over the online session.
static BOOL BecameFriends(SZFE2EAddPair *pair, NSTimeInterval timeout) {
    __block NSDictionary *benAtA = nil, *anaAtB = nil;
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
              benAtA = Row(pair.a, pair.listA, ^BOOL(NSDictionary *row) { return IsFriend(row); });
              anaAtB = Row(pair.b, pair.listB, ^BOOL(NSDictionary *row) { return IsFriend(row); });
              return benAtA != nil && anaAtB != nil;
          }),
          "friends on both Macs: %@ / %@", Data(pair.a, pair.listA)[@"rows"], Data(pair.b, pair.listB)[@"rows"]);
    NSString *text = [NSString stringWithFormat:@"Hello from far away %u", arc4random()];
    NSDictionary *sent = [pair.a intent:@"send_message" fields:@{@"conversation_id" : benAtA[@"conversation_id"],
                                                                 @"text" : text,
                                                                 @"client_token" : [NSUUID UUID].UUIDString}];
    CHECK([sent[@"ok"] isEqual:@YES], "%@", sent);
    NSString *atB = [pair.b openConversation:anaAtB[@"conversation_id"]];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              for (NSDictionary *item in Data(pair.b, atB)[@"items"]) {
                  if ([item[@"kind"] isEqual:@"message"] && [item[@"accessibility_label"] containsString:text]) {
                      return YES;
                  }
              }
              return NO;
          }),
          "the message arrives online: %@", Data(pair.b, atB)[@"items"]);
    return YES;
}

static NSString *FriendLink(SZFE2EClient *client) {
    NSString *profile = [client subscribe:@"profile" params:nil];
    SZFE2EWaitUntil(10, ^BOOL { return Data(client, profile)[@"links"][@"friend"][@"url"] != nil; });
    return AppPayload(Data(client, profile)[@"links"][@"friend"][@"url"]);
}

typedef BOOL (^SZFE2EAddBody)(SZFE2EAddPair *pair);

static BOOL RunPair(SZFE2EWorld *world, NSUInteger linkAccepts, SZFE2EAddBody body) {
    NSString *why = nil;
    SZFE2EOnlineHost *host = [SZFE2EOnlineHost startInWorld:world relay:NO skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip add online: %s\n", why.UTF8String);
        return why != nil;
    }
    BOOL ok = NO;
    @try {
        SZFE2EAddPair *pair = [SZFE2EAddPair new];
        ok = StartPair(world, host, pair, linkAccepts) && body(pair);
        [pair.a close];
        [pair.b close];
    } @finally {
        [host stop];
    }
    return ok;
}

BOOL SZFE2EOnlineScenarioAddByID(SZFE2EWorld *world) {
    return RunPair(world, 0, ^BOOL(SZFE2EAddPair *pair) {
        NSDictionary *sent = [pair.a intent:@"add_by_id" fields:@{@"friends_id" : pair.idB}];
        // Online, the words no longer wait for being nearby.
        CHECK([sent[@"result"][@"message"] hasSuffix:@"while ShenzhenPDF, Shenzhen Files or Shenzhen 3D is open "
                                                     @"for both of you, and you’ll be friends once they accept."],
              "%@", sent);
        __block NSDictionary *asked = nil;
        CHECK(SZFE2EWaitUntil(20, ^BOOL {
                  asked = Row(pair.b, pair.listB, ^BOOL(NSDictionary *row) { return IsWaitingRequest(row); });
                  return asked != nil;
              }),
              "the request reaches Ben online: %@", Data(pair.b, pair.listB)[@"rows"]);
        SZFE2EPump(2);
        CHECK(Row(pair.a, pair.listA, ^BOOL(NSDictionary *row) { return IsFriend(row); }) == nil,
              "nothing happens until Ben answers");
        CHECK([[pair.b intent:@"accept_request" fields:@{@"conversation_id" : asked[@"conversation_id"]}][@"ok"]
                  isEqual:@YES],
              "accept");
        return BecameFriends(pair, 30);
    });
}

BOOL SZFE2EOnlineScenarioFriendLink(SZFE2EWorld *world) {
    return RunPair(world, 0, ^BOOL(SZFE2EAddPair *pair) {
        NSString *payload = FriendLink(pair.b);
        CHECK(payload != nil, "Ben's friend link");
        NSDictionary *card = [pair.a intent:@"open_link" fields:@{@"payload" : payload}][@"result"][@"card"];
        CHECK([card[@"title"] isEqual:@"Add Ben Okafor?"], "%@", card);
        NSDictionary *sent = [pair.a intent:@"add_from_link" fields:@{@"payload" : payload}];
        CHECK([sent[@"result"][@"message"] isEqual:@"Request sent to Ben Okafor. It reaches them while ShenzhenPDF, "
                                                    @"Shenzhen Files or Shenzhen 3D is open for both of you, and "
                                                    @"you’re friends as soon as it does."],
              "%@", sent);
        CHECK(SZFE2EWaitUntil(20, ^BOOL {
                  return Row(pair.b, pair.listB, ^BOOL(NSDictionary *row) {
                             return IsFriend(row) && [row[@"subtitle"] isEqual:@"Added through your link"];
                         }) != nil;
              }),
              "accepted at once on Ben's Mac: %@", Data(pair.b, pair.listB)[@"rows"]);
        CHECK(BecameFriends(pair, 30));
        return YES;
    });
}

BOOL SZFE2EOnlineScenarioLinkKeyMismatch(SZFE2EWorld *world) {
    return RunPair(world, 0, ^BOOL(SZFE2EAddPair *pair) {
        // A link with Ben's ID and invite but someone else's key: whoever holds the ID gets the request, and only
        // that other key could complete it.
        SZFriendsFriendLinkPayload *link = SZFriendsParseLinkPayload(FriendLink(pair.b));
        CHECK([link isKindOfClass:[SZFriendsFriendLinkPayload class]], "%@", link);
        NSMutableData *seed = [NSMutableData dataWithLength:32], *staticKey = [NSMutableData dataWithLength:32];
        randombytes_buf(seed.mutableBytes, 32);
        randombytes_buf(staticKey.mutableBytes, 32);
        link.identityKey = [SZFriendsIdentity identityWithSigningSeed:seed staticPrivateKey:staticKey].publicKey;
        NSString *forged = link.payloadString;
        CHECK([[pair.a intent:@"add_from_link" fields:@{@"payload" : forged ?: @""}][@"ok"] isEqual:@YES], "sent");
        CHECK(SZFE2EWaitUntil(20, ^BOOL {
                  return Row(pair.b, pair.listB, ^BOOL(NSDictionary *row) {
                             return [row[@"subtitle"] isEqual:@"Added through your link"];
                         }) != nil;
              }),
              "the request reached the ID's holder, whose link accepted it: %@", Data(pair.b, pair.listB)[@"rows"]);
        // Ben's Mac dials Ana with the request's token; Ana's admits only the key the link carried.
        SZFE2EPump(8);
        CHECK(Row(pair.a, pair.listA, ^BOOL(NSDictionary *row) { return IsFriend(row); }) == nil,
              "Ana never becomes Ben's friend: %@", Data(pair.a, pair.listA)[@"rows"]);
        CHECK(Row(pair.a, pair.listA, ^BOOL(NSDictionary *row) { return [row[@"title"] isEqual:@"Ben Okafor"]; }),
              "her request still waits for the link's key: %@", Data(pair.a, pair.listA)[@"rows"]);
        return YES;
    });
}

BOOL SZFE2EOnlineScenarioLinkCap(SZFE2EWorld *world) {
    return RunPair(world, SZFriendsInviteAcceptsPerDay, ^BOOL(SZFE2EAddPair *pair) {
        NSString *payload = FriendLink(pair.b);
        CHECK([[pair.a intent:@"add_from_link" fields:@{@"payload" : payload ?: @""}][@"ok"] isEqual:@YES], "sent");
        __block NSDictionary *asked = nil;
        CHECK(SZFE2EWaitUntil(20, ^BOOL {
                  asked = Row(pair.b, pair.listB, ^BOOL(NSDictionary *row) { return IsWaitingRequest(row); });
                  return asked != nil;
              }),
              "past 20 today the request waits for Ben: %@", Data(pair.b, pair.listB)[@"rows"]);
        CHECK(Row(pair.b, pair.listB, ^BOOL(NSDictionary *row) { return IsFriend(row); }) == nil, "not accepted");
        CHECK([[pair.b intent:@"accept_request" fields:@{@"conversation_id" : asked[@"conversation_id"]}][@"ok"]
                  isEqual:@YES],
              "Ben accepts");
        return BecameFriends(pair, 30);
    });
}
