// Port prediction for a per-destination NAT, and the candidate lines the NAT techniques hand to the transport
// (ADR 0011 § Port prediction; SZFriendsOnlineTransport.h, -addRemoteCandidate:technique: and
// -addLocalCandidate:technique:).
//
// The hard side reports the server-reflexive port of its connection's socket and its class's step (both from the
// classifier, through the authenticated signalling); the easy side adds up to SZFriendsOnlinePredictedCandidateMax
// candidates continuing from that port in that step, fewer when the connection's other remote candidates already
// take part of libjuice's SZFriendsOnlineRemoteCandidateMax. The prediction is the hard NAT's next mappings: its
// mapping toward the easy side is a new one, made after the mapping the host saw.

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

// Ports reflexivePort + step, + 2 x step, ... within 1024 to 65535, at most
// MIN(SZFriendsOnlinePredictedCandidateMax, SZFriendsOnlineRemoteCandidateMax - existingRemoteCandidates). Empty
// for a step of 0 or one beyond SZFriendsNATPredictableStepMax: a NAT that maps at random has nothing to predict.
NSArray<NSNumber *> *SZFriendsNATPredictPorts(uint16_t reflexivePort, int32_t step,
                                              NSUInteger existingRemoteCandidates);

// The predicted candidates themselves: the hard side's public address at each predicted port, as RFC 8839
// server-reflexive candidates, for -addRemoteCandidate:technique: with SZFriendsOnlineTechniquePredictedPort.
NSArray<NSString *> *SZFriendsNATPredictedCandidates(SZFriendsNATEndpoint *reflexive, int32_t step,
                                                     NSUInteger existingRemoteCandidates);

// A router port mapping as a local candidate for the peer (-addLocalCandidate:technique: with
// SZFriendsOnlineTechniquePortMapping): server-reflexive, preferred over hole-punched ones. Its related address is
// 0.0.0.0 port 0 (or :: for IPv6), as browsers write it, so no private address travels with it.
NSString *SZFriendsNATPortMappingCandidate(SZFriendsNATEndpoint *external);

#pragma mark - Candidate lines (RFC 8839, RFC 6544)

typedef NS_ENUM(NSInteger, SZFriendsNATCandidateType) {
    SZFriendsNATCandidateTypeHost = 1,
    SZFriendsNATCandidateTypeServerReflexive = 2,
    SZFriendsNATCandidateTypePeerReflexive = 3,
    SZFriendsNATCandidateTypeRelay = 4,
};

@interface SZFriendsNATCandidate : NSObject
@property(nonatomic, readonly) BOOL tcp;                   // TCP (tcptype so), else UDP
@property(nonatomic, readonly) SZFriendsNATCandidateType type;
@property(nonatomic, readonly) SZFriendsNATEndpoint *endpoint;
@property(nonatomic, readonly) uint32_t priority;
// Strict: "candidate:<foundation> 1 <UDP|TCP> <priority> <numeric address> <port> typ <type>", then optional
// "raddr <address> rport <port>", and for TCP "tcptype so" (the only TCP kind the TCP path dials); with or without
// a leading "a=". Names (mDNS or DNS) and anything else are refused. Nil when it does not parse.
+ (nullable instancetype)candidateWithLine:(NSString *)line;
- (instancetype)init NS_UNAVAILABLE;
@end

// One candidate line for this side. TCP lines get "tcptype so". Server-reflexive lines carry raddr 0.0.0.0 (or ::)
// rport 0. The priority follows RFC 8445 § 5.1.2 with `localPreference` (0 to 65535) separating techniques.
NSString *SZFriendsNATCandidateLine(SZFriendsNATEndpoint *endpoint, SZFriendsNATCandidateType type, BOOL tcp,
                                    uint16_t localPreference);

NS_ASSUME_NONNULL_END
