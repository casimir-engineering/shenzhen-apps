// The facts behind the golden fixtures: the people, items, profile and Nearby state the mockups show, at the
// fixtures' clock (Monday 12 October 2026, 14:47:48 Hong Kong time). Tests build every snapshot from these and
// compare it with fixtures/snapshots/ as parsed JSON.

#import <Foundation/Foundation.h>

#import "service/presentation/SZFriendsPresentation.h"
#import "tests/SZFriendsProtocolSchema.h"

NS_ASSUME_NONNULL_BEGIN

// Shared test state (SZFriendsPresentationTests.m).
extern int SZPFailures;
void SZPFail(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#define SZPExpect(condition, ...)                                                                       \
    do {                                                                                                \
        if (!(condition)) SZPFail(@"%s:%d: %@", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__]); \
    } while (0)

// The fixture clock and an instant at a Hong Kong wall-clock time ("2026-10-11 18:02").
NSDate *SZPNow(void);
NSDate *SZPHongKong(NSString *wallClock);

SZFriendsAudience *SZPAudience(void); // ShenzhenPDF in Hong Kong, the hello fixture's capabilities and formats
SZFriendsSnapshotBuilder *SZPBuilder(SZFriendsAudience *audience);

SZFriendsProfileFacts *SZPProfileRaph(void);       // cottage-violet, unreserved, named Raph
SZFriendsProfileFacts *SZPProfileIDChanged(void);  // walnut-garden after a collision, no name yet

// Synthetic identity keys (base64url) for the people below, for mentions, which find people by key only; and
// SZPKey to turn one into its 32 bytes.
static NSString *const SZPKeyMei = @"4VfVbTCPmosk0EmB4HbM9anI6WU2iMvJAX4lM3fFJu0";
static NSString *const SZPKeyKenji = @"gLwC335QDCEsaH4RFgglBnA5_tuYt2iBPS9iyZ9PfFM";
static NSString *const SZPKeyLena = @"Gx7e5Y2l0M5eZN_EoY_5Af4YbPJ-ZDkVBz8bp_RVH1k";
static NSString *const SZPKeyDaniel = @"wqxssxkOxWnY3gErAhojbyDStwGh7ItOEPkCK8k7c_U";
static NSString *const SZPKeyPriya = @"w9_wFJ6KVjt4YRmiX2wXPjxOORLKfcq7MbOoSxPXMc4";
static NSString *const SZPKeyTulip = @"Vvv7gpi00_qnpLi5abuYO2omFoq5oKTt29E3Pnq-Tm4";
static NSString *const SZPKeyJonas = @"GjynlfI-lEigaBnJKZJ_NkcDKuY-m15vLmDagtJlr84";
static NSString *const SZPKeyRaph = @"C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E";
// Someone none of them is friends with (Leo Park, bonfire-otter), and a key that is not Kenji's.
static NSString *const SZPKeyLeo = @"tN1JdICMMlIsgspydMWcnrWDAec9jXbspfRfygj7Q6o";
static NSString *const SZPKeyForged = @"s3f8Kz4p4VLH9QagQL1wR2ZwPi-p1QEz22O2RmM2NBo";
NSData *SZPKey(NSString *base64url);

// The list's seven people, keyed by conversation id, and the items each row previews.
NSDictionary<NSString *, SZFriendsPersonFacts *> *SZPPeople(void);
NSDictionary<NSString *, SZFriendsItemFacts *> *SZPPreviewItems(void);
NSArray<SZFriendsItemFacts *> *SZPItemsFor(NSString *conversationID);

SZFriendsNearbyFacts *SZPNearbyVisibleBluetoothOff(void);
SZFriendsNearbyFacts *SZPNearbyLocalNetworkDenied(void);

// Item builders for edge-case tests.
SZFriendsItemFacts *SZPMessage(NSString *itemID, BOOL outgoing, NSString *wallClock, NSString *text, NSInteger outbox);
SZFriendsItemFacts *SZPTransfer(NSString *itemID, BOOL outgoing, NSString *wallClock, NSString *name, uint64_t size,
                                NSInteger state);
SZFriendsItemFacts *SZPEvent(NSString *itemID, NSString *wallClock, NSString *kind);

// Strict JSON comparison: dictionaries by keys, booleans distinct from numbers. Returns the first difference's path
// and values, or nil when equal.
NSString *_Nullable SZPDifference(id actual, id expected, NSString *path);
// Reads fixtures/<relative> as JSON.
id SZPFixture(NSString *relative);
// Validates a view's data (or a reply result) against PROTOCOL.md's schema blocks.
void SZPValidateSnapshot(NSDictionary *data, NSString *view, NSString *label);
void SZPValidateResult(NSDictionary *result, NSString *intent, NSString *label);
// Compares a built view with fixtures/snapshots/<fixture> and validates it, as every fixture test does.
void SZPExpectFixture(NSDictionary *built, NSString *fixture, NSString *view);

// portable/friends, absolute: the failure tests read the store's headers from it.
extern NSString *SZPFriendsDirectory;

void SZPRunFixtureTests(void);
void SZPRunLabelTests(void);
void SZPRunViewEdgeTests(void);
void SZPRunPeopleEdgeTests(void);
void SZPRunFailureTests(void);
void SZPRunReaderTests(void);
void SZPRunAssistantTests(void);
void SZPRunMentionTests(void);
void SZPRunMentionTextTests(void);
void SZPRunOnlineTests(void);
void SZPRunLinksTests(void);
void SZPRunHistoryTests(void);
void SZPRunJoinTests(void);
void SZPRunDevicesTests(void);
void SZPRunDevicesBuildTests(void);

NS_ASSUME_NONNULL_END
