#pragma once
#import <Foundation/Foundation.h>
// Explicit edit only; no decode, scan, or filesystem work during app launch.
BOOL SPDFRotateImageAtPath(NSString* path, int degrees, NSError** error);
