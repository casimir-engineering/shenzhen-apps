// Unit tests of the pure parts: STUN against RFC 5769's vectors, PCP and NAT-PMP, the epoch check, address scopes,
// candidate lines and port prediction.

#import "SZFriendsNATTestSupport.h"

#import "service/online/SZFriendsOnlineTransport.h"
#import "service/online/nat/SZFriendsNATClassifier.h"
#import "service/online/nat/SZFriendsNATPCP.h"
#import "service/online/nat/SZFriendsNATPrediction.h"
#import "service/online/nat/SZFriendsNATStun.h"

#include <netinet/in.h>

static NSData *Hex(NSString *text) {
    NSMutableData *data = [NSMutableData data];
    NSString *clean = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsJoinedByString:@""];
    for (NSUInteger i = 0; i + 1 < clean.length; i += 2) {
        uint8_t byte = (uint8_t)strtoul([[clean substringWithRange:NSMakeRange(i, 2)] UTF8String], NULL, 16);
        [data appendBytes:&byte length:1];
    }
    return data;
}

// RFC 5769 § 2: short-term credential password, and the three samples (request, IPv4 and IPv6 responses).
static const char *kVectorPassword = "VOkJxbRl1RmTxUk/WvJxBt";
static NSString *const kVectorRequest = @"00010058 2112a442 b7e7a701 bc34d686 fa87dfae 80220010 5354554e 20746573"
                                        @"7420636c 69656e74 00240004 6e0001ff 80290008 932ff9b1 51263b36 00060009"
                                        @"6576746a 3a683676 59202020 00080014 9aeaa70c bfd8cb56 781ef2b5 b2d3f249"
                                        @"c1b571a2 80280004 e57a3bcf";
static NSString *const kVectorIPv4 = @"0101003c 2112a442 b7e7a701 bc34d686 fa87dfae 8022000b 74657374 20766563"
                                     @"746f7220 00200008 0001a147 e112a643 00080014 2b91f599 fd9e90c3 8c7489f9"
                                     @"2af9ba53 f06be7d7 80280004 c07d4c96";
static NSString *const kVectorIPv6 = @"01010048 2112a442 b7e7a701 bc34d686 fa87dfae 8022000b 74657374 20766563"
                                     @"746f7220 00200014 0002a147 0113a9fa a5d3f179 bc25f4b5 bed2b9d9 00080014"
                                     @"a382954e 4be67bf1 1784c97c 8292c275 bfe3ed41 80280004 c8fb0b4c";

static SZFriendsNATEndpoint *MappedOf(const SZFriendsStunMessage *message) {
    return [SZFriendsNATEndpoint endpointWithSockaddr:(const struct sockaddr *)&message->mappedAddress
                                              length:message->mappedAddressLength];
}

static void TestStunVectors(void) {
    const uint8_t *key = (const uint8_t *)kVectorPassword;
    size_t keyLength = strlen(kVectorPassword);
    SZFriendsStunMessage message;
    NSData *request = Hex(kVectorRequest);
    CHECK(SZFriendsStunParse(request.bytes, request.length, &message), "RFC 5769 sample request parses");
    CHECK(message.type == SZFriendsStunTypeBindingRequest && message.hasFingerprint && message.hasIntegrity);
    CHECK(message.usernameLength == 9 && memcmp(message.username, "evtj:h6vY", 9) == 0);
    CHECK(SZFriendsStunCheckIntegrity(request.bytes, request.length, &message, key, keyLength));
    CHECK(!SZFriendsStunCheckIntegrity(request.bytes, request.length, &message, (const uint8_t *)"wrong", 5));

    NSData *v4 = Hex(kVectorIPv4);
    CHECK(SZFriendsStunParse(v4.bytes, v4.length, &message) && message.type == SZFriendsStunTypeBindingSuccess);
    CHECK([MappedOf(&message) isEqual:[SZFriendsNATEndpoint endpointWithHost:@"192.0.2.1" port:32853]]);
    CHECK(SZFriendsStunCheckIntegrity(v4.bytes, v4.length, &message, key, keyLength));
    NSData *v6 = Hex(kVectorIPv6);
    CHECK(SZFriendsStunParse(v6.bytes, v6.length, &message));
    CHECK([MappedOf(&message) isEqual:[SZFriendsNATEndpoint endpointWithHost:@"2001:db8:1234:5678:11:2233:4455:6677"
                                                                       port:32853]]);
    CHECK(SZFriendsStunCheckIntegrity(v6.bytes, v6.length, &message, key, keyLength));

    // Any flipped bit fails the FINGERPRINT, so the message is not parsed at all.
    for (NSUInteger i = 0; i < request.length; i += 7) {
        NSMutableData *flipped = [request mutableCopy];
        ((uint8_t *)flipped.mutableBytes)[i] ^= 0x10;
        CHECK(!SZFriendsStunParse(flipped.bytes, flipped.length, &message), "flipped byte %lu", (unsigned long)i);
    }
}

static void TestStunWriteAndStrictness(void) {
    uint8_t transaction[12], bytes[SZFriendsStunMessageMax];
    SZFriendsStunRandomTransaction(transaction);
    const uint8_t key[] = "0123456789abcdefghijklmnop";
    const char *longest = "ABCDEFGHIJKLMNOP:abcdefghijklmnop";
    size_t length = SZFriendsStunWriteBindingRequest(bytes, sizeof bytes, transaction, longest, key, sizeof key - 1);
    CHECK(length == 92, "the largest probe is 92 bytes, under ADR 0011's 100 (got %zu)", length);
    SZFriendsStunMessage message;
    CHECK(SZFriendsStunParse(bytes, length, &message) && message.hasIntegrity && message.hasFingerprint);
    CHECK(SZFriendsStunCheckIntegrity(bytes, length, &message, key, sizeof key - 1));
    CHECK(SZFriendsStunWriteBindingRequest(bytes, sizeof bytes, transaction, "ABCDEFGHIJKLMNOPQ:abcdefghijklmnop",
                                           key, sizeof key - 1) == 0, "usernames over 33 bytes are refused");
    CHECK(SZFriendsStunWriteBindingRequest(bytes, 40, transaction, NULL, NULL, 0) == 28, "plain request");
    CHECK(SZFriendsStunWriteBindingRequest(bytes, 27, transaction, NULL, NULL, 0) == 0, "too small a buffer");

    for (NSString *host in @[ @"198.51.100.7", @"2001:db8::42" ]) {
        SZFriendsNATEndpoint *mapped = [SZFriendsNATEndpoint endpointWithHost:host port:61000];
        struct sockaddr_storage storage;
        [mapped getSockaddr:&storage];
        length = SZFriendsStunWriteBindingSuccess(bytes, sizeof bytes, transaction, (struct sockaddr *)&storage, key,
                                                  sizeof key - 1);
        CHECK(SZFriendsStunParse(bytes, length, &message) && [MappedOf(&message) isEqual:mapped], "%@", host);
        CHECK(memcmp(message.transaction, transaction, 12) == 0);
        CHECK(SZFriendsStunCheckIntegrity(bytes, length, &message, key, sizeof key - 1));
    }

    // Malformed: each must be refused whole.
    length = SZFriendsStunWriteBindingRequest(bytes, sizeof bytes, transaction, NULL, NULL, 0);
    CHECK(!SZFriendsStunParse(bytes, length - 1, &message), "length field disagrees with the datagram");
    uint8_t copy[64];
    memcpy(copy, bytes, length);
    copy[0] |= 0x80;
    CHECK(!SZFriendsStunParse(copy, length, &message), "top bits set");
    memcpy(copy, bytes, length);
    copy[4] ^= 1;
    CHECK(!SZFriendsStunParse(copy, length, &message), "wrong magic cookie");
    const uint8_t overrun[] = {0x01, 0x01, 0x00, 0x08, 0x21, 0x12, 0xa4, 0x42, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
                               0x00, 0x20, 0x00, 0x10, 0, 1, 0, 0};
    CHECK(!SZFriendsStunParse(overrun, sizeof overrun, &message), "attribute longer than the message");
    const uint8_t badFamily[] = {0x01, 0x01, 0x00, 0x0c, 0x21, 0x12, 0xa4, 0x42, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
                                 12, 0x00, 0x20, 0x00, 0x08, 0x00, 0x03, 0, 0, 0, 0, 0, 0};
    CHECK(!SZFriendsStunParse(badFamily, sizeof badFamily, &message), "address family 3");
    const uint8_t noAttributes[] = {0x01, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
                                    12};
    CHECK(SZFriendsStunParse(noAttributes, sizeof noAttributes, &message) && !message.hasMappedAddress);
    uint8_t huge[SZFriendsStunMessageMax + 4] = {0};
    CHECK(!SZFriendsStunParse(huge, sizeof huge, &message), "longer than SZFriendsStunMessageMax");

    CHECK(SZFriendsStunFramedLength(bytes, 10) == 0, "header incomplete");
    CHECK(SZFriendsStunFramedLength(bytes, length - 1) == 0, "body incomplete");
    CHECK(SZFriendsStunFramedLength(bytes, length) == length);
    const uint8_t http[] = "HTTP/1.1 200 OK\r\n";
    CHECK(SZFriendsStunFramedLength(http, sizeof http - 1) == SIZE_MAX, "not STUN");
}

static NSData *PCPAnswer(const uint8_t nonce[12], uint8_t result, uint32_t lifetime, uint32_t epoch, uint16_t internal,
                         uint16_t external, NSUInteger optionBytes) {
    NSMutableData *data = [NSMutableData dataWithLength:60 + optionBytes];
    uint8_t *b = data.mutableBytes;
    b[0] = 2;
    b[1] = 0x81;
    b[3] = result;
    b[4] = (uint8_t)(lifetime >> 24), b[5] = (uint8_t)(lifetime >> 16), b[6] = (uint8_t)(lifetime >> 8);
    b[7] = (uint8_t)lifetime;
    b[8] = (uint8_t)(epoch >> 24), b[9] = (uint8_t)(epoch >> 16), b[10] = (uint8_t)(epoch >> 8), b[11] = (uint8_t)epoch;
    memcpy(b + 24, nonce, 12);
    b[36] = 17;
    b[40] = (uint8_t)(internal >> 8), b[41] = (uint8_t)internal;
    b[42] = (uint8_t)(external >> 8), b[43] = (uint8_t)external;
    b[54] = b[55] = 0xff;
    b[56] = 203, b[57] = 0, b[58] = 113, b[59] = 9;
    if (optionBytes >= 4) b[62] = 0, b[63] = (uint8_t)(optionBytes - 4); // one option filling the rest
    return data;
}

static void TestPCP(void) {
    uint8_t nonce[12], request[60], client[16] = {0};
    arc4random_buf(nonce, sizeof nonce);
    client[10] = client[11] = 0xff, client[12] = 192, client[13] = 168, client[14] = 1, client[15] = 20;
    CHECK(SZFriendsPCPWriteMapRequest(request, nonce, client, 50000, 50000, 7200) == 60);
    CHECK(request[0] == 2 && request[1] == 1 && request[4] == 0 && request[7] == (7200 & 0xff));
    CHECK(memcmp(request + 8, client, 16) == 0 && memcmp(request + 24, nonce, 12) == 0 && request[36] == 17);
    CHECK(request[40] == (50000 >> 8) && request[42] == (50000 >> 8) && request[54] == 0xff && request[55] == 0xff,
          "suggested external address is ::ffff:0.0.0.0 for IPv4");

    SZFriendsPCPMapResponse response;
    NSData *answer = PCPAnswer(nonce, 0, 7200, 100, 50000, 50001, 0);
    CHECK(SZFriendsPCPParseAnswer(answer.bytes, answer.length, nonce, 50000, &response) == SZFriendsPCPAnswerMap);
    CHECK(response.result == 0 && response.lifetime == 7200 && response.epoch == 100 && response.externalPort == 50001);
    answer = PCPAnswer(nonce, 0, 7200, 100, 50000, 50001, 8);
    CHECK(SZFriendsPCPParseAnswer(answer.bytes, answer.length, nonce, 50000, &response) == SZFriendsPCPAnswerMap,
          "a well-formed option is walked and ignored");
    NSMutableData *badOption = [PCPAnswer(nonce, 0, 7200, 100, 50000, 50001, 8) mutableCopy];
    ((uint8_t *)badOption.mutableBytes)[63] = 40;
    CHECK(SZFriendsPCPParseAnswer(badOption.bytes, badOption.length, nonce, 50000, &response) ==
          SZFriendsPCPAnswerInvalid, "option longer than the message");
    uint8_t otherNonce[12] = {0};
    CHECK(SZFriendsPCPParseAnswer(answer.bytes, answer.length, otherNonce, 50000, &response) ==
          SZFriendsPCPAnswerInvalid, "someone else's nonce");
    CHECK(SZFriendsPCPParseAnswer(answer.bytes, answer.length, nonce, 50002, &response) == SZFriendsPCPAnswerInvalid);
    CHECK(SZFriendsPCPParseAnswer(answer.bytes, answer.length - 2, nonce, 50000, &response) ==
          SZFriendsPCPAnswerInvalid, "not a multiple of four");
    answer = PCPAnswer(nonce, 0, 7200, 100, 50000, 0, 0);
    CHECK(SZFriendsPCPParseAnswer(answer.bytes, answer.length, nonce, 50000, &response) == SZFriendsPCPAnswerInvalid,
          "a mapping to port 0");
    answer = PCPAnswer(nonce, SZFriendsPCPResultNotAuthorized, 0, 100, 50000, 0, 0);
    CHECK(SZFriendsPCPParseAnswer(answer.bytes, answer.length, nonce, 50000, &response) == SZFriendsPCPAnswerMap &&
          response.result == SZFriendsPCPResultNotAuthorized, "a refusal is an answer");
    const uint8_t natpmpRefusal[] = {0, 0x81, 0, 1, 0, 0, 0, 7};
    CHECK(SZFriendsPCPParseAnswer(natpmpRefusal, sizeof natpmpRefusal, nonce, 50000, &response) ==
          SZFriendsPCPAnswerUnsupportedVersion);
    const uint8_t natpmpOther[] = {0, 0x81, 0, 3, 0, 0, 0, 7};
    CHECK(SZFriendsPCPParseAnswer(natpmpOther, sizeof natpmpOther, nonce, 50000, &response) ==
          SZFriendsPCPAnswerInvalid, "only result 1 means fall back");

    uint8_t natpmp[12];
    CHECK(SZFriendsNATPMPWriteExternalAddressRequest(natpmp) == 2 && natpmp[0] == 0 && natpmp[1] == 0);
    CHECK(SZFriendsNATPMPWriteMapRequest(natpmp, 50000, 50000, 7200) == 12 && natpmp[1] == 1 && natpmp[4] == 0xc3);
    SZFriendsNATPMPResponse pmp;
    const uint8_t external[] = {0, 128, 0, 0, 0, 0, 1, 0, 203, 0, 113, 9};
    CHECK(SZFriendsNATPMPParseExternalAddress(external, sizeof external, &pmp) && pmp.result == 0 &&
          pmp.epoch == 256 && pmp.externalAddress[0] == 203);
    CHECK(!SZFriendsNATPMPParseExternalAddress(external, 11, &pmp), "a success must be whole");
    const uint8_t map[] = {0, 129, 0, 0, 0, 0, 1, 0, 0xc3, 0x50, 0xc3, 0x51, 0, 0, 0x1c, 0x20};
    CHECK(SZFriendsNATPMPParseMap(map, sizeof map, 50000, &pmp) && pmp.externalPort == 50001 && pmp.lifetime == 7200);
    CHECK(!SZFriendsNATPMPParseMap(map, sizeof map, 50002, &pmp), "another internal port");
    CHECK(!SZFriendsNATPMPParseMap(map, 17, 50000, &pmp) && !SZFriendsNATPMPParseExternalAddress(map, 16, &pmp));
    const uint8_t refused[] = {0, 129, 0, 2, 0, 0, 1, 0};
    CHECK(SZFriendsNATPMPParseMap(refused, sizeof refused, 50000, &pmp) && pmp.result == 2, "a short refusal");
}

static void TestEpoch(void) {
    SZFriendsNATEpoch epoch = {0};
    CHECK(SZFriendsNATEpochContinues(&epoch, 1000, 50), "the first answer");
    CHECK(SZFriendsNATEpochContinues(&epoch, 1100, 150), "both clocks moved 100 s");
    CHECK(SZFriendsNATEpochContinues(&epoch, 1099, 150), "one second backwards is within the slack");
    CHECK(!SZFriendsNATEpochContinues(&epoch, 10, 160), "the router restarted");
    CHECK(SZFriendsNATEpochContinues(&epoch, 110, 260));
    CHECK(!SZFriendsNATEpochContinues(&epoch, 120, 1260), "our clock moved 1000 s and the router's 10");
    CHECK(SZFriendsNATEpochContinues(&epoch, 130, 1270));
    CHECK(!SZFriendsNATEpochContinues(&epoch, 5130, 1280), "the router's moved 5000 s and ours 10");
}

static void TestScopes(void) {
    NSDictionary<NSString *, NSNumber *> *cases = @{
        @"0.0.0.0" : @(SZFriendsNATAddressScopeUnspecified), @"127.3.2.1" : @(SZFriendsNATAddressScopeLoopback),
        @"169.254.9.9" : @(SZFriendsNATAddressScopeLinkLocal),
        @"239.255.255.250" : @(SZFriendsNATAddressScopeMulticast),
        @"255.255.255.255" : @(SZFriendsNATAddressScopeMulticast), @"10.1.2.3" : @(SZFriendsNATAddressScopePrivate),
        @"172.31.0.1" : @(SZFriendsNATAddressScopePrivate), @"172.32.0.1" : @(SZFriendsNATAddressScopeGlobal),
        @"192.168.1.1" : @(SZFriendsNATAddressScopePrivate), @"100.64.0.1" : @(SZFriendsNATAddressScopeShared),
        @"100.128.0.1" : @(SZFriendsNATAddressScopeGlobal), @"192.0.2.1" : @(SZFriendsNATAddressScopeReserved),
        @"198.18.0.1" : @(SZFriendsNATAddressScopeReserved), @"240.0.0.1" : @(SZFriendsNATAddressScopeReserved),
        @"8.8.8.8" : @(SZFriendsNATAddressScopeGlobal), @"::" : @(SZFriendsNATAddressScopeUnspecified),
        @"::1" : @(SZFriendsNATAddressScopeLoopback), @"fe80::1" : @(SZFriendsNATAddressScopeLinkLocal),
        @"ff02::1" : @(SZFriendsNATAddressScopeMulticast), @"fd00::1" : @(SZFriendsNATAddressScopePrivate),
        @"2001:db8::1" : @(SZFriendsNATAddressScopeReserved), @"2001::1" : @(SZFriendsNATAddressScopeReserved),
        @"2002::1" : @(SZFriendsNATAddressScopeReserved), @"64:ff9b::1.2.3.4" : @(SZFriendsNATAddressScopeReserved),
        @"240e:1::1" : @(SZFriendsNATAddressScopeGlobal), @"2400:cb00::1" : @(SZFriendsNATAddressScopeGlobal),
        @"::ffff:10.0.0.1" : @(SZFriendsNATAddressScopePrivate),
    };
    for (NSString *host in cases) {
        SZFriendsNATEndpoint *endpoint = [SZFriendsNATEndpoint endpointWithHost:host port:1];
        CHECK(endpoint.scope == cases[host].integerValue, "%@ is scope %ld", host, (long)endpoint.scope);
    }
    CHECK([SZFriendsNATEndpoint endpointWithHost:@"::ffff:10.0.0.1" port:1].family == AF_INET, "mapped is IPv4");
    CHECK([SZFriendsNATEndpoint endpointWithHost:@"fe80::1%lo0" port:1].scopeID != 0);
    for (NSString *bad in @[ @"example.com", @"1.2.3", @"2001:db8::1%en0", @"", @"1.2.3.4%en0", @"fe80::1%nosuch" ]) {
        CHECK([SZFriendsNATEndpoint endpointWithHost:bad port:1] == nil, "%@ refused", bad);
    }
    SZFriendsNATEndpoint *a = [SZFriendsNATEndpoint endpointWithHost:@"203.0.113.5" port:7];
    CHECK([a isEqual:[SZFriendsNATEndpoint endpointWithHost:@"203.0.113.5" port:7]]);
    CHECK(![a isEqual:[a endpointWithPort:8]]);
    CHECK([a hasSameAddressAs:[a endpointWithPort:8]]);
    CHECK(SZFriendsNATOwnAddresses().count > 0, "this Mac has at least loopback");
}

static void TestPredictionAndCandidates(void) {
    NSArray<NSNumber *> *ports = SZFriendsNATPredictPorts(40000, 2, 0);
    CHECK(ports.count == SZFriendsOnlinePredictedCandidateMax && ports.firstObject.intValue == 40002 &&
          ports.lastObject.intValue == 40050, "25 ports continuing in steps of 2");
    CHECK(SZFriendsNATPredictPorts(40000, 1, 10).count == 20, "30 remote candidates in all");
    CHECK(SZFriendsNATPredictPorts(40000, 1, 30).count == 0 && SZFriendsNATPredictPorts(40000, 0, 0).count == 0);
    CHECK(SZFriendsNATPredictPorts(40000, SZFriendsNATPredictableStepMax + 1, 0).count == 0, "a random NAT");
    CHECK(SZFriendsNATPredictPorts(65530, 1, 0).count == 5, "never past 65535");
    ports = SZFriendsNATPredictPorts(1030, -3, 0);
    CHECK(ports.count == 2 && ports.lastObject.intValue == 1024, "downwards, never below 1024");

    SZFriendsNATEndpoint *reflexive = [SZFriendsNATEndpoint endpointWithHost:@"203.0.113.9" port:40000];
    NSArray<NSString *> *lines = SZFriendsNATPredictedCandidates(reflexive, 1, 0);
    CHECK(lines.count == 25);
    SZFriendsNATCandidate *first = [SZFriendsNATCandidate candidateWithLine:lines.firstObject];
    CHECK(first != nil && !first.tcp && first.type == SZFriendsNATCandidateTypeServerReflexive &&
          [first.endpoint isEqual:[reflexive endpointWithPort:40001]], "%@", lines.firstObject);
    NSString *mapping = SZFriendsNATPortMappingCandidate([SZFriendsNATEndpoint endpointWithHost:@"2400:cb00::7"
                                                                                           port:5000]);
    CHECK([mapping hasSuffix:@"typ srflx raddr :: rport 0"], "%@", mapping);
    CHECK([SZFriendsNATCandidate candidateWithLine:mapping].priority > first.priority, "a mapping beats a guess");

    NSString *tcp = SZFriendsNATCandidateLine([SZFriendsNATEndpoint endpointWithHost:@"240e::5" port:6000],
                                              SZFriendsNATCandidateTypeHost, YES, 65535);
    SZFriendsNATCandidate *parsed = [SZFriendsNATCandidate candidateWithLine:[@"a=" stringByAppendingString:tcp]];
    CHECK(parsed.tcp && parsed.type == SZFriendsNATCandidateTypeHost && parsed.endpoint.port == 6000, "%@", tcp);
    NSArray<NSString *> *refused = @[
        @"candidate:1 1 TCP 1 240e::5 6000 typ host", @"candidate:1 1 TCP 1 240e::5 6000 typ host tcptype active",
        @"candidate:1 2 UDP 1 1.2.3.4 6000 typ host", @"candidate:1 1 UDP 1 abc.local 6000 typ host",
        @"candidate:1 1 UDP 1 1.2.3.4 0 typ host", @"candidate:1 1 UDP 1 1.2.3.4 6000 typ host extra",
        @"candidate:1 1 SCTP 1 1.2.3.4 6000 typ host", @"candidate:1 1 UDP 1 1.2.3.4 70000 typ host",
        @"candidate:1 1 UDP 1 1.2.3.4 6000 typ bogus", @"1 1 UDP 1 1.2.3.4 6000 typ host"
    ];
    for (NSString *bad in refused) {
        CHECK([SZFriendsNATCandidate candidateWithLine:bad] == nil, "%@ refused", bad);
    }
    SZFriendsNATClassification *sequential = [SZFriendsNATClassification
        classificationWithPrimary:[SZFriendsNATEndpoint endpointWithHost:@"203.0.113.9" port:40000]
                        secondary:[SZFriendsNATEndpoint endpointWithHost:@"203.0.113.9" port:39998]];
    CHECK(sequential.natClass == SZFriendsNATClassPerDestination && sequential.step == -2 && sequential.predictable);
}

void SZFTestCodecs(void) {
    TestStunVectors();
    TestStunWriteAndStrictness();
    TestPCP();
    TestEpoch();
    TestScopes();
    TestPredictionAndCandidates();
}
