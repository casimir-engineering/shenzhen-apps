#pragma once
#import <Cocoa/Cocoa.h>
#include "shenzhen_pdf_core.h"

// Build once per matching page; geometry selects the actual hit's context.
@interface SPDFMacFindContext : NSObject
- (instancetype)initWithLines:(const spdf_text_lines*)lines query:(NSString*)query
                        regex:(BOOL)regex multiline:(BOOL)multiline;
- (NSDictionary*)contextForMatchRect:(NSRect)rect;
@end
