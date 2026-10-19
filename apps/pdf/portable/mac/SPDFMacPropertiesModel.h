#pragma once
#import <Cocoa/Cocoa.h>
#include "shenzhen_pdf_core.h"

// Invoked only by Properties. Snapshots cheap core/file metadata; textInfo is
// optional active text-renderer state (text, pageCount, pageSize, format, language).
NSArray<NSDictionary*>* SPDFPropertiesSections(spdf_document* doc, NSString* sourcePath,
    NSString* inspectionPath, NSInteger pageIndex, NSInteger outlineCount, NSInteger annotationCount,
    NSDictionary* textInfo);
