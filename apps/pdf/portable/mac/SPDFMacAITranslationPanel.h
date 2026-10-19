#pragma once
#import <Cocoa/Cocoa.h>
@interface SPDFMacAITranslationPanel : NSWindowController <NSWindowDelegate>
@property(nonatomic,readonly) NSProgress* preparation;
@property(nonatomic,copy) NSArray<NSString*>* protectedSourcePaths;
@property(nonatomic,copy) void (^onClosed)(void);
@property(nonatomic,copy) void (^openCopy)(NSString* path);
// Build/show is explicit; displaying the panel never sends content.
- (instancetype)initWithSourceName:(NSString*)name language:(NSString*)language;
- (void)setSourceText:(NSString*)text error:(NSError*)error;
@end

FOUNDATION_EXPORT BOOL SPDFMacAITranslationCanSaveToURL(NSURL* destination, NSString* sourcePath);
