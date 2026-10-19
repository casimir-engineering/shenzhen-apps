#pragma once
#import <Foundation/Foundation.h>

// Explicit Save As worker operation. Image mode copies the original bytes;
// PDF mode exports every page. The original file is never a valid destination.
NSDictionary* SPDFImageSaveDestinationIdentity(NSString* path);
BOOL SPDFSaveImageCopy(NSString* source, NSString* destination, BOOL asPDF, NSError** error,
                       NSDictionary* expectedDestination = nil);
