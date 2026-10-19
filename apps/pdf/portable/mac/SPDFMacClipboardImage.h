#pragma once
#import <Cocoa/Cocoa.h>

// Availability only reads advertised types; decoding/storage is explicit work.
BOOL SPDFClipboardHasDocument(NSPasteboard* pasteboard);
NSData* SPDFClipboardImageData(NSPasteboard* pasteboard);
// Worker-only. Preserves PNG/TIFF/JPEG bytes, including alpha and image frames.
NSString* SPDFStoreClipboardImage(NSData* data, NSString* directory, NSError** error);
