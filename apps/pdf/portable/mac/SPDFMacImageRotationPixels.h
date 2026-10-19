#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Returned image owns its permuted samples, retaining depth and color space.
CGImageRef SPDFCopyQuarterTurnImage(CGImageRef image, NSUInteger orientation, int degrees);
