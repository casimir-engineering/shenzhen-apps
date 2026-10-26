#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacAIToolsReader)
- (NSDictionary*)aiWorkspaceContext;
- (NSDictionary*)aiCurrentDocumentContext;
- (NSDictionary*)aiWorkspaceContextWithArguments:(NSDictionary*)arguments;
// `activity`: {entries: standardized path -> SPDFMacDocumentActivity entry, recordedSince} adds each document's
// last_opened and last_viewed and allows the notViewedSince filter; nil lists without them.
- (NSDictionary*)aiWorkspaceContextWithArguments:(NSDictionary*)arguments activity:(NSDictionary*)activity;
- (NSDictionary*)aiDocumentMetadataForPath:(NSString*)path;
- (NSArray<NSString*>*)aiDocumentPaths;
- (void)aiRememberAnalysis:(NSDictionary*)analysis forPath:(NSString*)path;
- (NSArray<NSDictionary*>*)aiDocumentCandidates;
- (NSDictionary*)aiDocumentCandidateForPath:(NSString*)path;
- (NSDictionary*)aiCaptureWorkspace;
- (NSString*)aiWorkspaceFingerprint;
- (BOOL)aiRestoreWorkspace:(NSDictionary*)snapshot expected:(NSString*)fingerprint;
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page;
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page query:(NSString*)query;
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page query:(NSString*)query progress:(NSProgress*)progress;
- (NSDictionary*)aiNavigateDocument:(NSString*)path page:(NSInteger)page query:(NSString*)query progress:(NSProgress*)progress
    sourcePath:(NSString*)sourcePath revision:(NSString*)revision;
- (void)aiCancelPendingCitation;
@end
