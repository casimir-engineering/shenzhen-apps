#pragma once
// The palette's and Annotate menus' icons: SF Symbols, with the ones this app draws itself (Fill's paint bucket, which
// SF Symbols doesn't have) and a stand-in for symbols newer than macOS 12, so no tool ever shows without its picture.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A template image for `symbol` ("spdf.paintbucket" for Fill), nil only for an empty name.
FOUNDATION_EXPORT NSImage* _Nullable SPDFAnnotateSymbolImage(NSString* _Nullable symbol, NSString* _Nullable label);

NS_ASSUME_NONNULL_END
