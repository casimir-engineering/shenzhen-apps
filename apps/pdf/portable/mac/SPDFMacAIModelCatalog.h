#pragma once
#import <Foundation/Foundation.h>
// Each model is {id, name, supportsImages, supported_parameters} plus contextTokens when the catalog states it.
NSArray<NSDictionary*>* SPDFMacAIModelsFromCatalog(NSData* data, NSError** error);
NSDictionary* SPDFMacAIModelFromCatalog(NSData* data, NSString* identifier, NSError** error);
// Explicit picker/connection actions only. Never fetch during construction/launch.
NSURLSessionDataTask* SPDFMacAIFetchModels(void (^completion)(NSArray<NSDictionary*>*,NSError*));
NSURLSessionDataTask* SPDFMacAIValidateModel(NSString* identifier, void (^completion)(NSDictionary*,NSError*));
