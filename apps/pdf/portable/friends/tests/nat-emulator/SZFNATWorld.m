// The punching matrix's processes (SZFNATMatrix.h): the public side's STUN and relay, and one pair of hosts.

#import "SZFNATMatrix.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// How long a pair may run: the provisional budgets (5 s plain, 12 s more with a hard side), the relay, and room.
static const NSTimeInterval kPairBudget = 45;
static const NSTimeInterval kReadyBudget = 8;

// A child process with its stdin and stdout on pipes; stderr goes to a file in the scratch directory.
typedef struct {
    pid_t pid;
    int input, output;
} SZFNATChild;

static BOOL Spawn(NSArray<NSString *> *arguments, NSDictionary<NSString *, NSString *> *environment, int extraFD,
                  NSString *errorPath, SZFNATChild *child) {
    int in[2], out[2];
    if (pipe(in) != 0) return NO;
    if (pipe(out) != 0) {
        close(in[0]);
        close(in[1]);
        return NO;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errorPath.fileSystemRepresentation,
                                     O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (extraFD >= 0) posix_spawn_file_actions_adddup2(&actions, extraFD, 3);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT); // nothing else of the runner's
    NSMutableArray<NSData *> *keep = [NSMutableArray array];
    char *argv[16] = {0}, *envp[24] = {0};
    for (NSUInteger i = 0; i < arguments.count && i < 15; i++) {
        NSData *bytes = [arguments[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *text = [bytes mutableCopy];
        [text appendBytes:"" length:1];
        [keep addObject:text];
        argv[i] = text.mutableBytes;
    }
    NSUInteger e = 0;
    for (NSString *key in environment) {
        if (e >= 23) break;
        NSMutableData *text = [[[NSString stringWithFormat:@"%@=%@", key, environment[key]]
            dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [text appendBytes:"" length:1];
        [keep addObject:text];
        envp[e++] = text.mutableBytes;
    }
    int status = posix_spawnp(&child->pid, argv[0], &actions, &attributes, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(in[0]);
    close(out[1]);
    if (status != 0) {
        close(in[1]);
        close(out[0]);
        return NO;
    }
    child->input = in[1];
    child->output = out[0];
    fcntl(child->output, F_SETFL, O_NONBLOCK);
    return YES;
}

// Closes its stdin (every child here exits on that), then waits up to 3 s before killing it.
static void Finish(SZFNATChild *child) {
    if (child->pid <= 0) return;
    close(child->input);
    int status = 0;
    for (int i = 0; i < 60 && waitpid(child->pid, &status, WNOHANG) == 0; i++) usleep(50000);
    if (waitpid(child->pid, &status, WNOHANG) == 0) {
        kill(child->pid, SIGKILL);
        waitpid(child->pid, &status, 0);
    }
    close(child->output);
    child->pid = 0;
}

// Appends the JSON lines a child has printed so far to `lines`, keeping a partial line in `pending`; NO once its
// stdout ended.
static BOOL ReadLines(SZFNATChild *child, NSMutableData *pending, NSMutableArray<NSDictionary *> *lines) {
    uint8_t buffer[4096];
    for (;;) {
        ssize_t got = read(child->output, buffer, sizeof buffer);
        if (got == 0) return NO;
        if (got < 0) return YES;
        [pending appendBytes:buffer length:(NSUInteger)got];
        for (;;) {
            NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                             range:NSMakeRange(0, pending.length)];
            if (newline.location == NSNotFound) break;
            NSData *line = [pending subdataWithRange:NSMakeRange(0, newline.location)];
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            if ([object isKindOfClass:[NSDictionary class]]) [lines addObject:object];
        }
    }
}

static void Wait(SZFNATChild *children, int count, int milliseconds) {
    struct pollfd polls[4];
    for (int i = 0; i < count; i++) polls[i] = (struct pollfd){.fd = children[i].output, .events = POLLIN};
    poll(polls, (nfds_t)count, milliseconds);
}

static NSDictionary *FirstEvent(NSArray<NSDictionary *> *lines, NSString *name) {
    for (NSDictionary *line in lines) {
        if ([line[@"event"] isEqual:name]) return line;
    }
    return nil;
}

#pragma mark - The public side

static NSString *En0Address(void) {
    struct ifaddrs *list = NULL;
    NSString *address = nil;
    if (getifaddrs(&list) != 0) return @"127.0.0.1";
    for (struct ifaddrs *entry = list; entry != NULL && address == nil; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || entry->ifa_addr->sa_family != AF_INET || strcmp(entry->ifa_name, "en0") != 0) {
            continue;
        }
        char text[INET_ADDRSTRLEN];
        const struct sockaddr_in *in = (const struct sockaddr_in *)(const void *)entry->ifa_addr;
        if (inet_ntop(AF_INET, &in->sin_addr, text, sizeof text)) address = @(text);
    }
    freeifaddrs(list);
    return address ?: @"127.0.0.1";
}

static uint16_t FreePort(int type) {
    int fd = socket(AF_INET, type, 0);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof address;
    uint16_t port = 0;
    if (bind(fd, (struct sockaddr *)&address, sizeof address) == 0 &&
        getsockname(fd, (struct sockaddr *)&address, &length) == 0) {
        port = ntohs(address.sin_port);
    }
    close(fd);
    return port;
}

@implementation SZFNATServers {
    SZFNATChild _stun, _coturn;
}

+ (instancetype)startWithServerDirectory:(NSString *)serverDirectory
                                  script:(NSString *)script
                                 scratch:(NSString *)scratch
                                 problem:(NSString **)problem {
    SZFNATServers *servers = [[self alloc] init];
    NSString *coturn = NSProcessInfo.processInfo.environment[@"FRIENDS_TEST_COTURN"];
    BOOL relay = coturn.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:coturn];
    if (relay && ![servers startCoturn:coturn scratch:scratch]) {
        *problem = @"coturn did not answer STUN on loopback";
        return nil;
    }
    NSString *stun = [serverDirectory stringByAppendingPathComponent:@"src/stun.js"];
    NSDictionary *environment = @{@"PATH" : NSProcessInfo.processInfo.environment[@"PATH"] ?: @"/usr/bin:/bin"};
    NSArray *arguments = @[ @"node", script, stun, relay ? @"1" : @"2", relay ? @"0" : @"1" ];
    if (!Spawn(arguments, environment, -1, [scratch stringByAppendingPathComponent:@"stun-host.log"],
               &servers->_stun)) {
        *problem = @"node is not on PATH";
        [servers stop];
        return nil;
    }
    NSMutableData *pending = [NSMutableData data];
    NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (lines.count == 0 && deadline.timeIntervalSinceNow > 0) {
        Wait(&servers->_stun, 1, 200);
        if (!ReadLines(&servers->_stun, pending, lines)) break;
    }
    NSArray *udp = lines.firstObject[@"udp"];
    if (udp.count == 0 || (!relay && [lines.firstObject[@"tcp"] intValue] == 0)) {
        *problem = [NSString stringWithFormat:@"the host's STUN responder did not start (Node.js 22.16 or later, %@)",
                                              [scratch stringByAppendingPathComponent:@"stun-host.log"]];
        [servers stop];
        return nil;
    }
    servers->_stunPrimary = relay ? servers->_turnPort : (uint16_t)[udp[0] intValue];
    servers->_stunSecondary = (uint16_t)[udp[relay ? 0 : 1] intValue];
    return servers;
}

- (BOOL)startCoturn:(NSString *)binary scratch:(NSString *)scratch {
    _turnPort = FreePort(SOCK_DGRAM);
    _turnSecret = [NSString stringWithFormat:@"szfnat-turn-secret-%08x%08x", arc4random(), arc4random()];
    uint16_t minPort = (uint16_t)(50000 + arc4random_uniform(10000));
    NSArray<NSString *> *lines = @[
        @"realm=friends.test", [NSString stringWithFormat:@"listening-port=%u", _turnPort], @"listening-ip=127.0.0.1",
        [@"relay-ip=" stringByAppendingString:En0Address()], [NSString stringWithFormat:@"min-port=%u", minPort],
        [NSString stringWithFormat:@"max-port=%u", minPort + 63], @"fingerprint", @"use-auth-secret",
        [@"static-auth-secret=" stringByAppendingString:_turnSecret], @"max-bps=625000", @"no-tcp-relay",
        @"no-multicast-peers", @"no-cli", @"no-software-attribute", @"no-rfc5780", @"no-stdout-log",
        @"log-file=/dev/null", @"simple-log", @"no-tls", @"no-dtls", @"allow-loopback-peers",
        [@"pidfile=" stringByAppendingString:[scratch stringByAppendingPathComponent:@"turnserver.pid"]],
    ];
    NSString *config = [scratch stringByAppendingPathComponent:@"turnserver.conf"];
    [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:config atomically:YES
                                                                               encoding:NSUTF8StringEncoding
                                                                                  error:NULL];
    if (!Spawn(@[ binary, @"-c", config ], @{}, -1, [scratch stringByAppendingPathComponent:@"coturn.log"],
               &_coturn)) {
        return NO;
    }
    // coturn answers STUN once it listens.
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in to = {.sin_len = sizeof to, .sin_family = AF_INET, .sin_port = htons(_turnPort)};
    to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL answered = NO;
    for (int i = 0; i < 40 && !answered; i++) {
        uint8_t request[20] = {0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42}, reply[512];
        arc4random_buf(request + 8, 12);
        sendto(fd, request, sizeof request, 0, (struct sockaddr *)&to, sizeof to);
        struct pollfd wait = {.fd = fd, .events = POLLIN};
        answered = poll(&wait, 1, 200) == 1 && recv(fd, reply, sizeof reply, 0) >= 20;
    }
    close(fd);
    return answered;
}

- (void)stop {
    Finish(&_stun);
    if (_coturn.pid > 0) {
        kill(_coturn.pid, SIGTERM); // coturn does not read its stdin
        Finish(&_coturn);
    }
}

@end

#pragma mark - One pair

@implementation SZFNATOutcome
@end

static NSString *Hex(NSUInteger bytes) {
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < bytes; i++) [text appendFormat:@"%02x", arc4random_uniform(256)];
    return text;
}

SZFNATOutcome *SZFNATRunPair(szfnat_world *world, SZFNATServers *servers, NSString *peer, NSString *scratch,
                             const SZFNATType *offerer, const SZFNATType *answerer) {
    SZFNATOutcome *outcome = [SZFNATOutcome new];
    outcome.technique = 0;
    outcome.seconds = -1;
    outcome.elapsed = -1;
    outcome.relayAskedAt = -1;
    szfnat_nat *nats[2] = {szfnat_add(world, &offerer->config), szfnat_add(world, &answerer->config)};
    int pair[2] = {-1, -1};
    if (nats[0] == NULL || nats[1] == NULL || socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
        outcome.problem = @"no NAT or no socket pair";
        for (int i = 0; i < 2; i++) {
            if (nats[i]) szfnat_remove(world, nats[i]);
        }
        return outcome;
    }
    NSString *seed = Hex(32), *tag = [NSString stringWithFormat:@"%s-%s", offerer->name, answerer->name];
    SZFNATChild children[2] = {{0}, {0}};
    NSMutableArray<NSDictionary *> *lines[2] = {[NSMutableArray array], [NSMutableArray array]};
    NSMutableData *pending[2] = {[NSMutableData data], [NSMutableData data]};
    BOOL started = YES;
    for (int i = 0; i < 2; i++) {
        NSMutableDictionary *environment = [@{
            @"SZFNAT_INSIDE_PORT" : [NSString stringWithFormat:@"%u", szfnat_inside_port(nats[i])],
            @"SZFNAT_ROLE" : i == 0 ? @"offerer" : @"answerer", @"SZFNAT_SEED" : seed,
            @"SZFNAT_STUN" : [NSString stringWithFormat:@"%u", servers.stunPrimary],
            @"SZFNAT_STUN2" : [NSString stringWithFormat:@"%u", servers.stunSecondary],
            @"HOME" : scratch, @"TMPDIR" : scratch,
        } mutableCopy];
        if (servers.turnPort != 0) {
            environment[@"SZFNAT_TURN_PORT"] = [NSString stringWithFormat:@"%u", servers.turnPort];
            environment[@"SZFNAT_TURN_SECRET"] = servers.turnSecret;
        }
        NSString *log = [scratch stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.log", tag,
                                                                                           i == 0 ? @"a" : @"b"]];
        // Another peer for one role (the Rust core's, tools/nat-peer): it does not link the shim, so dyld inserts the
        // one beside this peer, which puts its sockets behind the NAT the same way.
        NSString *role = i == 0 ? @"SZFNAT_OFFERER_PEER" : @"SZFNAT_ANSWERER_PEER";
        NSString *other = NSProcessInfo.processInfo.environment[role];
        if (other.length > 0) {
            environment[@"DYLD_INSERT_LIBRARIES"] =
                [[peer stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"libszfnat_shim.dylib"];
        }
        started = started && Spawn(@[ other.length > 0 ? other : peer ], environment, pair[i], log, &children[i]);
    }
    close(pair[0]);
    close(pair[1]);
    if (!started) outcome.problem = @"a peer did not start";
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kReadyBudget];
    while (started && deadline.timeIntervalSinceNow > 0 &&
           (FirstEvent(lines[0], @"ready") == nil || FirstEvent(lines[1], @"ready") == nil)) {
        Wait(children, 2, 100);
        for (int i = 0; i < 2; i++) ReadLines(&children[i], pending[i], lines[i]);
    }
    NSDictionary *readyA = FirstEvent(lines[0], @"ready"), *readyB = FirstEvent(lines[1], @"ready");
    if (started && (readyA == nil || readyB == nil)) outcome.problem = @"a peer never said it was ready";
    outcome.offererClass = [readyA[@"class"] integerValue];
    outcome.answererClass = [readyB[@"class"] integerValue];
    if (outcome.problem == nil) {
        write(children[0].input, "reach\n", 6);
        deadline = [NSDate dateWithTimeIntervalSinceNow:kPairBudget];
        NSDate *relayAsked = nil;
        while (deadline.timeIntervalSinceNow > 0 && FirstEvent(lines[0], @"data") == nil &&
               FirstEvent(lines[0], @"ended") == nil) {
            // Without coturn the relay cannot carry it; a direct path that lost the race to the relay request is
            // given 2 s more.
            if (relayAsked == nil && servers.turnPort == 0 && FirstEvent(lines[0], @"relay") != nil) {
                relayAsked = [NSDate date];
            }
            if (relayAsked != nil && relayAsked.timeIntervalSinceNow < -2) break;
            Wait(children, 2, 100);
            for (int i = 0; i < 2; i++) ReadLines(&children[i], pending[i], lines[i]);
        }
        NSDictionary *stream = FirstEvent(lines[0], @"stream"), *data = FirstEvent(lines[0], @"data");
        NSDictionary *ended = FirstEvent(lines[0], @"ended"), *relay = FirstEvent(lines[0], @"relay");
        NSDictionary *log = data ?: stream ?: ended ?: relay;
        outcome.relayAskedAt = relay ? [relay[@"elapsed"] doubleValue] : -1;
        BOOL carried = [data[@"ok"] boolValue];
        outcome.direct = carried && [stream[@"route"] isEqual:@"internet"];
        outcome.relayed = carried && [stream[@"route"] isEqual:@"relay"];
        outcome.technique = [log[@"technique"] integerValue];
        outcome.tried = [log[@"tried"] unsignedIntegerValue];
        outcome.seconds = log ? [log[@"seconds"] doubleValue] : -1;
        outcome.elapsed = stream ? [stream[@"elapsed"] doubleValue] : -1;
        outcome.relayRequested = [log[@"relay_requested"] boolValue] || outcome.relayed;
        if (log == nil) outcome.problem = @"the offerer reported nothing within the pair's budget";
    }
    for (int i = 0; i < 2; i++) Finish(&children[i]);
    outcome.offererNAT = szfnat_get_stats(world, nats[0]);
    outcome.answererNAT = szfnat_get_stats(world, nats[1]);
    szfnat_remove(world, nats[0]);
    szfnat_remove(world, nats[1]);
    return outcome;
}
