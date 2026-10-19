// Fuzz target: the PCP and NAT-PMP answer parsers (SZFriendsNATPCP.h), which read datagrams from the LAN's gateway
// before anyone is authenticated. The nonce and internal port expected are taken from the input itself where a MAP
// answer would carry them, so the fuzzer reaches the checks after them; the epoch check gets the parsed values.

#import "service/online/nat/SZFriendsNATPCP.h"

#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    uint8_t nonce[SZFriendsPCPNonceLength] = {0};
    uint16_t internal = 0;
    if (size >= 42) {
        memcpy(nonce, data + 24, sizeof nonce);
        internal = (uint16_t)((data[40] << 8) | data[41]);
    }
    SZFriendsPCPMapResponse map;
    SZFriendsNATEpoch epoch = {YES, 1000, 50};
    if (SZFriendsPCPParseAnswer(data, size, nonce, internal, &map) == SZFriendsPCPAnswerMap) {
        (void)SZFriendsNATEpochContinues(&epoch, map.epoch, 60 + (double)map.lifetime);
    }
    SZFriendsNATPMPResponse pmp;
    if (SZFriendsNATPMPParseExternalAddress(data, size, &pmp)) (void)SZFriendsNATEpochContinues(&epoch, pmp.epoch, 70);
    uint16_t pmpInternal = size >= 10 ? (uint16_t)((data[8] << 8) | data[9]) : 0;
    if (SZFriendsNATPMPParseMap(data, size, pmpInternal, &pmp)) (void)SZFriendsNATEpochContinues(&epoch, pmp.epoch, 80);
    return 0;
}
