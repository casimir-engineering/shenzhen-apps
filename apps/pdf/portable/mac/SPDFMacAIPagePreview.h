#pragma once
#import <Foundation/Foundation.h>
// Generates one bounded, light-theme page image in a private owned directory.
// The caller owns cleanup, including cancellation and deleted conversations.
NSDictionary* SPDFAIPagePreview(NSString* path, BOOL landscape, NSUInteger page,
    NSProgress* progress, NSError** error);

NSDictionary* SPDFAIPagePreviewForCandidate(NSDictionary* candidate, NSUInteger page,
    NSProgress* progress, NSError** error);

// Optional region uses normalized top-left x/y/width/height in [0,1]. maxDimension
// defaults to 1600, accepts 256..2400. Crops render directly into a bounded bitmap.
// Result adds pixelWidth/pixelHeight, pageWidth/pageHeight (points), region, maxDimension.
NSDictionary* SPDFAIPagePreviewWithOptions(NSString* path, BOOL landscape, NSUInteger page,
    NSDictionary* options, NSProgress* progress, NSError** error);
NSDictionary* SPDFAIPagePreviewForCandidateWithOptions(NSDictionary* candidate, NSUInteger page,
    NSDictionary* options, NSProgress* progress, NSError** error);
