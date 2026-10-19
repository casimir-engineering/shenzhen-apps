#pragma once

#import <AppKit/AppKit.h>

@class SPDFTabStripView;

// Virtual children for the custom-drawn strip. The strip retains the returned
// array until its tabs or geometry change, as NSAccessibilityElement requires.
NSArray<NSAccessibilityElement*>* SPDFMacTabAccessibilityChildren(SPDFTabStripView* strip);
