#pragma once
#import "SPDFMacCollectionWindow.h"
@class SPDFMacCollectionStore, SPDFPasswordCredential;
@interface SPDFCollectionCompanionHost : NSObject
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store open:(SPDFCollectionOpenHandler)open
                     navigate:(SPDFCollectionNavigateHandler)navigate;
- (BOOL)showSettingsWithError:(NSError**)error;
- (BOOL)showDocumentID:(NSString*)documentID query:(NSString*)query error:(NSError**)error;
@end
@interface SPDFCollectionCompanionRuntime : NSObject
+ (instancetype)activeRuntime;
- (SPDFPasswordCredential*)credentialForPaths:(NSArray<NSString*>*)paths;
@end
int SPDFRunCollectionCompanion(void);
