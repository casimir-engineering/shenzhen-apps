#import "SPDFMacAICredentials.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacKeychainNoninteractive.h"
@interface SPDFMacAISystemKeychain : NSObject <SPDFMacAIKeychainAccess> @end
@implementation SPDFMacAISystemKeychain
- (OSStatus)copyMatching:(NSDictionary*)query result:(NSData**)result {
    __block CFTypeRef object=NULL;
    OSStatus status=SPDFKeychainWithoutInteraction(^{ return SecItemCopyMatching((__bridge CFDictionaryRef)query,&object); });
    id value=CFBridgingRelease(object); if(result)*result=[value isKindOfClass:NSData.class] ? value : nil;
    return status==errSecSuccess && ![value isKindOfClass:NSData.class] ? errSecDecode : status;
}
- (OSStatus)copyMatchingWithUserInteraction:(NSDictionary*)query result:(NSData**)result {
    __block CFTypeRef object=NULL;
    OSStatus status=SPDFKeychainForExplicitAuthorization(^{ return SecItemCopyMatching((__bridge CFDictionaryRef)query,&object); });
    id value=CFBridgingRelease(object);if(result)*result=[value isKindOfClass:NSData.class] ? value : nil;
    return status==errSecSuccess && ![value isKindOfClass:NSData.class] ? errSecDecode : status;
}
- (OSStatus)add:(NSDictionary*)attributes {
    return SPDFKeychainWithoutInteraction(^{ return SecItemAdd((__bridge CFDictionaryRef)attributes,NULL); });
}
- (OSStatus)update:(NSDictionary*)query attributes:(NSDictionary*)attributes {
    return SPDFKeychainWithoutInteraction(^{ return SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)attributes); });
}
- (OSStatus)remove:(NSDictionary*)query {
    return SPDFKeychainWithoutInteraction(^{ return SecItemDelete((__bridge CFDictionaryRef)query); });
}
@end
static NSMutableDictionary* Query(BOOL explicitAuthorization=NO) {
    NSMutableDictionary* query=[@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.intuition.shenzhenpdf.openrouter",
        (__bridge id)kSecAttrAccount:@"api-key",(__bridge id)kSecAttrSynchronizable:@NO} mutableCopy];
    if(explicitAuthorization)SPDFKeychainAllowAuthenticationUIForExplicitAction(query);
    else SPDFKeychainDisallowAuthenticationUI(query);return query;
}
static BOOL ValidKey(NSString* key) {
    return [key isKindOfClass:NSString.class] && [key hasPrefix:@"sk-or-"] && key.length>=20 && key.length<=512 &&
        [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location==NSNotFound;
}
@implementation SPDFMacAICredentials { id<SPDFMacAIKeychainAccess> _keychain; }
+ (instancetype)defaultCredentials {
    static SPDFMacAICredentials* value; static dispatch_once_t once;
    dispatch_once(&once,^{ value=[[self alloc] initWithKeychain:[SPDFMacAISystemKeychain new]]; }); return value;
}
+ (BOOL)storeAPIKey:(NSString*)key error:(NSError**)error { return [[self defaultCredentials] storeAPIKey:key error:error]; }
+ (NSString*)APIKeyWithError:(NSError**)error { return [[self defaultCredentials] APIKeyWithError:error]; }
+ (NSString*)authorizeAPIKeyAccessWithError:(NSError**)error { return [[self defaultCredentials] authorizeAPIKeyAccessWithError:error]; }
+ (BOOL)removeAPIKeyWithError:(NSError**)error { return [[self defaultCredentials] removeAPIKeyWithError:error]; }
- (instancetype)initWithKeychain:(id<SPDFMacAIKeychainAccess>)keychain { if((self=[super init]))_keychain=keychain; return self; }
- (BOOL)storeAPIKey:(NSString*)key error:(NSError**)error {
    if(error)*error=nil;
    if(!ValidKey(key)) { if(error)*error=SPDFMacAIError(20,@"Enter a valid OpenRouter API key."); return NO; }
    NSMutableData* bytes=[[key dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    NSMutableDictionary* query=Query(); NSMutableDictionary* attributes=[query mutableCopy];
    attributes[(__bridge id)kSecValueData]=bytes;
    attributes[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    OSStatus status=[_keychain add:attributes];
    if(status==errSecDuplicateItem) status=[_keychain update:query attributes:@{(__bridge id)kSecValueData:bytes}];
    volatile uint8_t* memory=(volatile uint8_t*)bytes.mutableBytes;
    for(NSUInteger i=0;i<bytes.length;i++) memory[i]=0;
    if(status!=errSecSuccess && error)*error=SPDFMacAIError(status,@"The OpenRouter key could not be saved in Keychain.");
    return status==errSecSuccess;
}
- (NSString*)APIKeyWithError:(NSError**)error { return [self readAPIKeyWithAuthorization:NO error:error]; }
- (NSString*)authorizeAPIKeyAccessWithError:(NSError**)error { return [self readAPIKeyWithAuthorization:YES error:error]; }
- (NSString*)readAPIKeyWithAuthorization:(BOOL)authorize error:(NSError**)error {
    if(error)*error=nil; NSMutableDictionary* query=Query(authorize);
    query[(__bridge id)kSecReturnData]=@YES; query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    NSData* bytes=nil;
    OSStatus status=authorize ? ([_keychain respondsToSelector:@selector(copyMatchingWithUserInteraction:result:)] ?
        [_keychain copyMatchingWithUserInteraction:query result:&bytes] : errSecUnimplemented) :
        [_keychain copyMatching:query result:&bytes];
    if(status==errSecItemNotFound) return nil;
    NSString* key=status==errSecSuccess ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
    if(!ValidKey(key)) { if(error)*error=SPDFMacAIError(status,@"Unlock Keychain or reconnect OpenRouter in Settings."); return nil; }
    return key;
}
- (BOOL)removeAPIKeyWithError:(NSError**)error {
    if(error)*error=nil; OSStatus status=[_keychain remove:Query()];
    if(status==errSecSuccess || status==errSecItemNotFound)return YES;
    if(error)*error=SPDFMacAIError(status,@"The OpenRouter connection could not be removed from Keychain."); return NO;
}
@end
