#pragma once
// The New Signature / New Initials sheet: Draw, Type or Picture, then Use Signature. "Keep for next time" saves it in
// SPDFMacSignatureStore; otherwise the signature is used once and forgotten.
#import <Cocoa/Cocoa.h>

@class SPDFMacSignature;

@interface SPDFMacSignatureSheet : NSObject
// completion receives the new signature, or nil on Cancel. suggestedName types the Type tab's first text.
+ (void)beginForWindow:(NSWindow*)window
              initials:(BOOL)initials
         suggestedName:(NSString*)suggestedName
            completion:(void (^)(SPDFMacSignature* signature))completion;
@end
