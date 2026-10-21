// What the helper learns from a client's hello (PROTOCOL.md § Handshake): who to write strings for.

#import "client/szfriends_client.h"
#import "service/helper/SZFriendsHelperInternal.h"

static NSString *const SZFriendsClientContextErrorDomain = @"SZFriendsClientContext";

// App-supplied strings end up inside snapshot text ("the first time ShenzhenPDF goes online"), so they are
// bounded; real values are a dozen characters. Capabilities are a few dozen names; open_formats has its own,
// larger bound (szfriends_client.h).
static const NSUInteger SZFriendsClientStringMax = SZFRIENDS_MAX_HELLO_STRING;
static const NSUInteger SZFriendsClientListMax = 64;

@interface SZFriendsClientContext ()
@property(nonatomic, readwrite) NSString *appID;
@property(nonatomic, readwrite) NSString *appName;
@property(nonatomic, readwrite) NSString *appVersion;
@property(nonatomic, readwrite) NSString *toolkit;
@property(nonatomic, readwrite) NSString *revealIn;
@property(nonatomic, readwrite) NSString *locale;
@property(nonatomic, readwrite) NSSet<NSString *> *capabilities;
@property(nonatomic, readwrite) NSSet<NSString *> *openFormats;
@property(nonatomic, readwrite, nullable) NSString *urlScheme;
@property(nonatomic, readwrite) SZFriendsProtocolVersion negotiatedVersion;
@end

static NSError *SZFriendsFieldError(NSString *field) {
    return [NSError errorWithDomain:SZFriendsClientContextErrorDomain
                               code:1
                           userInfo:@{@"field" : field, NSLocalizedDescriptionKey : field}];
}

static NSString *_Nullable SZFriendsHelloString(NSDictionary *object, NSString *key, BOOL required) {
    id value = object[key];
    if (value == nil || value == [NSNull null]) return required ? nil : @"";
    if (!SZFriendsJSONIsString(value)) return nil;
    NSString *text = value;
    if (text.length > SZFriendsClientStringMax || (required && text.length == 0)) return nil;
    return text;
}

// A URL scheme as RFC 3986 spells one (a letter, then letters, digits, "+", "-" or "."), at most 32 characters;
// anything else is no scheme, since the helper builds the URL a notification opens from it.
static NSString *_Nullable SZFriendsHelloURLScheme(id value) {
    if (!SZFriendsJSONIsString(value) || [value length] == 0 || [value length] > 32) return nil;
    NSString *scheme = [value lowercaseString];
    NSCharacterSet *letters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"];
    NSMutableCharacterSet *allowed = [letters mutableCopy];
    [allowed addCharactersInString:@"0123456789+-."];
    if (![letters characterIsMember:[scheme characterAtIndex:0]]) return nil;
    if ([scheme rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return scheme;
}

static NSSet<NSString *> *_Nullable SZFriendsHelloStringSet(id value, NSUInteger max, BOOL lowercase) {
    if (![value isKindOfClass:[NSArray class]] || [value count] > max) return nil;
    NSMutableSet *set = [NSMutableSet set];
    for (id item in value) {
        if (!SZFriendsJSONIsString(item) || [item length] == 0 || [item length] > SZFriendsClientStringMax) return nil;
        [set addObject:lowercase ? [item lowercaseString] : item];
    }
    return set;
}

@implementation SZFriendsClientContext

+ (nullable instancetype)contextFromHello:(NSDictionary<NSString *, id> *)hello
                        negotiatedVersion:(SZFriendsProtocolVersion)version
                                    error:(NSError **)error {
    id client = hello[@"client"];
    if (![client isKindOfClass:[NSDictionary class]]) {
        if (error) *error = SZFriendsFieldError(@"client");
        return nil;
    }
    SZFriendsClientContext *context = [[self alloc] init];
    NSArray<NSString *> *required = @[ @"app_id", @"app_name", @"app_version", @"toolkit", @"reveal_in" ];
    NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
    for (NSString *key in required) {
        NSString *value = SZFriendsHelloString(client, key, YES);
        if (value == nil) {
            if (error) *error = SZFriendsFieldError([@"client." stringByAppendingString:key]);
            return nil;
        }
        values[key] = value;
    }
    context.appID = values[@"app_id"];
    context.appName = values[@"app_name"];
    context.appVersion = values[@"app_version"];
    // Any toolkit name is accepted: a later host (a Windows build) must not fail hello on an older helper, and
    // the helper words nothing by toolkit.
    context.toolkit = values[@"toolkit"];
    context.revealIn = values[@"reveal_in"];
    // Optional and new (protocol 1.0 hellos without it stay valid): a malformed one is ignored, never refused.
    context.urlScheme = SZFriendsHelloURLScheme(client[@"url_scheme"]);

    // M1 answers in English whatever the locale; a missing one is not worth refusing a client over.
    NSString *locale = SZFriendsHelloString(hello, @"locale", NO);
    if (locale == nil) {
        if (error) *error = SZFriendsFieldError(@"locale");
        return nil;
    }
    context.locale = locale.length > 0 ? locale : @"en";

    NSSet *capabilities = SZFriendsHelloStringSet(hello[@"capabilities"], SZFriendsClientListMax, NO);
    if (capabilities == nil) {
        if (error) *error = SZFriendsFieldError(@"capabilities");
        return nil;
    }
    // Lowercased: received files are matched against these by extension, whatever case the app listed.
    NSSet *formats = SZFriendsHelloStringSet(hello[@"open_formats"], SZFRIENDS_MAX_OPEN_FORMATS, YES);
    if (formats == nil) {
        if (error) *error = SZFriendsFieldError(@"open_formats");
        return nil;
    }
    context.capabilities = capabilities;
    context.openFormats = formats;
    context.negotiatedVersion = version;
    return context;
}

@end
