#import <Cocoa/Cocoa.h>

#include "shenzhen_pdf_core.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDFPasswordCredential : NSObject
- (instancetype)initWithPassword:(NSString*)password NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)withUTF8Password:(void (^)(const char* password))block;
@end

@interface SPDFPasswordCredentialStore : NSObject
+ (instancetype)sharedStore;
- (nullable SPDFPasswordCredential*)credentialForSourcePath:(NSString*)sourcePath;
- (void)setCredential:(SPDFPasswordCredential*)credential forSourcePath:(NSString*)sourcePath;
- (void)invalidateCredentialForSourcePath:(NSString*)sourcePath;
- (nullable NSString*)sourceIdentityTokenForSourcePath:(NSString*)sourcePath;
- (NSString*)cacheTokenForSourcePath:(NSString*)sourcePath;
- (void)removeAllCredentials;
@end

spdf_document* _Nullable SPDFOpenDocumentWithCredential(NSString* openPath, SPDFPasswordCredential* _Nullable credential,
                                                         spdf_open_status* _Nullable status,
                                                         spdf_authentication* _Nullable authentication, char* error,
                                                         size_t errorLength);
spdf_document* _Nullable SPDFOpenDocumentWithStoredCredential(NSString* openPath, NSString* sourcePath,
                                                               spdf_open_status* _Nullable status,
                                                               spdf_authentication* _Nullable authentication, char* error,
                                                               size_t errorLength);

typedef NS_ENUM(NSInteger, SPDFPasswordAttemptResult) {
    SPDFPasswordAttemptSucceeded,
    SPDFPasswordAttemptIncorrect,
    SPDFPasswordAttemptFailed
};

typedef void (^SPDFPasswordAttemptCompletion)(SPDFPasswordAttemptResult result, NSString* _Nullable detail);
typedef void (^SPDFPasswordAttemptHandler)(SPDFPasswordCredential* credential,
                                           SPDFPasswordAttemptCompletion completion);

@interface SPDFPasswordSheetController : NSObject
- (instancetype)initWithParentWindow:(NSWindow*)parentWindow
                         displayName:(NSString*)displayName
                      attemptHandler:(SPDFPasswordAttemptHandler)attemptHandler
                       cancelHandler:(dispatch_block_t)cancelHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)begin;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
