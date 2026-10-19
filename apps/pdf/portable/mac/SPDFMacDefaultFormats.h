#pragma once
#import <Foundation/Foundation.h>
// Pure catalog; OS reads/writes are explicit and only occur in setup/settings.
NSArray<NSDictionary*>* SPDFMacDefaultFormats(void);
NSArray<NSDictionary*>* SPDFMacDefaultFormatStatus(void);
BOOL SPDFMacMakeDefaultForFormat(NSString* extension, NSError** error);
