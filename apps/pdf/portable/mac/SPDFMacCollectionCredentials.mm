#import "SPDFMacCollectionCredentials.h"
#import "SPDFMacPassword.h"
#import "SPDFMacKeychainNoninteractive.h"

@interface SPDFCollectionSystemKeychain : NSObject <SPDFCollectionKeychainAccess>
@end
@implementation SPDFCollectionSystemKeychain
- (OSStatus)copyMatching:(NSDictionary*)query result:(NSData**)result {
    __block CFTypeRef value=NULL;
    OSStatus status=SPDFKeychainWithoutInteraction(^{ return SecItemCopyMatching((__bridge CFDictionaryRef)query,&value); });
    id object=CFBridgingRelease(value);
    if (status==errSecSuccess && ![object isKindOfClass:NSData.class]) return errSecDecode;
    if (result) *result=object;
    return status;
}
- (OSStatus)add:(NSDictionary*)attributes {
    return SPDFKeychainWithoutInteraction(^{ return SecItemAdd((__bridge CFDictionaryRef)attributes,NULL); });
}
- (OSStatus)update:(NSDictionary*)query attributes:(NSDictionary*)attributes {
    return SPDFKeychainWithoutInteraction(^{ return SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)attributes); });
}
@end

static NSString* ValidHash(NSString* hash,NSError** error) {
    if ([hash isKindOfClass:NSString.class] && hash.length==64 &&
        [hash rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
            @"0123456789abcdefABCDEF"].invertedSet].location==NSNotFound) return hash.lowercaseString;
    if (error) *error=[NSError errorWithDomain:@"SPDFCollectionCredentials" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"A complete document content hash is required to remember its password."}];
    return nil;
}
static NSError* KeychainError(OSStatus status) {
    NSString* description=CFBridgingRelease(SecCopyErrorMessageString(status,NULL));
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
        userInfo:@{NSLocalizedDescriptionKey:description ?: @"The document password could not be accessed in Keychain."}];
}
static NSMutableDictionary* Query(NSString* hash) {
    // Background capture/thumbnail work must never summon Keychain authentication UI.
    // A locked/denied Keychain is reported to the caller, which can keep the session credential.
    NSMutableDictionary* query=[@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.intuition.shenzhenpdf.collection.password",
        (__bridge id)kSecAttrAccount:hash,(__bridge id)kSecAttrSynchronizable:@NO} mutableCopy];
    SPDFKeychainDisallowAuthenticationUI(query); return query;
}
@implementation SPDFMacCollectionCredentials {
    id<SPDFCollectionKeychainAccess> _keychain;
}
+ (instancetype)defaultCredentials {
    static SPDFMacCollectionCredentials* credentials; static dispatch_once_t once;
    dispatch_once(&once,^{ credentials=[[self alloc] initWithKeychain:[SPDFCollectionSystemKeychain new]]; });
    return credentials;
}
+ (BOOL)storeCredential:(SPDFPasswordCredential*)credential forHash:(NSString*)hash error:(NSError**)error {
    return [[self defaultCredentials] storeCredential:credential forHash:hash error:error];
}
+ (SPDFPasswordCredential*)credentialForHash:(NSString*)hash error:(NSError**)error {
    return [[self defaultCredentials] credentialForHash:hash error:error];
}
- (instancetype)initWithKeychain:(id<SPDFCollectionKeychainAccess>)keychain {
    if ((self=[super init])) _keychain=keychain;
    return self;
}
- (BOOL)storeCredential:(SPDFPasswordCredential*)credential forHash:(NSString*)hash error:(NSError**)error {
    if (error) *error=nil;
    NSString* account=ValidHash(hash,error); if (!account) return NO;
    if (!credential || !_keychain) {
        if (error) *error=KeychainError(errSecParam); return NO;
    }
    __block NSMutableData* data=nil;
    [credential withUTF8Password:^(const char* password) { data=[NSMutableData dataWithBytes:password length:strlen(password)]; }];
    NSMutableDictionary* query=Query(account), *attributes=[query mutableCopy];
    attributes[(__bridge id)kSecValueData]=data;
    OSStatus status=[_keychain add:attributes];
    if (status==errSecDuplicateItem)
        status=[_keychain update:query attributes:@{(__bridge id)kSecValueData:data}];
    // Security copied the bytes synchronously. Wipe our temporary transfer buffer.
    volatile unsigned char* bytes=(volatile unsigned char*)data.mutableBytes;
    for (NSUInteger i=0;i<data.length;i++) bytes[i]=0;
    if (status!=errSecSuccess && error) *error=KeychainError(status);
    return status==errSecSuccess;
}
- (SPDFPasswordCredential*)credentialForHash:(NSString*)hash error:(NSError**)error {
    if (error) *error=nil;
    NSString* account=ValidHash(hash,error); if (!account) return nil;
    NSMutableDictionary* query=Query(account);
    query[(__bridge id)kSecReturnData]=@YES; query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    NSData* bytes=nil; OSStatus status=_keychain ? [_keychain copyMatching:query result:&bytes] : errSecParam;
    if (status==errSecItemNotFound) return nil;
    if (status!=errSecSuccess) { if (error) *error=KeychainError(status); return nil; }
    NSString* password=[bytes isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
    if (!password || [password rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound) {
        if (error) *error=KeychainError(errSecDecode); return nil;
    }
    return [[SPDFPasswordCredential alloc] initWithPassword:password];
}
@end
