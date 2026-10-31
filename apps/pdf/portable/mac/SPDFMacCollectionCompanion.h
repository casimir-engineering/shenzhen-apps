#pragma once
#import "SPDFMacCollectionWindow.h"
@class SPDFMacCollectionStore, SPDFPasswordCredential;
@interface SPDFCollectionCompanionHost : NSObject
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store open:(SPDFCollectionOpenHandler)open
                     navigate:(SPDFCollectionNavigateHandler)navigate;
// The Collection window asked to remove documents from disk and Collection (confirmed there); `done` answers it.
@property(nonatomic, copy) void (^deleteHandler)(NSArray<NSString*>* documentIDs, void (^done)(NSArray<NSString*>* failures));
- (BOOL)showSettingsWithError:(NSError**)error;
- (BOOL)showDocumentID:(NSString*)documentID query:(NSString*)query error:(NSError**)error;
@end
@interface SPDFCollectionCompanionRuntime : NSObject
+ (instancetype)activeRuntime;
- (SPDFPasswordCredential*)credentialForPaths:(NSArray<NSString*>*)paths;
@end
int SPDFRunCollectionCompanion(void);
