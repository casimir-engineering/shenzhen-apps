// Port prediction and candidate lines (SZFriendsNATPrediction.h).

#import "service/online/nat/SZFriendsNATPrediction.h"

#import "service/online/SZFriendsOnlineTransport.h"
#import "service/online/nat/SZFriendsNATClassifier.h"

#include <stdlib.h>

enum {
    kLowestPredictedPort = 1024, // NATs allocate from the dynamic and registered ranges, never the system ports
    // Local preferences: a router mapping is the surest server-reflexive address, a hole-punched one next, a
    // predicted one last (25 guesses should not crowd out what was measured).
    kPreferencePortMapping = 65535,
    kPreferencePredicted = 1000,
};

NSArray<NSNumber *> *SZFriendsNATPredictPorts(uint16_t reflexivePort, int32_t step,
                                              NSUInteger existingRemoteCandidates) {
    NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
    if (step == 0 || abs(step) > SZFriendsNATPredictableStepMax || reflexivePort == 0) return ports;
    if (existingRemoteCandidates >= SZFriendsOnlineRemoteCandidateMax) return ports;
    NSUInteger room = MIN((NSUInteger)SZFriendsOnlinePredictedCandidateMax,
                          (NSUInteger)SZFriendsOnlineRemoteCandidateMax - existingRemoteCandidates);
    int32_t port = reflexivePort;
    while (ports.count < room) {
        port += step;
        if (port < kLowestPredictedPort || port > 65535) break;
        [ports addObject:@(port)];
    }
    return ports;
}

NSArray<NSString *> *SZFriendsNATPredictedCandidates(SZFriendsNATEndpoint *reflexive, int32_t step,
                                                     NSUInteger existingRemoteCandidates) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSNumber *port in SZFriendsNATPredictPorts(reflexive.port, step, existingRemoteCandidates)) {
        [lines addObject:SZFriendsNATCandidateLine([reflexive endpointWithPort:port.unsignedShortValue],
                                                   SZFriendsNATCandidateTypeServerReflexive, NO,
                                                   kPreferencePredicted)];
    }
    return lines;
}

NSString *SZFriendsNATPortMappingCandidate(SZFriendsNATEndpoint *external) {
    return SZFriendsNATCandidateLine(external, SZFriendsNATCandidateTypeServerReflexive, NO, kPreferencePortMapping);
}

static NSString *TypeName(SZFriendsNATCandidateType type) {
    switch (type) {
    case SZFriendsNATCandidateTypeHost: return @"host";
    case SZFriendsNATCandidateTypeServerReflexive: return @"srflx";
    case SZFriendsNATCandidateTypePeerReflexive: return @"prflx";
    case SZFriendsNATCandidateTypeRelay: return @"relay";
    }
    return @"host";
}

static uint32_t TypePreference(SZFriendsNATCandidateType type) {
    switch (type) {
    case SZFriendsNATCandidateTypeHost: return 126;
    case SZFriendsNATCandidateTypePeerReflexive: return 110;
    case SZFriendsNATCandidateTypeServerReflexive: return 100;
    case SZFriendsNATCandidateTypeRelay: return 0;
    }
    return 0;
}

NSString *SZFriendsNATCandidateLine(SZFriendsNATEndpoint *endpoint, SZFriendsNATCandidateType type, BOOL tcp,
                                    uint16_t localPreference) {
    uint32_t priority = (TypePreference(type) << 24) | ((uint32_t)localPreference << 8) | (256 - 1);
    // The foundation groups candidates of one type, family and transport (RFC 8445 § 5.1.1.3).
    NSString *foundation = [NSString stringWithFormat:@"%@%@%c", TypeName(type), tcp ? @"t" : @"u",
                                                      endpoint.family == AF_INET6 ? '6' : '4'];
    NSMutableString *line = [NSMutableString stringWithFormat:@"candidate:%@ 1 %@ %u %@ %u typ %@", foundation,
                                                              tcp ? @"TCP" : @"UDP", priority, endpoint.host,
                                                              endpoint.port, TypeName(type)];
    if (type != SZFriendsNATCandidateTypeHost) {
        [line appendString:endpoint.family == AF_INET6 ? @" raddr :: rport 0" : @" raddr 0.0.0.0 rport 0"];
    }
    if (tcp) [line appendString:@" tcptype so"];
    return line;
}

@implementation SZFriendsNATCandidate

static BOOL ParseUnsigned(NSString *text, uint64_t maximum, uint64_t *value) {
    if (text.length == 0 || text.length > 10) return NO;
    uint64_t result = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
        result = result * 10 + (uint64_t)(c - '0');
    }
    if (result > maximum) return NO;
    *value = result;
    return YES;
}

+ (instancetype)candidateWithLine:(NSString *)line {
    if (line.length > 512) return nil;
    if ([line hasPrefix:@"a="]) line = [line substringFromIndex:2];
    if (![line hasPrefix:@"candidate:"]) return nil;
    NSArray<NSString *> *parts = [[line substringFromIndex:10] componentsSeparatedByString:@" "];
    if (parts.count < 8 || parts.count > 14 || parts[0].length == 0 || parts[0].length > 32) return nil;
    uint64_t component, priority, port;
    if (!ParseUnsigned(parts[1], 256, &component) || component != 1) return nil;
    BOOL tcp;
    if ([parts[2] caseInsensitiveCompare:@"UDP"] == NSOrderedSame) {
        tcp = NO;
    } else if ([parts[2] caseInsensitiveCompare:@"TCP"] == NSOrderedSame) {
        tcp = YES;
    } else {
        return nil;
    }
    if (!ParseUnsigned(parts[3], UINT32_MAX, &priority) || !ParseUnsigned(parts[5], 65535, &port) || port == 0) {
        return nil;
    }
    SZFriendsNATEndpoint *endpoint = [SZFriendsNATEndpoint endpointWithHost:parts[4] port:(uint16_t)port];
    if (endpoint == nil || ![parts[6] isEqualToString:@"typ"]) return nil;
    NSDictionary<NSString *, NSNumber *> *types = @{
        @"host" : @(SZFriendsNATCandidateTypeHost), @"srflx" : @(SZFriendsNATCandidateTypeServerReflexive),
        @"prflx" : @(SZFriendsNATCandidateTypePeerReflexive), @"relay" : @(SZFriendsNATCandidateTypeRelay)
    };
    NSNumber *type = types[parts[7]];
    if (type == nil) return nil;
    BOOL sawTCPType = NO, sawRelated = NO;
    for (NSUInteger i = 8; i < parts.count; i += 2) {
        if (i + 1 >= parts.count) return nil;
        NSString *key = parts[i], *value = parts[i + 1];
        if ([key isEqualToString:@"raddr"] && !sawRelated && i + 3 < parts.count &&
            [parts[i + 2] isEqualToString:@"rport"]) {
            uint64_t relatedPort;
            if ([SZFriendsNATEndpoint endpointWithHost:value port:0] == nil ||
                !ParseUnsigned(parts[i + 3], 65535, &relatedPort)) {
                return nil;
            }
            sawRelated = YES;
            i += 2;
        } else if ([key isEqualToString:@"tcptype"] && tcp && !sawTCPType) {
            if (![value isEqualToString:@"so"]) return nil;
            sawTCPType = YES;
        } else {
            return nil;
        }
    }
    if (tcp && !sawTCPType) return nil;
    SZFriendsNATCandidate *candidate = [[self alloc] initPrivate];
    candidate->_tcp = tcp;
    candidate->_type = (SZFriendsNATCandidateType)type.integerValue;
    candidate->_endpoint = endpoint;
    candidate->_priority = (uint32_t)priority;
    return candidate;
}

- (instancetype)initPrivate {
    return [super init];
}

@end
