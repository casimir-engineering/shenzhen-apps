// Joining a profile from a new computer (friends-multi-device.md § Joining; PROTOCOL.md § Joining): the join request,
// the code the approving computer shows, CPace (SZFriendsCPace.h) over the session carrying the exchange, and the
// signed add link and profile the new computer receives.
//
// Helper-only and pure: no store, no clock (every `now` is passed in), no transport. The helper carries the messages
// below in JOIN frames (SZFriendsFrameTypeJoin) over Noise NN, nearby or through the Friends host, and keeps
// everything here in memory: a join request is stored nowhere, and the code never touches a disk.
//
// The exchange, with the new computer as CPace's initiator A and the approving one as responder B:
//   1. Request (new -> every device of the ID it typed): request id, device key, static key, name, system, Friends ID,
//      time, signed by the new device key. Each of the person's devices that hears it shows a waiting row.
//   2. The person presses Approve on one device. It draws a fresh 8-digit code and shows it for 5 minutes.
//   3. Code (new -> every device again, once the person typed the code): request id and Ya. Only the approving device
//      answers; the others say RECEIVED as for anything else, so nobody learns who approved.
//   4. Reply (approving -> new): Yb, the approving device's key, the root key, and tag Tb.
//   5. Confirm (new -> approving): the new device's consent to be added under that root, and tag Ta.
//   6. Welcome (approving -> new, in Parts): the chain carrying the signed add link, the profile, and a tag.
//   Either side may answer with Ended (denied, expired, too many attempts) instead.
// CPace's PRS is the code, CI binds the request (lv_cat("SZFriends join v1", request id, device key, static key)), sid
// is the session's handshake hash, ADa the new device key, ADb the approving device's key || the root key. Tags are
// BLAKE2b-256 keyed with ISK over their domain (and, for Ta, the consent; for the welcome, its body). So a device in
// the middle, which holds a different handshake hash with each side or substituted the keys in the request, ends up
// with keys that differ from both sides' unless it guessed the code, and each guess costs one of three attempts.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsDeviceChain;
@class SZFriendsIdentity;

#pragma mark - Limits

extern const NSUInteger SZFriendsJoinCodeDigits;             // 8
extern const NSUInteger SZFriendsJoinAttemptsMax;            // 3 codes per approval; the third wrong one ends it
extern const NSTimeInterval SZFriendsJoinCodeLifetime;       // 300 s from Approve
extern const NSUInteger SZFriendsJoinOpenRequestsMax;        // 3 rows waiting (or approved) on one device
extern const NSUInteger SZFriendsJoinNewRequestsPerHour;     // 6 new rows an hour (one taking a row's place is not new)
extern const NSTimeInterval SZFriendsJoinRequestLifetime;    // 1,800 s after the last copy of a request arrived
extern const NSTimeInterval SZFriendsJoinClockSkewMax;       // 600 s between the request's time and ours
extern const NSUInteger SZFriendsJoinMessageMax;             // 1,000 bytes: one message fits one Frame item online
extern const NSUInteger SZFriendsJoinPartMax;                // 900 bytes of the welcome per Part

#pragma mark - Messages

typedef NS_ENUM(uint8_t, SZFriendsJoinMessageKind) {
    SZFriendsJoinMessageRequest = 1,
    SZFriendsJoinMessageCode = 2,
    SZFriendsJoinMessageReply = 3,
    SZFriendsJoinMessageConfirm = 4,
    SZFriendsJoinMessagePart = 5,
    SZFriendsJoinMessageEnded = 6,
};

typedef NS_ENUM(uint8_t, SZFriendsJoinEndReason) {
    SZFriendsJoinEndDenied = 1,          // the person pressed Deny
    SZFriendsJoinEndExpired = 2,         // 5 minutes passed after Approve
    SZFriendsJoinEndTooManyAttempts = 3, // three codes were wrong
};

// The kind of a message, or 0 when it is not one this version reads.
SZFriendsJoinMessageKind SZFriendsJoinMessageKindOf(NSData *message);
NSData *SZFriendsJoinEndedMessage(SZFriendsJoinEndReason reason);
// The reason an Ended message gives, or 0.
SZFriendsJoinEndReason SZFriendsJoinEndReasonOf(NSData *message);

// A fresh code: SZFriendsJoinCodeDigits decimal digits, uniformly drawn ("04831220").
NSString *SZFriendsJoinNewCode(void);
// What the person typed, as a code: digits only (spaces, dashes and full-width digits allowed), or nil.
NSString *_Nullable SZFriendsJoinNormalizedCode(NSString *typed);

#pragma mark - A request, as a device of the person holds it

typedef NS_ENUM(NSInteger, SZFriendsJoinRequestState) {
    SZFriendsJoinRequestWaiting = 1,  // Approve and Deny show
    SZFriendsJoinRequestApproved = 2, // the code shows, until it is used, expires or is entered wrong three times
};

@interface SZFriendsJoinRequest : NSObject
@property(nonatomic, readonly) NSData *requestID; // 16 bytes, random per request
@property(nonatomic, readonly) NSData *deviceKey; // the new device's Ed25519 key
@property(nonatomic, readonly) NSData *staticKey; // its X25519 key
@property(nonatomic, readonly) NSString *name;    // "Mei's MacBook Air"
@property(nonatomic, readonly) NSString *system;  // "macOS 26.1"
@property(nonatomic, readonly) NSString *friendsID;
@property(nonatomic, readonly) NSDate *sentAt;    // the new device's clock
@property(nonatomic, readonly) NSDate *receivedAt;     // the first copy, here
@property(nonatomic, readonly) SZFriendsJoinRequestState state;
@property(nonatomic, readonly, nullable) NSString *code;        // Approved only
@property(nonatomic, readonly, nullable) NSDate *codeExpiresAt; // Approved only
@property(nonatomic, readonly) NSUInteger attempts;             // codes tried against this approval
@end

// A signed request from `device` for the profile holding `friendsID`. Nil for a name or system outside 1 to 64 bytes.
NSData *_Nullable SZFriendsJoinRequestMessage(SZFriendsIdentity *device, NSData *requestID, NSString *friendsID,
                                              NSString *name, NSString *system, NSDate *now);

#pragma mark - The new computer

// What one run on one session ended with, or that it goes on.
typedef NS_ENUM(NSInteger, SZFriendsJoinStepKind) {
    SZFriendsJoinStepSend = 1,     // send `message`, then wait for more
    SZFriendsJoinStepWait = 2,     // a Part arrived; more follow
    SZFriendsJoinStepJoined = 3,   // `chain` and `profile` arrived and verified
    SZFriendsJoinStepWrongCode = 4, // the other side's tag did not verify: a wrong code, or not the approving device
    SZFriendsJoinStepEnded = 5,    // the approving device said `reason`
    SZFriendsJoinStepFailed = 6,   // anything else: a malformed or out-of-order message, a chain that does not hold us
};

@interface SZFriendsJoinStep : NSObject
@property(nonatomic, readonly) SZFriendsJoinStepKind kind;
@property(nonatomic, readonly, nullable) NSData *message;
@property(nonatomic, readonly) SZFriendsJoinEndReason reason;
@property(nonatomic, readonly, nullable) SZFriendsDeviceChain *chain; // Joined: verified, authorizing this device
@property(nonatomic, readonly, nullable) NSData *profile;             // Joined: opaque to this layer (a PROFILE frame)
@property(nonatomic, readonly) NSInteger friendsIDState;              // Joined: the approving device's SZFriendsIDState
@end

// One run of the code on one session, on the new computer.
@interface SZFriendsJoinAttempt : NSObject
@property(nonatomic, readonly) NSData *codeMessage; // send first
- (SZFriendsJoinStep *)receiveMessage:(NSData *)message;
@end

@interface SZFriendsJoiner : NSObject
// `device` is this computer's own identity (never copied); `requestID` nil draws one.
- (instancetype)initWithIdentity:(SZFriendsIdentity *)device
                       friendsID:(NSString *)friendsID
                            name:(NSString *)name
                          system:(NSString *)system
                       requestID:(nullable NSData *)requestID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSData *requestID;
@property(nonatomic, readonly) NSString *friendsID;
- (nullable NSData *)requestMessageAtDate:(NSDate *)now;
// Nil unless `code` is SZFriendsJoinCodeDigits digits and the hash 64 bytes.
- (nullable SZFriendsJoinAttempt *)attemptWithCode:(NSString *)code handshakeHash:(NSData *)handshakeHash;
@end

#pragma mark - The person's other computers

typedef NS_ENUM(NSInteger, SZFriendsJoinReceipt) {
    SZFriendsJoinReceiptIgnored = 0,   // not for us, unverifiable, stale, our own or a device the chain knows
    SZFriendsJoinReceiptAdded = 1,     // a new waiting row
    SZFriendsJoinReceiptRefreshed = 2, // a copy of a request already here
    SZFriendsJoinReceiptLimited = 3,   // over SZFriendsJoinOpenRequestsMax or SZFriendsJoinNewRequestsPerHour
    SZFriendsJoinReceiptEnded = 4,     // a request this device ended: answer with `endedReason`'s message
};

// The approving device's side of one run, made from a Code message.
@interface SZFriendsJoinApproval : NSObject
@property(nonatomic, readonly) NSData *requestID;
@property(nonatomic, readonly) NSData *replyMessage; // send at once
@end

// What a correct Confirm produced: the chain to merge into the store first, then the Parts to send.
@interface SZFriendsJoinWelcome : NSObject
@property(nonatomic, readonly) SZFriendsDeviceChain *chain;
@property(nonatomic, readonly) NSArray<NSData *> *parts;
@end

@interface SZFriendsJoinApprover : NSObject
- (instancetype)initWithIdentity:(SZFriendsIdentity *)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A Request message for `ownFriendsID` (normalized), judged against our chain (nil before it has a genesis).
- (SZFriendsJoinReceipt)receiveRequestMessage:(NSData *)message
                                 ownFriendsID:(nullable NSString *)ownFriendsID
                                        chain:(nullable SZFriendsDeviceChain *)chain
                                          now:(NSDate *)now
                                  endedReason:(SZFriendsJoinEndReason *_Nullable)endedReason;
// Rows to show, oldest first: unexpired, not ended, and not a device `chain` already holds (the add reached us).
- (NSArray<SZFriendsJoinRequest *> *)openRequestsWithChain:(nullable SZFriendsDeviceChain *)chain now:(NSDate *)now;
// When the rows may next change with no new message (a code or a request expiring), or nil.
- (nullable NSDate *)nextChangeAfter:(NSDate *)now;
// Approve shows a fresh code; pressed again on an approved request, the code it shows already (nothing new is drawn);
// nil for a request that is gone. Deny ends it (and the same device's requests for
// SZFriendsJoinRequestLifetime). Cancel withdraws an approval: the request ends as Denied.
- (nullable NSString *)approveRequestID:(NSData *)requestID now:(NSDate *)now;
- (BOOL)denyRequestID:(NSData *)requestID now:(NSDate *)now;
// A Code message on a session with `handshakeHash`. Nil with *ended 0: not a request approved here (answer as any
// device does). Nil with *ended set: answer with its Ended message. Each Code counts one attempt.
- (nullable SZFriendsJoinApproval *)approvalForCodeMessage:(NSData *)message
                                             handshakeHash:(NSData *)handshakeHash
                                                  rootKey:(NSData *)rootKey
                                                       now:(NSDate *)now
                                                     ended:(SZFriendsJoinEndReason *)ended;
// The Confirm of `approval`: the add link on `chain`, signed by this device, and the welcome. Nil when the tag or the
// consent does not verify (that attempt stays counted), the code expired, or the chain refused the device.
- (nullable SZFriendsJoinWelcome *)welcomeForConfirmMessage:(NSData *)message
                                                   approval:(SZFriendsJoinApproval *)approval
                                                      chain:(SZFriendsDeviceChain *)chain
                                                    profile:(NSData *)profile
                                             friendsIDState:(NSInteger)friendsIDState
                                                        now:(NSDate *)now;
// As above, with the profile part made once the Confirm checked out, from the chain that holds the new device (the
// caller stores it first, then says what the profile held up to then); nil from `profile` sends nothing.
- (nullable SZFriendsJoinWelcome *)welcomeForConfirmMessage:(NSData *)message
                                                   approval:(SZFriendsJoinApproval *)approval
                                                      chain:(SZFriendsDeviceChain *)chain
                                             friendsIDState:(NSInteger)friendsIDState
                                                        now:(NSDate *)now
                                            profileForChain:(NSData *_Nullable (^)(SZFriendsDeviceChain *added))profile;
// The session carrying `approval` ended before a Confirm (the new computer found the code wrong, or went away): that
// attempt failed, and the third failure ends the approval at once.
- (void)abandonApproval:(SZFriendsJoinApproval *)approval now:(NSDate *)now;
// The welcome was stored and sent: the request is done.
- (void)finishRequestID:(NSData *)requestID;
// Reset Friends, or this device left the profile: nothing is waiting any more.
- (void)forgetEverything;
@end

NS_ASSUME_NONNULL_END
