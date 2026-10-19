// Fuzz target: candidate lines (SZFriendsNATPrediction.h), which the TCP path parses from the peer's signalling, and
// numeric addresses (SZFriendsNAT.h). Authenticated input, but a friend's helper is still not this one.

#import "service/online/nat/SZFriendsNATPrediction.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    @autoreleasepool {
        NSString *line = [[NSString alloc] initWithBytes:data length:size encoding:NSUTF8StringEncoding];
        if (line == nil) return 0;
        SZFriendsNATCandidate *candidate = [SZFriendsNATCandidate candidateWithLine:line];
        if (candidate != nil) {
            NSString *again = SZFriendsNATCandidateLine(candidate.endpoint, candidate.type, candidate.tcp, 1);
            if ([SZFriendsNATCandidate candidateWithLine:again] == nil) __builtin_trap(); // what we write, we read
        }
        (void)[SZFriendsNATEndpoint endpointWithHost:line port:1];
    }
    return 0;
}
