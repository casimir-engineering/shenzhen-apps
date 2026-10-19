#pragma once
#import "SPDFMacCollectionWindow.h"
@interface SPDFMacCollectionWindow (HistoryDetail)
- (void)showHistoryForDocument:(NSDictionary*)document version:(NSDictionary*)version;
- (NSDictionary*)historySelectedDocument;
- (NSDictionary*)historySelectedVersion;
- (void)returnFromCollectionHistory:(id)sender;
@end
