#pragma once
#import <Foundation/Foundation.h>
// What one request reads from the settings: copied when the person sends, so a switch flipped while the request
// runs applies to the next one. Immutable.
@interface SPDFMacAISettingsSnapshot : NSObject
@property(nonatomic, readonly, copy) NSString* model;
@property(nonatomic, readonly, copy) NSString* language;
@property(nonatomic, readonly) BOOL aiWebSearchEnabled;
@property(nonatomic, readonly) BOOL aiPythonEnabled;
@property(nonatomic, readonly) BOOL aiSubagentsEnabled;
@end
// Loading is explicit and cheap. Construction performs no I/O; setup reads happen after first paint.
@interface SPDFMacAISettings : NSObject
@property(nonatomic, copy) NSString* model;
// How much the chosen model reads at once, from the model catalog; 0 when not known.
@property(nonatomic) NSUInteger modelContextTokens;
@property(nonatomic, copy) NSString* language; // Stable language code, English by default.
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL connectionConfigured;
@property(nonatomic) BOOL automaticAnalysis;
@property(nonatomic) BOOL showSettingsOnLaunch;
@property(nonatomic) NSInteger onboardingRevision;
@property(nonatomic) NSInteger onboardingStep;
// Assistant capabilities (ai-agent-capabilities.md), each on unless the person turns it off. web_search_enabled,
// python_enabled and subagents_enabled in ai-settings.yaml. aiPythonEnabled is the person's switch: the Python tool
// is offered only while it is on AND its interpreter is installed, so it reads as on once installed.
@property(nonatomic) BOOL aiWebSearchEnabled;
@property(nonatomic) BOOL aiPythonEnabled;
@property(nonatomic) BOOL aiSubagentsEnabled;
+ (NSURL*)defaultURL;
- (instancetype)initWithURL:(NSURL*)URL;
- (BOOL)allowsRequestsForSetupRevision:(NSInteger)revision;
- (BOOL)load:(NSError**)error;
- (BOOL)save:(NSError**)error;
- (SPDFMacAISettingsSnapshot*)snapshot;
@end
