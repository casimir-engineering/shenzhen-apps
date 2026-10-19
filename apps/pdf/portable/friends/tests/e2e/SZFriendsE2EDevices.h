// friends-e2e-devices-check: one person's Friends on several computers, between real helpers on loopback
// (friends-multi-device.md; ADR 0012 to 0014; PROTOCOL.md § Devices and § Joining). Every computer is its own helper
// process with its own state directory, driven only through the C client library, as the apps drive it. The helper is
// the online e2e helper (SZFriendsE2EOnlineHelperMain.m): nearby scenarios give it no host list, so it never checks
// in; the online ones give it the local Node host on 127.0.0.1 and a loopback Bonjour type of its own.
//
// A partition is a Bonjour type: a helper restarted with another type meets nobody on the first one.

#import "SZFriendsE2EHarness.h"

NS_ASSUME_NONNULL_BEGIN

// One computer: its helper, a client on it, and that client's list and profile subscriptions.
@interface SZFE2EComputer : NSObject
@property(nonatomic) SZFE2EHelper *helper;
@property(nonatomic, nullable) SZFE2EClient *client;
@property(nonatomic, copy, nullable) NSString *list, *profile;
@property(nonatomic, copy) NSString *displayName; // set as the profile name on a fresh computer
@end

// A helper named `name` started with `env` beside the harness's own, a client on it opened (activate), named
// `displayName` unless `join` (a computer about to join keeps no name of its own), with list and profile subscribed.
SZFE2EComputer *_Nullable SZFE2EStartComputer(SZFE2EWorld *world, NSString *name, NSString *displayName,
                                              NSDictionary *_Nullable env, BOOL join);
// After the helper's restart (with whatever extraEnvironment it has now): a client again, list and profile subscribed.
BOOL SZFE2ERestartComputer(SZFE2EComputer *computer);
// SIGTERM and the client closed.
BOOL SZFE2EStopComputer(SZFE2EComputer *computer);

// `newcomer` asks to join `existing`'s profile by its Friends ID; the request shows on `existing`, which approves; the
// code it shows is typed on `newcomer`, which then holds the profile's name and ID. Within `timeout` per step.
BOOL SZFE2EJoin(SZFE2EComputer *existing, SZFE2EComputer *newcomer, NSTimeInterval timeout);
// The same, with the profile's `others` showing the request too and dropping it once `newcomer` has joined.
BOOL SZFE2EJoinWatched(SZFE2EComputer *existing, SZFE2EComputer *newcomer, NSArray<SZFE2EComputer *> *others,
                       NSTimeInterval timeout);
// This computer's Friends ID, from its profile.
NSString *_Nullable SZFE2EFriendsID(SZFE2EComputer *computer);
// The rows of Your computers.
NSArray<NSDictionary *> *SZFE2EComputerRows(SZFE2EComputer *computer);
// This computer's device id, from its own row.
NSString *_Nullable SZFE2EThisDeviceID(SZFE2EComputer *computer);

// Stopped, then started again meeting only helpers of Bonjour type `serviceType` (`nil`: the scenario's own type).
BOOL SZFE2EMoveComputer(SZFE2EComputer *computer, NSString *_Nullable serviceType);
// A partition of its own: a Bonjour type no other helper of the scenario browses yet.
NSString *SZFE2EPartitionType(void);

// Ana's profile on two computers with a friend, Ben, all nearby: the studio befriends Ben, the laptop joins, and the
// computers are named "Studio Mac" and "Travel Laptop". Ben's conversation id on each comes back.
BOOL SZFE2EStartProfile(SZFE2EWorld *world, SZFE2EComputer *_Nullable *_Nonnull studio,
                        SZFE2EComputer *_Nullable *_Nonnull laptop, SZFE2EComputer *_Nullable *_Nonnull ben,
                        NSString *_Nullable *_Nonnull benAtStudio, NSString *_Nullable *_Nonnull benAtLaptop,
                        NSString *_Nullable *_Nonnull anaAtBen);
// Waits until every computer of `computers` lists exactly the computers named `names`, this one first.
BOOL SZFE2EComputersListed(NSArray<SZFE2EComputer *> *computers, NSArray<NSString *> *names, NSTimeInterval timeout);
// Waits until `subscription` on `computer` shows exactly `texts` as its messages, in any order.
BOOL SZFE2EShowsTexts(SZFE2EComputer *computer, NSString *subscription, NSArray<NSString *> *texts,
                      NSTimeInterval timeout);

// `asker` finds `visible` (visible for the moment) in Nearby, asks, and `visible` accepts: both are friends. The
// conversation id each gives the other comes back.
BOOL SZFE2EBefriendNearby(SZFE2EComputer *asker, SZFE2EComputer *visible, NSString *_Nullable *_Nonnull visibleAtAsker,
                          NSString *_Nullable *_Nonnull askerAtVisible);

NSDictionary *_Nullable SZFE2EListRow(SZFE2EComputer *computer, NSString *title);
NSArray<NSDictionary *> *SZFE2EKindItems(NSDictionary *_Nullable conversation, NSString *kind);
// The texts of a conversation's messages, in order.
NSArray<NSString *> *SZFE2ETexts(SZFE2EClient *client, NSString *subscription);
NSString *SZFE2ERandomToken(void);
// send_message with a fresh token; YES when the helper took it.
BOOL SZFE2ESay(SZFE2EComputer *computer, NSString *conversationID, NSString *text);

// Everything sync promises to keep the same on every computer of a profile, from the helper's store, read while the
// helper is stopped: one canonical string (conversations named by who they are with).
NSString *_Nullable SZFE2EStoreDump(SZFE2EHelper *helper);
// The store's presence secret and the presence secret its friend `name` is held with, hex; nil when absent.
NSString *_Nullable SZFE2EStorePresenceSecret(SZFE2EHelper *helper);
NSString *_Nullable SZFE2EStoreFriendPresenceSecret(SZFE2EHelper *helper, NSString *name);
// How the friend `name`'s computers stand in this store: "authorized 2 revoked 1".
NSString *_Nullable SZFE2EStoreFriendComputers(SZFE2EHelper *helper, NSString *name);

BOOL SZFE2EDevicesScenarioJoinNearby(SZFE2EWorld *world);
BOOL SZFE2EDevicesScenarioJoinOnline(SZFE2EWorld *world);
BOOL SZFE2EDevicesScenarioPartition(SZFE2EWorld *world);
BOOL SZFE2EDevicesScenarioRevoke(SZFE2EWorld *world);
BOOL SZFE2EDevicesScenarioErase(SZFE2EWorld *world);
BOOL SZFE2EDevicesScenarioYou(SZFE2EWorld *world);
BOOL SZFE2EDevicesScenarioFriendReachesOne(SZFE2EWorld *world);
BOOL SZFE2EDevicesScenarioRemovedWhileAway(SZFE2EWorld *world);

NS_ASSUME_NONNULL_END
