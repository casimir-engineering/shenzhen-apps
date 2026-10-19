#pragma once
#import <Foundation/Foundation.h>
#include "shenzhen_pdf_core.h"
// Explicit, bounded file transaction. No source mutation until a fresh staged
// document is successfully saved and its source revision is still unchanged.
NSDictionary* SPDFAIMutatePDF(NSString* path, NSString* expectedRevision, NSProgress* progress,
    BOOL (^mutation)(spdf_document* document, char* error, size_t length), NSError** error);
BOOL SPDFAIUndoFileTransaction(NSDictionary* receipt, NSProgress* progress, NSError** error);

BOOL SPDFAICanUndoFileTransaction(NSDictionary* receipt, NSProgress* progress);
