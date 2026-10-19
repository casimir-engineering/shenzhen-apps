#pragma once
#import <Foundation/Foundation.h>

// Invoked on the assistant worker only. Input is a private PDF rendition;
// output is installed exclusively after validation. No work occurs at load/init.
NSDictionary* SPDFAIRunPDFJob(NSString* kind, NSString* source, NSString* destination,
    NSString* executable, NSDictionary* environment, NSDictionary* options, NSProgress* progress, NSError** error);
BOOL SPDFAIJobReceiptIsCurrent(NSDictionary* receipt);
BOOL SPDFAIRemoveJobOutput(NSDictionary* receipt);

// Shared cancellable subprocess transport, also exercised with fake tools.
NSString* SPDFAIRunLocalTool(NSString* executable, NSArray<NSString*>* arguments,
    NSDictionary* environment, NSString* input, NSString* directory, NSProgress* progress, NSError** error);
