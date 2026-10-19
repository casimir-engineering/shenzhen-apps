#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
@class SPDFPasswordCredential;

// Injectable Security boundary: tests exercise the real policy without reading
// or modifying the user's Keychain. Production creates this adapter lazily.
@protocol SPDFCollectionKeychainAccess <NSObject>
- (OSStatus)copyMatching:(NSDictionary*)query result:(NSData**)result;
- (OSStatus)add:(NSDictionary*)attributes;
- (OSStatus)update:(NSDictionary*)query attributes:(NSDictionary*)attributes;
@end
@interface SPDFMacCollectionCredentials : NSObject
+ (BOOL)storeCredential:(SPDFPasswordCredential*)credential forHash:(NSString*)hash error:(NSError**)error;
+ (SPDFPasswordCredential*)credentialForHash:(NSString*)hash error:(NSError**)error;
- (instancetype)initWithKeychain:(id<SPDFCollectionKeychainAccess>)keychain;
- (BOOL)storeCredential:(SPDFPasswordCredential*)credential forHash:(NSString*)hash error:(NSError**)error;
- (SPDFPasswordCredential*)credentialForHash:(NSString*)hash error:(NSError**)error;
@end
