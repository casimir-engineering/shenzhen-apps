#pragma once
#import "SPDFMacPassword.h"
#import "SPDFMacCollectionCredentials.h"
@interface SPDFMacCollectionCredentials (Documents)
+ (SPDFPasswordCredential*)credentialForSourcePath:(NSString*)path;
+ (BOOL)rememberCredential:(SPDFPasswordCredential*)credential forSourcePath:(NSString*)path error:(NSError**)error;
@end
