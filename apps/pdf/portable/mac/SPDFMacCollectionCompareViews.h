#pragma once
#import "SPDFMacCollectionCompare.h"

@interface SPDFCollectionCompareRail : NSView
@property(nonatomic, copy) NSArray<NSNumber*>* slots;
@property(nonatomic) NSUInteger slotCount;
@property(nonatomic, strong) NSColor* markerColor;
@property(nonatomic, copy) void (^jump)(CGFloat);
@end

@interface SPDFCollectionComparePane : NSView <NSTextFieldDelegate>
@property(nonatomic, strong) PDFView* reader;
@property(nonatomic, strong) SPDFCollectionCompareRail* rail;
@property(nonatomic, copy) void (^navigationChanged)(SPDFCollectionComparePane*);
@property(nonatomic, copy) void (^zoomChanged)(SPDFCollectionComparePane*);
@property(nonatomic, copy) NSArray<NSNumber*>* sourcePages;
- (instancetype)initWithLabel:(NSString*)label removed:(BOOL)removed;
- (void)installDocument:(PDFDocument*)document;
@property(nonatomic, readonly) NSUInteger currentSlot;
@property(nonatomic, readonly) PDFDestination* navigationDestination;
- (void)goToDestination:(PDFDestination*)destination;
// Following never emits navigation callbacks or interrupts a wheel gesture
// with PDFKit's destination-jump machinery. User input resumes normal updates.
- (void)applyLinkedDestination:(PDFDestination*)destination scaleFactor:(CGFloat)scaleFactor;
- (void)beginUserNavigation;
- (void)goToSlot:(NSUInteger)slot;
@end
