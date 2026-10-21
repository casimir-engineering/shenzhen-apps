#pragma once
#import <Foundation/Foundation.h>

// Invoked on the assistant worker only. Input is a private PDF rendition; the output is made in a private scratch
// folder and, once validated, installed in `directory` as `name` or "name (2)"… (SPDFMacAIOutputFiles.h), never
// replacing a file. Receipt: {path, identity}. No work occurs at load/init.
NSDictionary* SPDFAIRunPDFJob(NSString* kind, NSString* source, NSString* directory, NSString* name,
    NSString* executable, NSDictionary* environment, NSDictionary* options, NSProgress* progress, NSError** error);
BOOL SPDFAIJobReceiptIsCurrent(NSDictionary* receipt);
BOOL SPDFAIRemoveJobOutput(NSDictionary* receipt);

// Shared cancellable subprocess transport, also exercised with fake tools.
NSString* SPDFAIRunLocalTool(NSString* executable, NSArray<NSString*>* arguments,
    NSDictionary* environment, NSString* input, NSString* directory, NSProgress* progress, NSError** error);
