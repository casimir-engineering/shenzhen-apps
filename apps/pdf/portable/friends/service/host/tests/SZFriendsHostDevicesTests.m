// friends-host-check: a device checking in for its person (HOST-PROTOCOL.md § Devices), against the scripted host. A
// device that joined a profile names the person's root and brings the chain, both under its signature; it never draws
// a Friends ID of its own after a collision; a host from before protocol 3 gets a protocol 2 check-in; and a host
// closing with 4002 stops it for good.

#import "SZFriendsHostHarness.h"
#import "SZFriendsHostOnlineTests.h"

#import <sodium.h>

static NSData *SZFHBytes(uint8_t fill, NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    memset(data.mutableBytes, fill, length);
    return data;
}

static void SZFHTestMembershipInCheckin(void) {
    SZFHHarness *h = SZFHMakeHarness();
    NSData *root = SZFHBytes(0x5a, 32), *chain = SZFHBytes(0x07, 300);
    h.client.membershipProvider = ^NSData *(NSData **out) {
        *out = chain;
        return root;
    };
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    NSDictionary *checkin = SZFHChallenge(h, socket, @"main-hk");
    SZFHExpect([checkin[@"root_key"] isEqual:SZFriendsHostBase64URLEncode(root)] &&
                   [checkin[@"chain"] isEqual:SZFriendsHostBase64URLEncode(chain)] && [checkin[@"protocol"] isEqual:@3],
               @"the check-in names the person and brings the chain: %@", checkin);
    NSData *message = SZFriendsHostCheckinMessage(@"main-hk", SZFriendsHostBase64URLDecode(SZFHNonce, 32),
                                                  h.identity.publicKey, @"maple-river", NO, @"26.10.12-1", 3, 1, root,
                                                  chain);
    SZFHExpect(SZFHVerify(SZFriendsHostBase64URLDecode(checkin[@"sig"], 64), message, @"SZFriends checkin v1",
                          h.identity.publicKey),
               @"the signature covers the root and the chain");
    NSData *other = SZFriendsHostCheckinMessage(@"main-hk", SZFriendsHostBase64URLDecode(SZFHNonce, 32),
                                                h.identity.publicKey, @"maple-river", NO, @"26.10.12-1", 3, 1, root,
                                                SZFHBytes(0x08, 300));
    SZFHExpect(!SZFHVerify(SZFriendsHostBase64URLDecode(checkin[@"sig"], 64), other, @"SZFriends checkin v1",
                           h.identity.publicKey),
               @"another chain does not verify");
    // The ID is the person's: the welcome's is adopted, and a collision draws nothing on a joined device.
    h.client.drawsIDs = NO;
    NSUInteger sent = socket.sent.count;
    SZFHWelcome(h, socket, @{@"reservation" : @"taken", @"friends_id" : [NSNull null]});
    SZFHDrain(h.queue);
    SZFHExpect(socket.sent.count == sent && h.providedIDs.count == 1,
               @"no fresh ID drawn or reserved: %@ %@", socket.sent, h.providedIDs);
    SZFHExpect(![h.recorder.events.lastObject hasPrefix:@"renamed"], @"no rename: %@", h.recorder.events);
    [h.client stop];
}

// A host from before protocol 3 says no protocol in its challenge and would refuse the devices fields' signature: a
// joined device checks in there with protocol 2, as itself, until the host is updated.
static void SZFHTestOlderHost(void) {
    SZFHHarness *h = SZFHMakeHarness();
    NSData *root = SZFHBytes(0x5a, 32), *chain = SZFHBytes(0x07, 300);
    h.client.membershipProvider = ^NSData *(NSData **out) {
        *out = chain;
        return root;
    };
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    [socket deliver:@{@"type" : @"challenge", @"host_id" : @"main-hk", @"nonce" : SZFHNonce, @"time" : @"x"}];
    SZFHDrain(h.queue);
    NSDictionary *checkin = socket.sent.lastObject;
    SZFHExpect([checkin[@"protocol"] isEqual:@2] && checkin[@"root_key"] == nil && checkin[@"chain"] == nil,
               @"a protocol 2 check-in: %@", checkin);
    NSData *message = SZFriendsHostCheckinMessage(@"main-hk", SZFriendsHostBase64URLDecode(SZFHNonce, 32),
                                                  h.identity.publicKey, @"maple-river", NO, @"26.10.12-1", 2, 1, nil,
                                                  nil);
    SZFHExpect(SZFHVerify(SZFriendsHostBase64URLDecode(checkin[@"sig"], 64), message, @"SZFriends checkin v1",
                          h.identity.publicKey),
               @"signed as protocol 2 signs it, which the older host verifies");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river"});
    SZFHExpect([h.client.personKey isEqualToData:h.identity.publicKey], @"there it is its own person");
    [h.client stop];
}

static void SZFHTestRevokedStops(void) {
    SZFHHarness *h = SZFHMakeHarness();
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river"});
    [socket closeWithCode:4002];
    SZFHDrain(h.queue);
    SZFHExpect([h.recorder saw:@"revoked"] && h.client.state == SZFriendsHostStateStopped,
               @"4002 stops the client: %@", h.recorder.events);
    SZFHExpect(SZFHSocket(h, 1) == nil, @"and nothing reconnects (the first retry would come within 1 s)");
}

// A joined device's record is filed under its person: signed by the device over the root's rendezvous key, which is
// the key the host files every device of the person under (HOST-PROTOCOL-ONLINE.md § Several devices).
static void SZFHTestRecordUnderTheRoot(void) {
    SZFHOnlineRecorder *recorder = [[SZFHOnlineRecorder alloc] init];
    SZFHHarness *h = SZFHOnlineHarness(recorder, ^NSData * { return [NSMutableData dataWithLength:512]; });
    NSData *root = SZFHBytes(0x5a, 32), *chain = SZFHBytes(0x07, 300);
    h.client.membershipProvider = ^NSData *(NSData **out) {
        *out = chain;
        return root;
    };
    SZFHStart(h);
    SZFHFakeSocket *socket = SZFHSocket(h, 0);
    SZFHChallenge(h, socket, @"main-hk");
    SZFHWelcome(h, socket, @{@"reservation" : @"reserved", @"friends_id" : @"maple-river", @"online" : @YES});
    NSDictionary *publish = SZFHLast(socket, @"rdv_publish");
    NSData *sealed = SZFriendsHostBase64URLDecode(publish[@"sealed"], 512);
    NSData *message = SZFriendsHostRendezvousRecordMessage(@"main-hk", SZFriendsHostRendezvousKey(root),
                                                           (uint64_t)[publish[@"seq"] longLongValue],
                                                           [publish[@"expires"] longLongValue], sealed);
    SZFHExpect(publish != nil && SZFHVerify(SZFriendsHostBase64URLDecode(publish[@"sig"], 64), message,
                                            @"SZFriends rendezvous record v1", h.identity.publicKey),
               @"the record is signed by the device over the person's rendezvous key");
    [h.client stop];
}

void SZFHRunDevicesTests(void) {
    SZFHTestMembershipInCheckin();
    SZFHTestOlderHost();
    SZFHTestRevokedStops();
    SZFHTestRecordUnderTheRoot();
}
