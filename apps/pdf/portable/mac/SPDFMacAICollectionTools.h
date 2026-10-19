#pragma once
#import <Foundation/Foundation.h>
// Worker-only Collection discovery. No Collection initialization on launch.
NSDictionary* SPDFAICollectionDocuments(NSString* query, NSUInteger first, NSProgress* progress);
NSDictionary* SPDFAICollectionOpenTarget(NSString* identifier, BOOL savedCopy, NSProgress* progress);
