// This Mac's notification switches and the app a click opens (SZFriendsNotify.h), kept as small JSON files in the
// state directory: they belong to this device and never sync.

#import "service/notify/SZFriendsNotify.h"

static NSString *const SZFriendsNotifySettingsFile = @"notify-settings.json";
static NSString *const SZFriendsNotifyTargetFile = @"notify-target";

// The apps Friends runs in, for a client whose hello predates client.url_scheme.
NSString *_Nullable SZFriendsNotifyKnownScheme(NSString *appID) {
    static NSDictionary<NSString *, NSString *> *schemes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        schemes = @{
            @"com.intuition.shenzhenpdf" : @"shenzhenpdf",
            @"com.intuition.shenzhenfiles" : @"shenzhenfiles",
            @"com.shenzhen3d.viewer" : @"shenzhen3d",
        };
    });
    return schemes[appID];
}

NSString *_Nullable SZFriendsNotifyBundlePath(NSString *_Nullable executablePath) {
    NSArray<NSString *> *parts = executablePath.stringByStandardizingPath.pathComponents;
    // …/X.app/Contents/MacOS/x: the outermost bundle whose executable this is, never a helper nested inside an app.
    if (parts.count < 4 || ![parts[parts.count - 2] isEqualToString:@"MacOS"] ||
        ![parts[parts.count - 3] isEqualToString:@"Contents"] ||
        ![parts[parts.count - 4].pathExtension.lowercaseString isEqualToString:@"app"]) {
        return nil;
    }
    return [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, parts.count - 3)]];
}

@implementation SZFriendsNotifyTarget

+ (instancetype)defaultTarget {
    SZFriendsNotifyTarget *target = [[self alloc] init];
    target.appID = @"com.intuition.shenzhenpdf";
    target.urlScheme = @"shenzhenpdf";
    return target;
}

- (id)copyWithZone:(NSZone *)zone {
    SZFriendsNotifyTarget *copy = [[[self class] allocWithZone:zone] init];
    copy.appID = self.appID;
    copy.urlScheme = self.urlScheme;
    copy.appPath = self.appPath;
    return copy;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[SZFriendsNotifyTarget class]]) return NO;
    SZFriendsNotifyTarget *other = object;
    return [self.appID isEqualToString:other.appID] && [self.urlScheme isEqualToString:other.urlScheme] &&
           (self.appPath == other.appPath || [self.appPath isEqualToString:other.appPath]);
}

- (NSUInteger)hash {
    return self.appID.hash ^ self.urlScheme.hash;
}

- (NSString *)URLForConversation:(nullable NSString *)conversationID {
    if (conversationID.length == 0) return [NSString stringWithFormat:@"%@://friends", self.urlScheme];
    // Conversation ids are [A-Za-z0-9_-] (SZFriendsStore.h): nothing to escape.
    return [NSString stringWithFormat:@"%@://friends/conversation/%@", self.urlScheme, conversationID];
}

@end

@implementation SZFriendsNotifySettings {
    NSString *_directory;
}

- (instancetype)initWithStateDirectory:(NSString *)stateDirectory {
    if ((self = [super init])) {
        _directory = [stateDirectory copy];
        _enabled = YES;
        _preview = YES;
        _target = [SZFriendsNotifyTarget defaultTarget];
        [self load];
    }
    return self;
}

static id _Nullable SZFriendsReadJSON(NSString *path) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    // A small regular file only: these are a few dozen bytes.
    if (![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize > 4096) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}

static BOOL SZFriendsBoolIn(NSDictionary *object, NSString *key, BOOL fallback) {
    id value = object[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

- (void)load {
    NSDictionary *settings = SZFriendsReadJSON([_directory stringByAppendingPathComponent:SZFriendsNotifySettingsFile]);
    if ([settings isKindOfClass:[NSDictionary class]]) {
        _enabled = SZFriendsBoolIn(settings, @"enabled", YES);
        _preview = SZFriendsBoolIn(settings, @"preview", YES);
        _askDismissed = SZFriendsBoolIn(settings, @"ask_dismissed", NO);
        _used = SZFriendsBoolIn(settings, @"used", NO);
    }
    NSDictionary *target = SZFriendsReadJSON([_directory stringByAppendingPathComponent:SZFriendsNotifyTargetFile]);
    if ([target isKindOfClass:[NSDictionary class]] && [target[@"app_id"] isKindOfClass:[NSString class]] &&
        [target[@"url_scheme"] isKindOfClass:[NSString class]] && [target[@"url_scheme"] length] > 0) {
        SZFriendsNotifyTarget *loaded = [[SZFriendsNotifyTarget alloc] init];
        loaded.appID = target[@"app_id"];
        loaded.urlScheme = target[@"url_scheme"];
        loaded.appPath = [target[@"app_path"] isKindOfClass:[NSString class]] ? target[@"app_path"] : nil;
        _target = loaded;
    }
}

- (void)write:(NSDictionary *)object toFile:(NSString *)name {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                     error:NULL];
    [data writeToFile:[_directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:NULL];
}

- (void)save {
    [self write:@{
        @"enabled" : @(_enabled),
        @"preview" : @(_preview),
        @"ask_dismissed" : @(_askDismissed),
        @"used" : @(_used)
    }
         toFile:SZFriendsNotifySettingsFile];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self save];
}

- (void)setPreview:(BOOL)preview {
    _preview = preview;
    [self save];
}

- (void)setAskDismissed:(BOOL)askDismissed {
    _askDismissed = askDismissed;
    [self save];
}

- (void)setUsed:(BOOL)used {
    if (_used == used) return;
    _used = used;
    [self save];
}

- (void)setTarget:(SZFriendsNotifyTarget *)target {
    if ([_target isEqual:target]) return;
    _target = [target copy];
    [self write:@{@"app_id" : target.appID, @"url_scheme" : target.urlScheme, @"app_path" : target.appPath ?: [NSNull null]}
         toFile:SZFriendsNotifyTargetFile];
}

@end
