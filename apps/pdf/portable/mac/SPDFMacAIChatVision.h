#pragma once
#import <Foundation/Foundation.h>
@class SPDFMacAIChatStore;
// Explicit request-time projection: transcript stays text + private asset references.
// Image decoding/encoding belongs on the request worker, never the document-open path.
NSArray* SPDFMacAIChatVisionMessages(NSArray* messages, NSString* chatID,
    SPDFMacAIChatStore* store, BOOL (^cancelled)(void));
