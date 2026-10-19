// Shared by the join suites: devices with fixed keys, a profile's chain, and one whole run between a joiner and an
// approver over a session whose handshake hash each side is given (the same one, or two, for a device in the middle).

#import "SZFriendsIdentityTestSupport.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/identity/SZFriendsJoinInternal.h"

static inline NSDate *JoinAt(double seconds) { return [NSDate dateWithTimeIntervalSince1970:1791800000 + seconds]; }

static inline SZFriendsIdentity *JoinDevice(uint8_t seed) {
    uint8_t signing[32], key[32];
    memset(signing, seed, 32);
    memset(key, (uint8_t)(seed + 0x40), 32);
    return [SZFriendsIdentity identityWithSigningSeed:[NSData dataWithBytes:signing length:32]
                                     staticPrivateKey:[NSData dataWithBytes:key length:32]];
}

static inline NSData *JoinHash(uint8_t fill) {
    NSMutableData *hash = [NSMutableData dataWithLength:64];
    memset(hash.mutableBytes, fill, 64);
    return hash;
}

static inline SZFriendsDeviceChain *JoinGenesis(SZFriendsIdentity *root) {
    return [SZFriendsDeviceChain genesisChainWithIdentity:root name:@"Mei's iMac" system:@"macOS 26.0"
                                                     date:JoinAt(0) error:NULL];
}

static inline SZFriendsJoiner *JoinJoiner(SZFriendsIdentity *device, NSString *friendsID) {
    return [[SZFriendsJoiner alloc] initWithIdentity:device friendsID:friendsID name:@"Mei's MacBook Air"
                                              system:@"macOS 26.1" requestID:nil];
}

static inline NSData *JoinProfileBytes(void) {
    return [@"profile frame bytes" dataUsingEncoding:NSUTF8StringEncoding];
}

// What a run ended with on both sides.
typedef struct {
    SZFriendsJoinStepKind joiner;      // the joiner's last step
    BOOL welcomed;                     // the approver produced a welcome
    SZFriendsJoinEndReason ended;      // the approver answered the Code with Ended
} SZFJoinRun;

// One run: the joiner types `code` on a session whose hash it sees as `joinerHash`, the approver as `approverHash`.
// `tamper`, if given, may change each message on its way (index counts messages in both directions).
static inline SZFJoinRun SZFJoinRunOnce(SZFriendsJoiner *joiner, SZFriendsJoinApprover *approver,
                                        SZFriendsDeviceChain *chain, NSString *code, NSData *joinerHash,
                                        NSData *approverHash, NSDate *now, SZFriendsDeviceChain **joined,
                                        NSData * (^tamper)(NSUInteger index, NSData *message)) {
    SZFJoinRun run = {0, NO, 0};
    NSUInteger index = 0;
    SZFriendsJoinAttempt *attempt = [joiner attemptWithCode:code handshakeHash:joinerHash];
    if (attempt == nil) {
        run.joiner = SZFriendsJoinStepFailed;
        return run;
    }
    NSData *message = tamper ? tamper(index++, attempt.codeMessage) : attempt.codeMessage;
    SZFriendsJoinEndReason ended = 0;
    SZFriendsJoinApproval *approval = [approver approvalForCodeMessage:message handshakeHash:approverHash
                                                               rootKey:chain.rootKey now:now ended:&ended];
    run.ended = ended;
    if (approval == nil) {
        if (ended != 0) run.joiner = [attempt receiveMessage:SZFriendsJoinEndedMessage(ended)].kind;
        return run;
    }
    message = tamper ? tamper(index++, approval.replyMessage) : approval.replyMessage;
    SZFriendsJoinStep *step = [attempt receiveMessage:message];
    run.joiner = step.kind;
    if (step.kind != SZFriendsJoinStepSend) {
        [approver abandonApproval:approval now:now];
        return run;
    }
    message = tamper ? tamper(index++, step.message) : step.message;
    SZFriendsJoinWelcome *welcome = [approver welcomeForConfirmMessage:message approval:approval chain:chain
                                                               profile:JoinProfileBytes()
                                                        friendsIDState:2
                                                                   now:now];
    run.welcomed = welcome != nil;
    if (welcome == nil) return run;
    for (NSData *part in welcome.parts) {
        step = [attempt receiveMessage:tamper ? tamper(index++, part) : part];
        run.joiner = step.kind;
    }
    if (step.kind == SZFriendsJoinStepJoined && joined != NULL) *joined = step.chain;
    return run;
}
