#pragma once
#import <Foundation/Foundation.h>
@class SPDFMacAITransport, SPDFMacAISettings, SPDFMacAIAnalysisCache;
typedef NSDictionary* (^SPDFMacAIContextProvider)(NSString* path, BOOL landscape, NSProgress* progress, NSError** error);
typedef NSString* (^SPDFMacAIHashProvider)(NSString* path, NSProgress* progress, NSError** error);
typedef NSString* (^SPDFMacAIKeyProvider)(NSError** error);
// All extraction, hashes, cache I/O and credential access run on an explicitly started utility worker.
@interface SPDFMacAIAnalysisService : NSObject
@property(nonatomic) NSUInteger maximumRequestsPerSession; // Default 20; cached hits do not consume this budget.
- (instancetype)initWithCache:(SPDFMacAIAnalysisCache*)cache transport:(SPDFMacAITransport*)transport;
- (instancetype)initWithCache:(SPDFMacAIAnalysisCache*)cache transport:(SPDFMacAITransport*)transport
    contextProvider:(SPDFMacAIContextProvider)contextProvider hashProvider:(SPDFMacAIHashProvider)hashProvider
    keyProvider:(SPDFMacAIKeyProvider)keyProvider;
// Call only following a successful document read, with already loaded settings. Disabled requests do no work.
- (void)analyzeDocumentAtPath:(NSString*)path landscape:(BOOL)landscape settings:(SPDFMacAISettings*)settings
    completion:(void (^)(NSDictionary* analysis, NSError* error))completion;
- (void)analyzeCandidate:(NSDictionary*)candidate settings:(SPDFMacAISettings*)settings
    completion:(void (^)(NSDictionary* analysis, NSError* error))completion;
- (void)cancelAll;
@end
