#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
@protocol SPDFMacAIKeychainAccess <NSObject>
- (OSStatus)copyMatching:(NSDictionary*)query result:(NSData**)result;
- (OSStatus)add:(NSDictionary*)attributes;
- (OSStatus)update:(NSDictionary*)query attributes:(NSDictionary*)attributes;
- (OSStatus)remove:(NSDictionary*)query;
@optional
// May display system authentication UI; reachable only from explicit user action.
- (OSStatus)copyMatchingWithUserInteraction:(NSDictionary*)query result:(NSData**)result;
@end
@interface SPDFMacAICredentials : NSObject
+ (BOOL)storeAPIKey:(NSString*)key error:(NSError**)error;
+ (NSString*)APIKeyWithError:(NSError**)error;
// Explicit authorization button only. Background/launch callers must use APIKeyWithError.
+ (NSString*)authorizeAPIKeyAccessWithError:(NSError**)error;
+ (BOOL)removeAPIKeyWithError:(NSError**)error;
- (instancetype)initWithKeychain:(id<SPDFMacAIKeychainAccess>)keychain;
- (BOOL)storeAPIKey:(NSString*)key error:(NSError**)error;
- (NSString*)APIKeyWithError:(NSError**)error;
- (NSString*)authorizeAPIKeyAccessWithError:(NSError**)error;
- (BOOL)removeAPIKeyWithError:(NSError**)error;
@end
