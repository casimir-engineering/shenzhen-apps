// The test home's poster (SZFriendsNotify.h): every request, withdrawal, ask and routed click as one JSON line in
// <state dir>/notifications.jsonl, so tests read what a person would have seen and nothing reaches the screen.

#import "service/notify/SZFriendsNotify.h"

#import <fcntl.h>
#import <unistd.h>

@implementation SZFriendsNotifyFileSink {
    SZFriendsNotifyPermission _permission;
}

@synthesize onResponse = _onResponse;
@synthesize onPermissionChange = _onPermissionChange;

- (instancetype)initWithStateDirectory:(NSString *)stateDirectory
                           environment:(NSDictionary<NSString *, NSString *> *)environment {
    if ((self = [super init])) {
        _path = [stateDirectory stringByAppendingPathComponent:@"notifications.jsonl"];
        NSString *permission = environment[@"SZFRIENDS_NOTIFY_PERMISSION"];
        _permission = [permission isEqualToString:@"denied"]      ? SZFriendsNotifyPermissionDenied
                      : [permission isEqualToString:@"not_asked"] ? SZFriendsNotifyPermissionNotAsked
                                                                  : SZFriendsNotifyPermissionGranted;
    }
    return self;
}

- (SZFriendsNotifyPermission)permission {
    return _permission;
}

// One line, appended with O_APPEND so a test reading the file meanwhile never sees half of one.
- (void)append:(NSDictionary *)object {
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:object
                                                           options:NSJSONWritingSortedKeys |
                                                                   NSJSONWritingWithoutEscapingSlashes
                                                             error:NULL] mutableCopy];
    if (line == nil) return;
    [line appendBytes:"\n" length:1];
    int fd = open(_path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    (void)write(fd, line.bytes, line.length);
    close(fd);
}

- (void)post:(NSDictionary<NSString *, id> *)request {
    [self append:request];
}

- (void)withdrawThread:(NSString *)thread {
    [self append:@{@"withdraw" : @{@"thread" : thread}}];
}

- (void)askWithCompletion:(void (^)(void))completion {
    [self append:@{@"asked" : @YES}];
    if (_permission == SZFriendsNotifyPermissionNotAsked) _permission = SZFriendsNotifyPermissionGranted;
    completion();
}

- (void)openURL:(NSString *)url appID:(NSString *)appID appPath:(nullable NSString *)appPath {
    [self append:@{@"opened" : @{@"url" : url, @"app_id" : appID, @"app_path" : appPath ?: [NSNull null]}}];
}

@end
