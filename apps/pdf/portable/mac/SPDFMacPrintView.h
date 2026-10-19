#import <Cocoa/Cocoa.h>

#import "SPDFMacModels.h"

@class PDFDocument;

typedef NS_ENUM(NSInteger, SPDFPrintScalingMode) {
    SPDFPrintScalingModeFit = 0,
    SPDFPrintScalingModeActualSize = 1,
    SPDFPrintScalingModeCustom = 2,
};

NSString* SPDFPrintScalingModeTitle(SPDFPrintScalingMode mode);
CGFloat SPDFClampPrintCustomScale(CGFloat scale);

@interface SPDFPrintScalingAccessoryController : NSViewController <NSPrintPanelAccessorizing>
@property(nonatomic) SPDFPrintScalingMode scalingMode;
@property(nonatomic) CGFloat customScale;
@property(nonatomic, copy) void (^changeHandler)(SPDFPrintScalingMode mode, CGFloat customScale);
- (instancetype)initWithScalingMode:(SPDFPrintScalingMode)scalingMode customScale:(CGFloat)customScale;
@end

@interface SPDFPDFKitPrintView : NSView
@property(nonatomic, strong) PDFDocument* pdfDocument;
@property(nonatomic) SPDFPrintScalingMode scalingMode;
@property(nonatomic) CGFloat customScale;
@end

@interface SPDFPrintView : NSView
@property(nonatomic) spdf_document* document;
@property(nonatomic) NSInteger pageCount;
@property(nonatomic) CGFloat targetDPI;
@property(nonatomic) SPDFPrintScalingMode scalingMode;
@property(nonatomic) CGFloat customScale;
@property(nonatomic, copy) NSArray<SPDFRenderedPage*>* fallbackPages;
@end
