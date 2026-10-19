#pragma once
#import <Foundation/Foundation.h>

// Pure capability checks: no decoding, indexing, tool discovery or file access.
BOOL SPDFOCRPathSupported(NSString* path);
BOOL SPDFOCRPathNeedsPDF(NSString* path);
// Runs only after an explicit command, on a worker queue. Owns its MuPDF document;
// exports every page and never overwrites the source or an existing rendition.
NSString* SPDFCreateToolPDF(NSString* source, NSString* suffix, NSError** error, NSString* destinationDirectory = nil);
