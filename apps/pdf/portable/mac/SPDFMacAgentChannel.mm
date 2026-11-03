// The szpdf channel's paths, request checks and client side (SPDFMacAgentChannel.h).
#import "SPDFMacAgentChannel.h"

#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

const NSUInteger SPDFMacAgentChannelMaxLine = 1024 * 1024;

static NSError* ChannelError(NSString* message) {
    return [NSError errorWithDomain:@"ShenzhenPDF.AgentChannel" code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSString* SPDFMacAgentChannelDirectory(NSString* stateDirectory) {
    return [stateDirectory stringByAppendingPathComponent:@"Agent"];
}

NSString* SPDFMacAgentChannelSocketPath(NSString* stateDirectory, pid_t pid) {
    return [SPDFMacAgentChannelDirectory(stateDirectory)
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.sock", (int)pid]];
}

pid_t SPDFMacAgentChannelPIDFromName(NSString* name) {
    if (![name hasSuffix:@".sock"]) return 0;
    NSString* digits = [name substringToIndex:name.length - 5];
    if (!digits.length || digits.length > 9) return 0;
    for (NSUInteger i = 0; i < digits.length; i++)
        if (![NSCharacterSet.decimalDigitCharacterSet characterIsMember:[digits characterAtIndex:i]] ||
            [digits characterAtIndex:i] > '9')
            return 0;
    if ([digits hasPrefix:@"0"]) return 0;
    return (pid_t)digits.intValue;
}

BOOL SPDFMacAgentChannelPathFits(NSString* path) {
    struct sockaddr_un address;
    return strlen(path.fileSystemRepresentation) < sizeof(address.sun_path);
}

static BOOL IsBool(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL IsWholeNumber(id value, long long low, long long high) {
    if (![value isKindOfClass:NSNumber.class] || IsBool(value)) return NO;
    double number = [value doubleValue];
    return number == floor(number) && number >= (double)low && number <= (double)high;
}

static BOOL IsAbsolutePath(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 1 && [value length] <= 4096 &&
           [value isAbsolutePath] && [value rangeOfString:@"\0"].location == NSNotFound;
}

NSDictionary* SPDFMacAgentChannelValidateRequest(NSData* line, NSError** error) {
    NSError* failure = nil;
    id object = line.length && line.length <= SPDFMacAgentChannelMaxLine
                    ? [NSJSONSerialization JSONObjectWithData:line options:0 error:nil]
                    : nil;
    NSDictionary* request = [object isKindOfClass:NSDictionary.class] ? object : nil;
    NSString* command = [request[@"command"] isKindOfClass:NSString.class] ? request[@"command"] : nil;
    NSDictionary<NSString*, NSArray<NSString*>*>* allowed = @{
        @"state" : @[ @"command" ],
        @"open" : @[ @"command", @"path", @"page", @"heading", @"front", @"wait", @"reload", @"timeout" ],
        @"reload" : @[ @"command", @"path", @"timeout" ],
        @"close" : @[ @"command", @"path", @"windowId" ],
        @"watch-comments" : @[ @"command", @"path", @"since", @"timeout" ],
        @"screenshot" : @[ @"command", @"windowId", @"output" ],
        @"comments-changed" : @[ @"command", @"path" ],
        @"version" : @[ @"command", @"action", @"path", @"carry", @"older", @"newer", @"front", @"wait" ],
    };
    if (!request) failure = ChannelError(@"The request is not a JSON object.");
    else if (!allowed[command ?: @""]) failure = ChannelError(@"Unknown command.");
    for (NSString* key in failure ? @[] : request.allKeys)
        if (![allowed[command] containsObject:key])
            failure = ChannelError([NSString stringWithFormat:@"Unknown field %@.", key]);
    BOOL takesPath = [@[ @"open", @"reload", @"comments-changed", @"version", @"watch-comments" ]
        containsObject:command ?: @""];
    if (!failure && takesPath && !IsAbsolutePath(request[@"path"]))
        failure = ChannelError(@"An absolute document path is required.");
    if (!failure && request[@"timeout"] && !IsWholeNumber(request[@"timeout"], 1, 86400))
        failure = ChannelError(@"timeout must be whole seconds.");
    if (!failure && [command isEqual:@"close"] &&
        !((IsAbsolutePath(request[@"path"]) && !request[@"windowId"]) ||
          (IsWholeNumber(request[@"windowId"], 1, INT32_MAX) && !request[@"path"])))
        failure = ChannelError(@"close takes an absolute path or a window number.");
    if (!failure && [command isEqual:@"watch-comments"] && request[@"since"] &&
        (![request[@"since"] isKindOfClass:NSString.class] || [request[@"since"] length] > 64))
        failure = ChannelError(@"since must be an ISO 8601 time.");
    if (!failure && [command isEqual:@"open"]) {
        if (request[@"page"] && !IsWholeNumber(request[@"page"], 1, 1000000))
            failure = ChannelError(@"page must be a whole number from 1.");
        else if (request[@"heading"] &&
                 (![request[@"heading"] isKindOfClass:NSString.class] || ![request[@"heading"] length] ||
                  [request[@"heading"] length] > 512))
            failure = ChannelError(@"heading must be text of at most 512 characters.");
        else if (request[@"page"] && request[@"heading"])
            failure = ChannelError(@"Give a page or a heading, not both.");
        else if ((request[@"front"] && !IsBool(request[@"front"])) || (request[@"wait"] && !IsBool(request[@"wait"])) ||
                 (request[@"reload"] && !IsBool(request[@"reload"])))
            failure = ChannelError(@"front, wait and reload must be true or false.");
    }
    if (!failure && [command isEqual:@"version"]) {
        NSString* action = request[@"action"];
        if (![@[ @"new", @"list", @"compare" ] containsObject:action ?: @""])
            failure = ChannelError(@"action must be new, list or compare.");
        else if (request[@"carry"] && ![@[ @"open", @"all", @"none" ] containsObject:request[@"carry"]])
            failure = ChannelError(@"carry must be open, all or none.");
        else if ([action isEqual:@"compare"] && (!IsWholeNumber(request[@"older"], 1, 100000) ||
                                                 !IsWholeNumber(request[@"newer"], 1, 100000)))
            failure = ChannelError(@"compare needs two version numbers.");
        else if ((request[@"front"] && !IsBool(request[@"front"])) || (request[@"wait"] && !IsBool(request[@"wait"])))
            failure = ChannelError(@"front and wait must be true or false.");
    }
    if (!failure && [command isEqual:@"screenshot"]) {
        if (!IsWholeNumber(request[@"windowId"], 1, INT32_MAX))
            failure = ChannelError(@"windowId must be a window number.");
        else if (!IsAbsolutePath(request[@"output"]) ||
                 ![[request[@"output"] pathExtension].lowercaseString isEqual:@"png"])
            failure = ChannelError(@"The picture's path must be absolute and end in .png.");
    }
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    return request;
}

NSData* SPDFMacAgentChannelEncode(NSDictionary* object) {
    NSMutableData* data = [[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil]
                              mutableCopy]
                              ?: [NSMutableData dataWithData:[@"{\"error\":\"Unencodable answer.\"}"
                                                                 dataUsingEncoding:NSUTF8StringEncoding]];
    [data appendBytes:"\n" length:1];
    return data;
}

BOOL SPDFMacAgentChannelPrepareDirectory(NSString* directory, NSError** error) {
    mkdir(directory.stringByDeletingLastPathComponent.fileSystemRepresentation, 0700);
    if (mkdir(directory.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
        if (error) *error = ChannelError(@"Could not create the agent directory.");
        return NO;
    }
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 0077)) {
        if (error) *error = ChannelError(@"The agent directory is not private to this user.");
        return NO;
    }
    return YES;
}

static BOOL WaitFor(int fd, short events, NSDate* deadline) {
    for (;;) {
        int ms = (int)MAX(0, deadline.timeIntervalSinceNow * 1000);
        struct pollfd entry = {fd, events, 0};
        int ready = poll(&entry, 1, ms);
        if (ready > 0) return YES;
        if (ready == 0 || errno != EINTR) return NO;
    }
}

NSDictionary* SPDFMacAgentChannelExchange(NSString* path, NSDictionary* request, NSTimeInterval timeout,
                                          NSError** error) {
    if (!SPDFMacAgentChannelPathFits(path)) {
        if (error) *error = ChannelError(@"The agent socket's path is too long.");
        return nil;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) *error = ChannelError(@"Could not create a socket.");
        return nil;
    }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    struct sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr*)&address, sizeof(address)) != 0) {
        int code = errno;
        close(fd);
        if (error)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                                     userInfo:@{NSLocalizedDescriptionKey : @"ShenzhenPDF did not answer."}];
        return nil;
    }
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSData* out = SPDFMacAgentChannelEncode(request);
    const uint8_t* bytes = (const uint8_t*)out.bytes;
    size_t sent = 0;
    while (sent < out.length) {
        if (!WaitFor(fd, POLLOUT, deadline)) break;
        ssize_t n = write(fd, bytes + sent, out.length - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        sent += (size_t)n;
    }
    NSMutableData* answer = [NSMutableData data];
    BOOL complete = NO;
    while (sent == out.length && !complete && answer.length <= SPDFMacAgentChannelMaxLine) {
        if (!WaitFor(fd, POLLIN, deadline)) break;
        uint8_t buffer[16384];
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        [answer appendBytes:buffer length:(NSUInteger)n];
        complete = memchr(buffer, '\n', (size_t)n) != NULL;
    }
    close(fd);
    id object = complete ? [NSJSONSerialization JSONObjectWithData:answer options:0 error:nil] : nil;
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error) *error = ChannelError(sent == out.length ? @"ShenzhenPDF did not answer in time."
                                                            : @"Could not send the request to ShenzhenPDF.");
        return nil;
    }
    return object;
}
