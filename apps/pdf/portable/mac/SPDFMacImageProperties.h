#pragma once
#import <Foundation/Foundation.h>

// Pure extension check: no filesystem access or decoder work.
BOOL SPDFPathIsRasterImage(NSString* path);
// On-demand header inspection only; no image decode and no work for other document types.
NSArray<NSDictionary*>* SPDFImagePropertyRows(NSString* path);
