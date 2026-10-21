// The real poster (SZFriendsNotify.h): the notification centre under the helper's own bundle, "Shenzhen Friends" with
// its icon, so the person allows Friends once per Mac whatever app they use it from.
//
// Each conversation is a thread (grouped, and withdrawn together once read); messages carry Reply. A click opens the
// remembered app on the conversation through LaunchServices, the call behind NSWorkspace's open methods (the service
// layer links no UI toolkit): the app itself, else whatever opens the scheme, else ShenzhenPDF. Never made in a test
// home: tests use SZFriendsNotifyFileSink and nothing here runs in any test process.

#import "service/notify/SZFriendsNotify.h"

#import <CoreServices/CoreServices.h>
#import <UserNotifications/UserNotifications.h>
#import <poll.h>

#import "client/szfriends_client.h"

static NSString *const SZFriendsNotifyReplyAction = @"reply";
// Reply's placeholder names the friend, so each conversation has its category; the newest few are registered.
static const NSUInteger SZFriendsNotifyCategoryMax = 64;
// How often the system's answer is read again, so a change in System Settings reaches Settings' line.
static const NSTimeInterval SZFriendsNotifyPermissionRefresh = 5;

// The request as the system keeps it with the notification: userInfo takes property lists only, so JSON text.
static NSDictionary *_Nullable SZFriendsNotifyRequestFromUserInfo(NSDictionary *userInfo) {
    NSString *json = [userInfo[@"request"] isKindOfClass:[NSString class]] ? userInfo[@"request"] : nil;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [request isKindOfClass:[NSDictionary class]] ? request : nil;
}

static void SZFriendsNotifyResponseParts(UNNotificationResponse *response, NSString **action, NSString **text) {
    *action = nil;
    *text = nil;
    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
        *action = @"open";
    } else if ([response.actionIdentifier isEqualToString:SZFriendsNotifyReplyAction] &&
               [response isKindOfClass:[UNTextInputNotificationResponse class]]) {
        *action = @"reply";
        *text = ((UNTextInputNotificationResponse *)response).userText;
    }
}

static BOOL SZFriendsNotifyOpenWith(NSURL *url, NSURL *_Nullable appURL) {
    if (appURL == nil) return LSOpenCFURLRef((__bridge CFURLRef)url, NULL) == noErr;
    LSLaunchURLSpec spec = {(__bridge CFURLRef)appURL, (__bridge CFArrayRef) @[ url ], NULL, kLSLaunchDefaults, NULL};
    return LSOpenFromURLSpec(&spec, NULL) == noErr;
}

// The app at `appPath` when it is still there, activated; the scheme's default app; ShenzhenPDF's scheme.
static void SZFriendsNotifyOpen(NSString *urlString, NSString *_Nullable appPath) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) return;
    BOOL isApp = NO;
    if (appPath.length && [[NSFileManager defaultManager] fileExistsAtPath:appPath isDirectory:&isApp] && isApp &&
        SZFriendsNotifyOpenWith(url, [NSURL fileURLWithPath:appPath isDirectory:YES])) {
        return;
    }
    if (SZFriendsNotifyOpenWith(url, nil)) return;
    NSURLComponents *fallback = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([fallback.scheme isEqualToString:@"shenzhenpdf"]) return;
    fallback.scheme = @"shenzhenpdf";
    if (fallback.URL != nil) SZFriendsNotifyOpenWith(fallback.URL, nil);
}

@interface SZFriendsNotifySystemPoster () <UNUserNotificationCenterDelegate>
@end

@implementation SZFriendsNotifySystemPoster {
    dispatch_queue_t _queue;
    UNUserNotificationCenter *_center;
    SZFriendsNotifyPermission _permission;
    CFAbsoluteTime _permissionReadAt;
    NSMutableDictionary<NSString *, UNNotificationCategory *> *_categories;
    NSMutableArray<NSString *> *_categoryOrder;
}

@synthesize onResponse = _onResponse;
@synthesize onPermissionChange = _onPermissionChange;

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        _permission = SZFriendsNotifyPermissionNotAsked;
        _categories = [NSMutableDictionary dictionary];
        _categoryOrder = [NSMutableArray array];
        _center = [UNUserNotificationCenter currentNotificationCenter];
        // Before the first response can arrive: a click that launched this helper is delivered to the delegate.
        _center.delegate = self;
        [self readPermission];
    }
    return self;
}

#pragma mark - Permission

- (void)readPermission {
    _permissionReadAt = CFAbsoluteTimeGetCurrent();
    __weak SZFriendsNotifySystemPoster *weakSelf = self;
    dispatch_queue_t queue = _queue;
    [_center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        SZFriendsNotifyPermission permission = SZFriendsNotifyPermissionGranted;
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            permission = SZFriendsNotifyPermissionNotAsked;
        } else if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
            permission = SZFriendsNotifyPermissionDenied;
        }
        dispatch_async(queue, ^{ [weakSelf setPermissionValue:permission]; });
    }];
}

- (void)setPermissionValue:(SZFriendsNotifyPermission)permission {
    if (permission == _permission) return;
    _permission = permission;
    if (self.onPermissionChange) self.onPermissionChange();
}

- (SZFriendsNotifyPermission)permission {
    if (CFAbsoluteTimeGetCurrent() - _permissionReadAt > SZFriendsNotifyPermissionRefresh) [self readPermission];
    return _permission;
}

- (void)askWithCompletion:(void (^)(void))completion {
    __weak SZFriendsNotifySystemPoster *weakSelf = self;
    dispatch_queue_t queue = _queue;
    [_center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                           completionHandler:^(BOOL granted, NSError *error) {
                               (void)error;
                               dispatch_async(queue, ^{
                                   [weakSelf setPermissionValue:granted ? SZFriendsNotifyPermissionGranted
                                                                        : SZFriendsNotifyPermissionDenied];
                                   completion();
                               });
                           }];
}

#pragma mark - Posting

- (nullable NSString *)categoryForRequest:(NSDictionary *)request {
    NSDictionary *reply = [request[@"reply"] isKindOfClass:[NSDictionary class]] ? request[@"reply"] : nil;
    if (reply == nil) return nil;
    NSString *identifier = [@"message." stringByAppendingString:request[@"thread"]];
    UNTextInputNotificationAction *action =
        [UNTextInputNotificationAction actionWithIdentifier:SZFriendsNotifyReplyAction
                                                      title:reply[@"label"]
                                                    options:UNNotificationActionOptionNone
                                       textInputButtonTitle:reply[@"send"]
                                       textInputPlaceholder:reply[@"placeholder"]];
    UNNotificationCategory *category = [UNNotificationCategory categoryWithIdentifier:identifier
                                                                              actions:@[ action ]
                                                                    intentIdentifiers:@[]
                                                                              options:UNNotificationCategoryOptionNone];
    UNNotificationCategory *held = _categories[identifier];
    if (held != nil && [held.actions.firstObject.title isEqualToString:action.title] &&
        [((UNTextInputNotificationAction *)held.actions.firstObject).textInputPlaceholder
            isEqualToString:action.textInputPlaceholder]) {
        return identifier;
    }
    [_categoryOrder removeObject:identifier];
    [_categoryOrder addObject:identifier];
    _categories[identifier] = category;
    while (_categoryOrder.count > SZFriendsNotifyCategoryMax) {
        [_categories removeObjectForKey:_categoryOrder.firstObject];
        [_categoryOrder removeObjectAtIndex:0];
    }
    [_center setNotificationCategories:[NSSet setWithArray:_categories.allValues]];
    return identifier;
}

- (void)post:(NSDictionary<NSString *, id> *)request {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = request[@"title"];
    content.body = request[@"body"];
    content.threadIdentifier = request[@"thread"];
    content.sound = [UNNotificationSound defaultSound];
    NSString *category = [self categoryForRequest:request];
    if (category != nil) content.categoryIdentifier = category;
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
    if (json != nil) content.userInfo = @{@"request" : [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]};
    UNNotificationRequest *notification = [UNNotificationRequest requestWithIdentifier:request[@"key"]
                                                                               content:content
                                                                               trigger:nil];
    [_center addNotificationRequest:notification withCompletionHandler:nil];
}

- (void)withdrawThread:(NSString *)thread {
    UNUserNotificationCenter *center = _center;
    [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
        NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
        for (UNNotification *notification in notifications) {
            if ([notification.request.content.threadIdentifier isEqualToString:thread]) {
                [identifiers addObject:notification.request.identifier];
            }
        }
        if (identifiers.count > 0) [center removeDeliveredNotificationsWithIdentifiers:identifiers];
    }];
}

- (void)openURL:(NSString *)url appID:(NSString *)appID appPath:(nullable NSString *)appPath {
    (void)appID;
    // LaunchServices may take a moment to launch the app: never on the helper's queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ SZFriendsNotifyOpen(url, appPath); });
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    NSString *action = nil, *text = nil;
    SZFriendsNotifyResponseParts(response, &action, &text);
    NSString *key = response.notification.request.identifier;
    NSDictionary *request = SZFriendsNotifyRequestFromUserInfo(response.notification.request.content.userInfo);
    if (action != nil) {
        __weak SZFriendsNotifySystemPoster *weakSelf = self;
        dispatch_async(_queue, ^{
            SZFriendsNotifySystemPoster *strongSelf = weakSelf;
            if (strongSelf.onResponse) strongSelf.onResponse(key, action, text, request);
        });
    }
    completionHandler();
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    (void)center, (void)notification;
    // The helper is never the app in front: show it as any notification.
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionSound);
}

@end

#pragma mark - A helper launched for a click while another holds the lock

@interface SZFriendsNotifyForwarder : NSObject <UNUserNotificationCenterDelegate>
@property(atomic, copy, nullable) NSString *action, *text;
@property(atomic, copy, nullable) NSDictionary *request;
@property(atomic) BOOL answered;
@end

@implementation SZFriendsNotifyForwarder

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    NSString *action = nil, *text = nil;
    SZFriendsNotifyResponseParts(response, &action, &text);
    self.action = action;
    self.text = text;
    self.request = SZFriendsNotifyRequestFromUserInfo(response.notification.request.content.userInfo);
    self.answered = YES;
    completionHandler();
}

@end

typedef struct {
    char re[32];
    BOOL replied, ok;
} SZFriendsNotifyWait;

static void SZFriendsNotifyForwardFrame(void *context, const char *json, size_t length) {
    SZFriendsNotifyWait *wait = context;
    NSDictionary *frame = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:length] options:0
                                                            error:NULL];
    if (![frame isKindOfClass:[NSDictionary class]] || ![frame[@"type"] isEqual:@"reply"]) return;
    if ([frame[@"re"] isEqual:@(wait->re)]) {
        wait->replied = YES;
        wait->ok = [frame[@"ok"] boolValue];
    }
}

// Services the client until `done` or the deadline.
static BOOL SZFriendsNotifyPump(szfriends_client *client, CFAbsoluteTime deadline, BOOL (^done)(void)) {
    while (!done()) {
        if (CFAbsoluteTimeGetCurrent() > deadline) return NO;
        int fd = szfriends_client_fd(client);
        if (fd >= 0) {
            struct pollfd entry = {.fd = fd, .events = POLLIN};
            if (poll(&entry, 1, 50) > 0) szfriends_client_on_readable(client);
        } else {
            usleep(20 * 1000);
        }
        szfriends_client_tick(client, szfriends_monotonic_ms());
    }
    return YES;
}

static BOOL SZFriendsNotifySendIntent(szfriends_client *client, SZFriendsNotifyWait *wait, NSString *type,
                                      NSDictionary *fields) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    wait->replied = NO;
    if (szfriends_client_send(client, type.UTF8String, text.UTF8String, wait->re, sizeof(wait->re)) != SZFRIENDS_OK) {
        return NO;
    }
    return SZFriendsNotifyPump(client, CFAbsoluteTimeGetCurrent() + 5, ^BOOL { return wait->replied; }) && wait->ok;
}

// The reply as the person typed it, through the running helper: sent as send_message is, then the conversation opened
// for a moment, which marks it read there (and withdraws its notifications).
static void SZFriendsNotifyForwardReply(NSString *stateDirectory, NSString *conversationID, NSString *text) {
    SZFriendsNotifyWait wait = {{0}, NO, NO};
    szfriends_client_config config = {
        .state_dir = stateDirectory.fileSystemRepresentation,
        .helper_path = NULL,
        .app_id = "com.intuition.shenzhenfriends",
        .app_name = "Shenzhen Friends",
        .app_version = "1",
        .toolkit = "appkit",
        .reveal_in = "Finder",
        .locale = "en",
        .on_frame = SZFriendsNotifyForwardFrame,
        .context = &wait,
    };
    szfriends_client *client = szfriends_client_new(&config);
    if (client == NULL) return;
    szfriends_client_start(client);
    BOOL ready = SZFriendsNotifyPump(client, CFAbsoluteTimeGetCurrent() + 5, ^BOOL {
        return szfriends_client_state(client) == SZFRIENDS_CONNECTION_READY;
    });
    char token[33] = {0};
    if (ready && szfriends_client_token(token, sizeof(token)) == SZFRIENDS_OK &&
        SZFriendsNotifySendIntent(client, &wait, @"send_message",
                                  @{@"conversation_id" : conversationID, @"text" : text, @"client_token" : @(token)})) {
        SZFriendsNotifySendIntent(client, &wait, @"open_conversation", @{@"conversation_id" : conversationID});
    }
    szfriends_client_stop(client, false);
    szfriends_client_free(client);
}

void SZFriendsNotifyForwardLaunchResponse(NSString *stateDirectory) {
    @autoreleasepool {
        SZFriendsNotifyForwarder *forwarder = [[SZFriendsNotifyForwarder alloc] init];
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = forwarder;
        // The response that launched this process comes within moments of launch, if one did.
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 3;
        while (!forwarder.answered && CFAbsoluteTimeGetCurrent() < deadline) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        }
        center.delegate = nil;
        NSDictionary *request = forwarder.request;
        id conversation = request[@"conversation_id"];
        NSString *conversationID = [conversation isKindOfClass:[NSString class]] ? conversation : nil;
        if ([forwarder.action isEqualToString:@"reply"] && conversationID && forwarder.text.length > 0) {
            SZFriendsNotifyForwardReply(stateDirectory, conversationID, forwarder.text);
        } else if ([forwarder.action isEqualToString:@"open"]) {
            SZFriendsNotifySettings *settings = [[SZFriendsNotifySettings alloc] initWithStateDirectory:stateDirectory];
            SZFriendsNotifyTarget *target = settings.target;
            SZFriendsNotifyOpen([target URLForConversation:conversationID], target.appPath);
        }
    }
}
