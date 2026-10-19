// friends-nat-emulator-check, second half (SZFNATMatrix.h): the real online driver through every pair of NAT types,
// what each pair must show, and the matrix it writes (docs/punching-matrix.md when asked to).
//
// Usage: SZFNATMatrix <szfnat-peer> <server/friends directory> <stun-host.mjs> <matrix .md> [a second copy]

#import "SZFNATMatrix.h"

#include <sys/resource.h>

// Six common behaviours (RFC 4787 terms). Mappings last 120 s idle, longer than any pair; no pair shares a NAT, so
// hairpinning stays off (szfnat_tests.c covers it).
static const SZFNATType kTypes[] = {
    {"full cone", "endpoint-independent mapping and filtering",
     {SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ENDPOINT_INDEPENDENT, SZFNAT_PORTS_SEQUENTIAL, 120, 0, 0}},
    {"restricted cone", "endpoint-independent mapping, address-dependent filtering",
     {SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_ADDRESS_DEPENDENT, SZFNAT_PORTS_SEQUENTIAL, 120, 0, 0}},
    {"port-restricted", "endpoint-independent mapping, address- and port-dependent filtering",
     {SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_PORT_DEPENDENT, SZFNAT_PORTS_SEQUENTIAL, 120, 0, 0}},
    {"port-restr. no TCP",
     "as port-restricted, but its firewall drops a SYN that crosses its own: no TCP simultaneous open",
     {SZFNAT_MAP_ENDPOINT_INDEPENDENT, SZFNAT_FILTER_PORT_DEPENDENT, SZFNAT_PORTS_SEQUENTIAL, 120, 0, 1}},
    {"address-dependent", "address-dependent mapping and filtering",
     {SZFNAT_MAP_ADDRESS_DEPENDENT, SZFNAT_FILTER_ADDRESS_DEPENDENT, SZFNAT_PORTS_SEQUENTIAL, 120, 0, 0}},
    {"symmetric, seq.", "address- and port-dependent mapping and filtering, each new port the next one",
     {SZFNAT_MAP_PORT_DEPENDENT, SZFNAT_FILTER_PORT_DEPENDENT, SZFNAT_PORTS_SEQUENTIAL, 120, 0, 0}},
    {"symmetric, random", "address- and port-dependent mapping and filtering, each new port random",
     {SZFNAT_MAP_PORT_DEPENDENT, SZFNAT_FILTER_PORT_DEPENDENT, SZFNAT_PORTS_RANDOM, 120, 0, 0}},
};
enum { kTypeCount = sizeof kTypes / sizeof kTypes[0], kPortRestricted = 2, kNoCrossing = 3, kSequential = 5,
       kRandom = 6 };
static const NSUInteger kParallelPairs = 3;

// What a pair must show but the code does not do yet, and why. Such a pair is reported, not failed; when it starts
// to pass, the suite says so, and the entry goes. None today; the entry with no reason only keeps the array legal C.
static const struct {
    NSUInteger offerer, answerer;
    const char *why;
} kKnownGaps[] = {
    {0, 0, NULL},
};

static const char *KnownGap(NSUInteger offerer, NSUInteger answerer) {
    for (size_t i = 0; i < sizeof kKnownGaps / sizeof kKnownGaps[0]; i++) {
        if (kKnownGaps[i].offerer == offerer && kKnownGaps[i].answerer == answerer) return kKnownGaps[i].why;
    }
    return NULL;
}

// SZFriendsOnlineTechnique, as the matrix names them.
static NSString *TechniqueName(NSInteger technique) {
    switch (technique) {
    case 1: return @"global IPv6";
    case 2: return @"private address";
    case 3: return @"hole punching";
    case 4: return @"hole punching (peer-reflexive)";
    case 5: return @"router port mapping";
    case 6: return @"port prediction";
    case 7: return @"birthday probing";
    case 8: return @"TCP simultaneous open";
    case 9: return @"relay";
    default: return @"none";
    }
}

static BOOL Symmetric(NSUInteger type) {
    return type == kSequential || type == kRandom;
}

// Endpoint-independent mapping: the cones, with or without TCP crossings.
static BOOL Cone(NSUInteger type) {
    return type <= kNoCrossing;
}

static BOOL PortRestricted(NSUInteger type) {
    return type == kPortRestricted || type == kNoCrossing;
}

// What a pair must show, or nil when the matrix only records it. `relay`: coturn runs, so the relay must carry it.
static NSString *Expected(NSUInteger offerer, NSUInteger answerer, BOOL relay,
                          BOOL (^_Nullable *check)(SZFNATOutcome *)) {
    BOOL portRestricted = PortRestricted(offerer) || PortRestricted(answerer);
    NSUInteger other = PortRestricted(offerer) ? answerer : offerer;
    if (Cone(offerer) && Cone(answerer)) {
        // TCP simultaneous open counts as punching too, unless a NAT drops crossing SYNs: then UDP must do it.
        BOOL udp = offerer == kNoCrossing || answerer == kNoCrossing;
        *check = ^BOOL(SZFNATOutcome *o) {
            BOOL punched = o.technique == 3 || o.technique == 4 || (!udp && o.technique == 8);
            return o.direct && !o.relayRequested && punched;
        };
        return udp ? @"UDP punching" : @"punching";
    }
    if (portRestricted && other == kSequential) {
        *check = ^BOOL(SZFNATOutcome *o) { return o.direct && o.technique == 6; };
        return @"port prediction";
    }
    if (portRestricted && other == kRandom) {
        // Within the hard-NAT budget: direct before the order would ask for the relay (5 s + 12 s).
        *check = ^BOOL(SZFNATOutcome *o) {
            return o.direct && o.technique == 7 && !o.relayRequested && o.elapsed < 17.0;
        };
        return @"birthday probing";
    }
    if ((Cone(offerer) && Symmetric(answerer)) || (Symmetric(offerer) && Cone(answerer))) {
        *check = ^BOOL(SZFNATOutcome *o) { return o.direct; };
        return @"direct";
    }
    if (Symmetric(offerer) && Symmetric(answerer)) {
        *check = ^BOOL(SZFNATOutcome *o) { return !o.direct && o.relayRequested && (!relay || o.relayed); };
        return relay ? @"relay" : @"relay asked";
    }
    *check = nil;
    return nil;
}

static NSString *Seconds(double seconds) {
    return seconds < 0 ? @"–" : [NSString stringWithFormat:seconds < 1 ? @"%.2f s" : @"%.1f s", seconds];
}

static NSString *Connected(SZFNATOutcome *o) {
    if (o.problem) return [NSString stringWithFormat:@"did not run: %@", o.problem];
    if (o.direct) return TechniqueName(o.technique);
    return o.relayed ? @"relay" : @"nothing direct";
}

static NSString *ClassLetter(NSInteger natClass) {
    return natClass == 1 ? @"I" : natClass == 2 ? @"D" : @"?";
}

// Prose wrapped at 120 columns, as every Friends document is; `indent` starts the continuation lines.
static NSString *Wrapped(NSString *text, NSString *first, NSString *indent) {
    NSMutableString *out = [NSMutableString string], *line = [first mutableCopy];
    BOOL empty = YES;
    for (NSString *word in [text componentsSeparatedByString:@" "]) {
        if (word.length == 0) continue;
        if (!empty && line.length + 1 + word.length > 120) {
            [out appendFormat:@"%@\n", line];
            line = [indent mutableCopy];
            empty = YES;
        }
        if (!empty) [line appendString:@" "];
        [line appendString:word];
        empty = NO;
    }
    [out appendFormat:@"%@\n", line];
    return out;
}

static NSString *Matrix(NSArray<SZFNATOutcome *> *outcomes, NSArray *pairs, BOOL relay) {
    NSMutableString *md = [NSMutableString stringWithString:@"# Hole punching through emulated NATs\n\n"];
    [md appendString:Wrapped(@"Generated by `friends-nat-emulator-check` (`friends/tests/nat-emulator/`); do not edit "
                             @"by hand. To regenerate it, run `make -C portable friends-nat-emulator-check "
                             @"FRIENDS_NAT_MATRIX_DOC=1`.", @"", @"")];
    NSString *relayText =
        relay ? @"The relay is a local coturn at the 5 Mbit/s cap."
              : @"No coturn ran, so where only the relay could help, the matrix shows when the driver asked for it; "
                @"set `FRIENDS_TEST_COTURN` to see it connect.";
    [md appendFormat:@"\n%@", Wrapped([@"Two real online drivers, each behind its own userspace NAT on loopback, reach "
                                       @"each other as friends: the transport, the order with its provisional "
                                       @"budgets (5 s of plain checks, 12 s more when exactly one side maps per "
                                       @"destination) and every NAT technique, as the helper runs them in loopback "
                                       @"test mode. STUN comes from the host service's own responder on two ports. "
                                       stringByAppendingString:relayText], @"", @"")];
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *offererPeer = env[@"SZFNAT_OFFERER_PEER"], *answererPeer = env[@"SZFNAT_ANSWERER_PEER"];
    if (offererPeer.length > 0 || answererPeer.length > 0) {
        NSString *rust = @"the Rust core (`tools/nat-peer`)", *helper = @"the helper";
        NSString *who = [NSString stringWithFormat:@"Mixed pairs: the offerer runs %@ and the answerer %@.",
                                                   offererPeer.length ? rust : helper,
                                                   answererPeer.length ? rust : helper];
        [md appendFormat:@"\n%@", Wrapped(who, @"", @"")];
    }
    [md appendFormat:@"\n%@", Wrapped(@"The offerer starts the attempt. *Classes* are what each side measured with the "
                                      @"two-port classifier: I for endpoint-independent, D for per destination. "
                                      @"*Time* runs from the offerer starting its attempt to its first stream, which "
                                      @"then carried a 16-byte echo both ways. *Relay asked* runs from the same start "
                                      @"to the offerer's order asking for the relay, once the direct budgets ran out.",
                                      @"", @"")];
    [md appendString:@"\n| Offerer | Answerer | Classes | Connected by | Time | Relay asked | Must show |\n"];
    [md appendString:@"|---|---|---|---|---|---|---|\n"];
    NSMutableString *gaps = [NSMutableString string];
    for (NSUInteger i = 0; i < pairs.count; i++) {
        NSUInteger a = [pairs[i][0] unsignedIntegerValue], b = [pairs[i][1] unsignedIntegerValue];
        SZFNATOutcome *o = outcomes[i];
        BOOL (^check)(SZFNATOutcome *) = nil;
        NSString *must = Expected(a, b, relay, &check) ?: @"–";
        const char *gap = KnownGap(a, b);
        if (gap != NULL && !(check && check(o))) {
            must = [must stringByAppendingString:@" (gap)"];
            NSString *item = [NSString stringWithFormat:@"%s offerer, %s answerer: %s.", kTypes[a].name,
                                                        kTypes[b].name, gap];
            [gaps appendString:Wrapped(item, @"- ", @"  ")];
        }
        [md appendFormat:@"| %s | %s | %@ / %@ | %@ | %@ | %@ | %@ |\n", kTypes[a].name, kTypes[b].name,
                         ClassLetter(o.offererClass), ClassLetter(o.answererClass), Connected(o),
                         Seconds(o.direct || o.relayed ? o.elapsed : -1),
                         o.relayRequested ? Seconds(o.relayAskedAt) : @"never", must];
    }
    [md appendString:@"\n*Must show* is what the suite asserts; – marks a pair it only records.\n"];
    if (gaps.length > 0) [md appendFormat:@"\nKnown gaps, which the suite reports without failing:\n\n%@", gaps];
    [md appendString:@"\n## The NAT types\n\n| Name | Behaviour (RFC 4787) |\n|---|---|\n"];
    for (NSUInteger t = 0; t < kTypeCount; t++) {
        [md appendFormat:@"| %s | %s |\n", kTypes[t].name, kTypes[t].description];
    }
    [md appendFormat:@"\n%@", Wrapped(@"Every address here is 127.0.0.1, so the emulator gives each NAT's public ports "
                                      @"one virtual address, its hosts' private ports another, and the servers a "
                                      @"third. A two-port classifier therefore sees an address-dependent NAT as "
                                      @"independent, as it would on a real network.", @"", @"")];
    [md appendString:@"\n## What this does not show\n\n"];
    NSArray<NSString *> *limits = @[
        (@"Real routers, carrier-grade NAT, mainland China and cross-border paths: those stay in the M0 real-network "
        @"matrix."),
        (@"The host's signalling: the two drivers pass it over a socket pair, as the host forwards it, and make relay "
        @"credentials as the host does. In production it travels each helper's own connection to the host, which no "
        @"NAT here would stop."),
        (@"IPv6, router port mapping and two hosts behind one NAT: the emulated network has no IPv6, loopback test "
        @"mode asks no router, and each host here has a NAT of its own."),
        (@"Run-to-run variation: birthday probing finds a pair with about 99% probability within its budget, so the "
        @"suite runs that pair a second time after a miss."),
    ];
    for (NSString *limit in limits) [md appendString:Wrapped(limit, @"- ", @"  ")];
    return md;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        if (argc < 5) {
            fprintf(stderr, "usage: SZFNATMatrix <szfnat-peer> <server dir> <stun-host.mjs> <matrix.md> [copy.md]\n");
            return 2;
        }
        // The emulator holds a socket per mapping: a hard side's prober alone opens 256.
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < 8192) {
            limit.rlim_cur = limit.rlim_max < 8192 ? limit.rlim_max : 8192;
            setrlimit(RLIMIT_NOFILE, &limit);
        }
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfnat.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof template);
        NSString *scratch = mkdtemp(template) ? @(template) : nil;
        NSString *problem = nil;
        SZFNATServers *servers = scratch ? [SZFNATServers startWithServerDirectory:@(argv[2]) script:@(argv[3])
                                                                           scratch:scratch problem:&problem]
                                         : nil;
        szfnat_world *world = servers ? szfnat_world_create() : NULL;
        if (world == NULL) {
            fprintf(stderr, "SZFNATMatrix: %s\n", (problem ?: @"no scratch directory or NAT world").UTF8String);
            [servers stop];
            return 1;
        }
        BOOL relay = servers.turnPort != 0;
        NSMutableArray *pairs = [NSMutableArray array];
        for (NSUInteger a = 0; a < kTypeCount; a++) {
            for (NSUInteger b = a; b < kTypeCount; b++) {
                // SZFNAT_PAIRS="2-5,4-4" runs only those pairs (by type index), when looking into one.
                NSString *only = NSProcessInfo.processInfo.environment[@"SZFNAT_PAIRS"];
                NSString *name = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)a, (unsigned long)b];
                if (only == nil || [[only componentsSeparatedByString:@","] containsObject:name]) {
                    [pairs addObject:@[ @(a), @(b) ]];
                }
            }
        }
        NSMutableArray<SZFNATOutcome *> *outcomes = [NSMutableArray array];
        for (NSUInteger i = 0; i < pairs.count; i++) [outcomes addObject:[SZFNATOutcome new]];
        __block int failures = 0;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = (NSInteger)kParallelPairs;
        NSString *peer = @(argv[1]);
        NSDate *start = [NSDate date];
        for (NSUInteger i = 0; i < pairs.count; i++) {
            [queue addOperationWithBlock:^{
                NSUInteger a = [pairs[i][0] unsignedIntegerValue], b = [pairs[i][1] unsignedIntegerValue];
                BOOL (^check)(SZFNATOutcome *) = nil;
                NSString *expected = Expected(a, b, relay, &check);
                SZFNATOutcome *outcome = nil;
                NSUInteger runs = 0;
                // Birthday probing is a 99% technique by design (ADR 0011): one more run after a miss.
                const char *gap = KnownGap(a, b);
                NSUInteger allowed = [expected isEqualToString:@"birthday probing"] && gap == NULL ? 2 : 1;
                do {
                    outcome = SZFNATRunPair(world, servers, peer, scratch, &kTypes[a], &kTypes[b]);
                    runs++;
                } while (runs < allowed && check != nil && !check(outcome));
                outcome.runs = runs;
                BOOL ok = outcome.problem == nil && (check == nil || check(outcome));
                @synchronized(outcomes) {
                    outcomes[i] = outcome;
                    if (!ok && gap == NULL) failures++;
                    if (ok && gap != NULL) printf("note: a known gap closed; remove it from kKnownGaps\n");
                    printf("%s %s -> %s: %s, %s (relay asked: %s)%s%s\n", ok ? "ok  " : gap ? "gap " : "FAIL",
                           kTypes[a].name,
                           kTypes[b].name, Connected(outcome).UTF8String, Seconds(outcome.elapsed).UTF8String,
                           outcome.relayRequested ? "yes" : "no",
                           expected ? [NSString stringWithFormat:@"; must show %@", expected].UTF8String : "",
                           runs > 1 ? " (second run)" : "");
                    if (!ok && gap != NULL) printf("     known gap: %s\n", gap);
                    // The NATs' counters for a failure, or for every pair with SZFNAT_VERBOSE set.
                    if (!ok || getenv("SZFNAT_VERBOSE") != NULL) {
                        szfnat_stats x = outcome.offererNAT, y = outcome.answererNAT;
                        printf("     NATs (offerer/answerer): %zu/%zu UDP mappings, %zu/%zu sent, %zu/%zu let in, "
                               "%zu/%zu filtered, %zu/%zu toward private addresses, %zu/%zu TCP spliced; "
                               "techniques tried 0x%lx\n", x.udp_mappings, y.udp_mappings, x.udp_sent, y.udp_sent,
                               x.udp_admitted, y.udp_admitted, x.filtered, y.filtered, x.unreachable, y.unreachable,
                               x.tcp_spliced, y.tcp_spliced, (unsigned long)outcome.tried);
                    }
                }
            }];
        }
        [queue waitUntilAllOperationsAreFinished];
        szfnat_world_destroy(world);
        [servers stop];
        NSString *md = Matrix(outcomes, pairs, relay);
        for (int i = 4; i < argc; i++) {
            [[NSFileManager defaultManager] createDirectoryAtPath:[@(argv[i]) stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:NULL];
            if (![md writeToFile:@(argv[i]) atomically:YES encoding:NSUTF8StringEncoding error:NULL]) failures++;
        }
        printf("%zu pairs in %.0f s; matrix: %s\n", (size_t)pairs.count, -start.timeIntervalSinceNow, argv[4]);
        if (failures > 0 || getenv("SZFNAT_KEEP_LOGS") != NULL) {
            fprintf(stderr, "SZFNATMatrix: helper logs kept under %s\n", scratch.UTF8String);
        } else [[NSFileManager defaultManager] removeItemAtPath:scratch error:NULL];
        if (failures > 0) {
            fprintf(stderr, "SZFNATMatrix: %d pair(s) failed\n", failures);
            return 1;
        }
        printf("SZFNATMatrix passed\n");
        return 0;
    }
}
