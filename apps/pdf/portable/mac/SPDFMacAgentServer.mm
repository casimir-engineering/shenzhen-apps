// The szpdf listener (SPDFMacAgentServer.h). Accepting and reading happen on a private serial queue; each checked
// request is handled on the main thread in the run loop's common modes, so a reader showing a modal panel, or one
// finishing a quit (NSTerminateLater runs the loop in NSModalPanelRunLoopMode, where the main dispatch queue is not
// served), still answers instead of leaving the tool waiting.
#import "SPDFMacAgentServer.h"
#import "SPDFMacAgentChannel.h"
#import "SPDFMacStateDirectory.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

void spdf_launch_profile_log(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);

static dispatch_queue_t gQueue;
static dispatch_source_t gSource;
static char gSocketPath[sizeof(((struct sockaddr_un*)0)->sun_path)];

// The socket goes with the process: a quit ends in exit(), which runs this.
static void RemoveSocket(void) {
    if (gSocketPath[0]) unlink(gSocketPath);
}

static void WriteAll(int fd, NSData* data) {
    const uint8_t* bytes = (const uint8_t*)data.bytes;
    size_t sent = 0;
    while (sent < data.length) {
        ssize_t n = write(fd, bytes + sent, data.length - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        sent += (size_t)n;
    }
}

static void Answer(int fd, NSDictionary* answer) {
    NSMutableDictionary* stamped = [answer mutableCopy];
    stamped[@"pid"] = @(getpid());
    WriteAll(fd, SPDFMacAgentChannelEncode(stamped));
    close(fd);
}

static void Serve(int fd) {
    // A tool that connects and says nothing cannot hold the queue: reads give up after five seconds.
    struct timeval wait = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    uid_t uid = (uid_t)-1;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0 || uid != getuid()) {
        close(fd);
        return;
    }
    NSMutableData* line = [NSMutableData data];
    for (;;) {
        uint8_t buffer[4096];
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        uint8_t* end = (uint8_t*)memchr(buffer, '\n', (size_t)n);
        [line appendBytes:buffer length:end ? (NSUInteger)(end - buffer) : (NSUInteger)n];
        if (end || line.length > SPDFMacAgentChannelMaxLine) break;
    }
    NSError* error = nil;
    NSDictionary* request = SPDFMacAgentChannelValidateRequest(line, &error);
    if (!request) {
        Answer(fd, @{@"error" : error.localizedDescription ?: @"Invalid request."});
        return;
    }
    __block BOOL answered = NO;
    void (^reply)(NSDictionary*) = ^(NSDictionary* answer) {
        dispatch_async(gQueue, ^{
            if (answered) return;
            answered = YES;
            Answer(fd, answer ?: @{@"error" : @"No answer."});
        });
    };
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        @autoreleasepool {
            [ShenzhenMacDelegate agentServerHandleRequest:request reply:reply];
        }
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void SPDFMacAgentServerStart(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    NSString* stateDirectory = SPDFMacStateDirectoryPath();
    NSString* directory = SPDFMacAgentChannelDirectory(stateDirectory);
    NSString* path = SPDFMacAgentChannelSocketPath(stateDirectory, getpid());
    NSError* error = nil;
    if (!SPDFMacAgentChannelPathFits(path) || !SPDFMacAgentChannelPrepareDirectory(directory, &error)) {
        spdf_launch_profile_log(@"szpdf channel not started: %@", error.localizedDescription ?: @"path too long");
        return;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    unlink(address.sun_path); // a previous process with this pid is gone
    // Created closed to everyone else, then opened to this user only: there is no moment when another user could
    // connect.
    mode_t previous = umask(0177);
    int bound = bind(fd, (struct sockaddr*)&address, sizeof(address));
    umask(previous);
    if (bound != 0 || chmod(address.sun_path, 0600) != 0 || listen(fd, 8) != 0) {
        close(fd);
        return;
    }
    strlcpy(gSocketPath, address.sun_path, sizeof(gSocketPath));
    atexit(RemoveSocket);
    gQueue = dispatch_queue_create("ShenzhenPDF szpdf channel", DISPATCH_QUEUE_SERIAL);
    gSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, gQueue);
    dispatch_source_set_event_handler(gSource, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) return;
        fcntl(client, F_SETFD, FD_CLOEXEC);
        Serve(client);
    });
    dispatch_resume(gSource);
}
