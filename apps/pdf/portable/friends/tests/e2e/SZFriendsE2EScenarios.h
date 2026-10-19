// friends-e2e-check scenarios and the steps they share. Each scenario starts its own pair of helpers in its own
// directory with its own Bonjour type, finishes within 60 s, and leaves no process behind (the runner kills what
// is left).

#import "SZFriendsE2EHarness.h"

NS_ASSUME_NONNULL_BEGIN

// Two helpers, a client on each, both opened (activate) and named, each subscribed to its list.
@interface SZFE2EPair : NSObject
@property(nonatomic) SZFE2EHelper *helperA;
@property(nonatomic) SZFE2EHelper *helperB;
@property(nonatomic, nullable) SZFE2EClient *a;
@property(nonatomic, nullable) SZFE2EClient *b;
@property(nonatomic, copy, nullable) NSString *listA;
@property(nonatomic, copy, nullable) NSString *listB;
@property(nonatomic, copy, nullable) NSString *bAtA; // B's conversation id in A's list
@property(nonatomic, copy, nullable) NSString *aAtB;
@property(nonatomic, copy, nullable) NSString *codeA; // the comparison code each side showed
@property(nonatomic, copy, nullable) NSString *codeB;
@end

BOOL SZFE2EStartPair(SZFE2EWorld *world, SZFE2EPair *pair, NSDictionary *_Nullable envA, NSDictionary *_Nullable envB);
// One helper with a client, opened (activate) and named, subscribed to its list.
BOOL SZFE2EStartSingle(SZFE2EWorld *world, NSString *name, NSString *displayName, NSDictionary *_Nullable env,
                       SZFE2EHelper *_Nullable *_Nonnull helper, SZFE2EClient *_Nullable *_Nonnull client,
                       NSString *_Nullable *_Nonnull list);
// The first half of befriending: B visible, A asks from Nearby, B's list shows the request; both rows' ids set.
BOOL SZFE2ERequestFromNearby(SZFE2EPair *pair);
// A reconnected client (after its helper restarted) subscribes to its list again.
BOOL SZFE2EReconnect(SZFE2EClient *client, NSString *_Nullable *_Nonnull list);
// B becomes visible, A finds B in Nearby and asks, both see the same comparison code, B accepts.
BOOL SZFE2EBefriend(SZFE2EPair *pair);

NSDictionary *_Nullable SZFE2ERowTitled(NSDictionary *_Nullable list, NSString *title);
NSDictionary *_Nullable SZFE2ERowWithID(NSDictionary *_Nullable list, NSString *conversationID);
NSArray<NSDictionary *> *SZFE2EItems(NSDictionary *_Nullable conversation, NSString *kind);
NSString *SZFE2EToken(void);
// The row titled `title` while it waits as an Add by ID answer the host did not vouch for, or nil.
NSDictionary *_Nullable SZFE2EUnconfirmedAnswer(NSDictionary *_Nullable list, NSString *title);
// Waits for that row, checks its card says why it waits, accepts it and waits until it is a friend.
BOOL SZFE2EAcceptAnswer(SZFE2EClient *client, NSString *list, NSString *title);

BOOL SZFE2EScenarioRequest(SZFE2EWorld *world);
BOOL SZFE2EScenarioMessages(SZFE2EWorld *world);
BOOL SZFE2EScenarioTransfer(SZFE2EWorld *world);
BOOL SZFE2EScenarioAutoAccept(SZFE2EWorld *world);
BOOL SZFE2EScenarioKillResume(SZFE2EWorld *world);
BOOL SZFE2EScenarioAddByID(SZFE2EWorld *world);
BOOL SZFE2EScenarioBlock(SZFE2EWorld *world);
BOOL SZFE2EScenarioExpiry(SZFE2EWorld *world);
BOOL SZFE2EScenarioSameBadge(SZFE2EWorld *world);
BOOL SZFE2EScenarioBluetoothToNetwork(SZFE2EWorld *world);
BOOL SZFE2EScenarioCodeAfterRequest(SZFE2EWorld *world);
BOOL SZFE2EScenarioAnswersByID(SZFE2EWorld *world);
BOOL SZFE2EScenarioTwoHolders(SZFE2EWorld *world);
BOOL SZFE2EScenarioRemoveBeforeDelivery(SZFE2EWorld *world);
BOOL SZFE2EScenarioAdmission(SZFE2EWorld *world);
BOOL SZFE2EScenarioStrangerLifetimes(SZFE2EWorld *world);
BOOL SZFE2EScenarioHostCheckIn(SZFE2EWorld *world);
BOOL SZFE2EScenarioAskAgainByID(SZFE2EWorld *world);
BOOL SZFE2EScenarioAttestedHolder(SZFE2EWorld *world);
BOOL SZFE2EScenarioCopiedAttestation(SZFE2EWorld *world);
BOOL SZFE2EScenarioViaAssistant(SZFE2EWorld *world);
BOOL SZFE2EScenarioMessageStatus(SZFE2EWorld *world);
BOOL SZFE2EScenarioCancelMessage(SZFE2EWorld *world);
BOOL SZFE2EScenarioThumbnails(SZFE2EWorld *world);
BOOL SZFE2EScenarioThumbnailRefusals(SZFE2EWorld *world);
BOOL SZFE2EScenarioCancelAfterLostAck(SZFE2EWorld *world);
BOOL SZFE2EScenarioMentionAddBound(SZFE2EWorld *world);
BOOL SZFE2EScenarioMentionForged(SZFE2EWorld *world);
BOOL SZFE2EScenarioTwoAppsShareHelper(SZFE2EWorld *world);
BOOL SZFE2EScenarioTwoAppsHandover(SZFE2EWorld *world);
BOOL SZFE2EScenarioDeleteHistory(SZFE2EWorld *world);

NS_ASSUME_NONNULL_END
