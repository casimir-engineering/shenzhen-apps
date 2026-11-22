#pragma once
#import <Cocoa/Cocoa.h>

// OCR's one question, asked the way Translate asks its own: a popover under the OCR button with, at its top, who reads
// the text, "Open source" (Tesseract, through OCRmyPDF) | "macOS" (Apple's text recognition). Tab, ⌘1 and ⌘2 switch;
// the choice is kept for next time (macOS the first time, SPDFMacPictureText.h). Open source asks for the language
// (the last one chosen selected); macOS finds it. Return or the button runs it, Escape closes. Built when OCR is
// clicked, never earlier.
@interface SPDFMacOCRChoicePopover : NSObject
// `languages`: Tesseract's, as {code, name} (spdf_ocr_languages). `run` gets the engine (SPDFMacOCREngine...) and, for
// open source, the language chosen.
+ (instancetype)showRelativeToView:(NSView*)anchor
                         languages:(NSArray<NSDictionary<NSString*, NSString*>*>*)languages
                               run:(void (^)(NSString* engine, NSDictionary<NSString*, NSString*>* language))run;
+ (instancetype)shownPicker;
@property(nonatomic, readonly) NSPopover* popover;
@property(nonatomic, readonly) NSSegmentedControl* engine;
@property(nonatomic, readonly) NSPopUpButton* language;
- (void)chooseOpenSource:(BOOL)openSource;
- (void)runChosen;
- (void)close;
@end
