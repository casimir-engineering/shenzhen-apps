#pragma once
// Saved signatures and initials, My Details and saved texts for Fill & Sign (docs/plans/fill-and-sign.md, UI).
//
// Kept in <state>/FillSign/: index.json lists the signatures, <id>.json holds a drawing's outlines, <id>.png a
// picture, details.json My Details and saved texts. The folder is 0700 and every file 0600, written to a temporary
// file and renamed. Each window is its own process, so every read checks the index's date and reloads when another
// window changed it. Nothing here is touched before Fill & Sign is first used.
#import <Cocoa/Cocoa.h>

@interface SPDFMacSignature : NSObject
@property(nonatomic, copy) NSString* identifier;  // lower-case hex, never a '-' (the /NM ends the id at the first one)
@property(nonatomic) BOOL initials;
@property(nonatomic, copy) NSString* source;      // "drawn", "typed" or "picture"
@property(nonatomic) NSInteger ink;               // 0 black, 1 blue
@property(nonatomic) CGFloat aspect;              // width / height
@property(nonatomic, copy) NSArray<NSString*>* paths;  // filled outlines in a box one unit high, y down (M L C Q Z)
@property(nonatomic, copy) NSData* png;           // a picture signature, transparent background
@property(nonatomic, copy) NSDate* created;
@property(nonatomic, copy) NSDate* lastUsed;
- (void)getRGB:(float[3])rgb;
- (NSColor*)inkColor;
// Draws the signature fitted into rect (y down when the current view is flipped).
- (void)drawInRect:(NSRect)rect flipped:(BOOL)flipped alpha:(CGFloat)alpha;
- (NSImage*)thumbnailWithHeight:(CGFloat)height;
@end

@interface SPDFMacSignatureStore : NSObject
+ (instancetype)sharedStore;
// Most recently used first.
- (NSArray<SPDFMacSignature*>*)signaturesForInitials:(BOOL)initials;
- (SPDFMacSignature*)lastUsedForInitials:(BOOL)initials;
- (SPDFMacSignature*)signatureWithIdentifier:(NSString*)identifier;
- (BOOL)saveSignature:(SPDFMacSignature*)signature error:(NSError**)error;
- (void)removeSignature:(SPDFMacSignature*)signature;
- (void)markUsed:(SPDFMacSignature*)signature;

// My Details: "name", "initials", "email" (all optional).
- (NSDictionary<NSString*, NSString*>*)details;
- (void)setDetails:(NSDictionary<NSString*, NSString*>*)details;
- (NSArray<NSString*>*)savedTexts;
- (void)addSavedText:(NSString*)text;
@property(nonatomic) BOOL formHintSeen;
@end

// Parses outlines (absolute M L C Q Z) into a path in the unit box, y down.
NSBezierPath* SPDFSignatureBezierPath(NSArray<NSString*>* paths);
