#pragma once
// The text box laid exactly over a field or a placed text while typing, with the suggestions row under it when it is
// empty (My Details, today's date, saved texts). Return, Tab, Shift-Tab and Escape behave as in a form; a placed text
// box sits on the same baseline MuPDF draws it on (spdf_fill_text_rect), so committing never moves the words.
#import <Cocoa/Cocoa.h>

#import "SPDFMacFillModel.h"

@class SPDFMacFillEditor, SPDFMacFillOverlayView;

@protocol SPDFMacFillEditorDelegate <NSObject>
// move: 0 stay, 1 next field, -1 previous field.
- (void)fillEditor:(SPDFMacFillEditor*)editor commitMoving:(NSInteger)move;
- (void)fillEditorDidCancel:(SPDFMacFillEditor*)editor;
- (void)fillEditorFlush:(SPDFMacFillEditor*)editor;
- (void)fillEditorEditDetails:(SPDFMacFillEditor*)editor;
@end

@interface SPDFMacFillSuggestion : NSObject
@property(nonatomic, copy) NSString* text;
+ (instancetype)suggestionWithText:(NSString*)text;
@end

@interface SPDFMacFillEditor : NSView
@property(nonatomic, weak) id<SPDFMacFillEditorDelegate> delegate;
@property(nonatomic, strong) SPDFFillField* field;            // a real field, or nil
@property(nonatomic, strong) SPDFFillItem* item;              // placed text being edited, or nil
@property(nonatomic, copy) NSArray<SPDFFillItem*>* combItems; // the cells of a placed comb entry being edited
@property(nonatomic) NSInteger page;
@property(nonatomic) NSRect box;            // page space: the field, or the text box of placed text
@property(nonatomic) CGFloat fontSize;      // page points
@property(nonatomic) BOOL multiline;
@property(nonatomic) NSInteger maxLength;   // 0: no limit
@property(nonatomic, copy) NSArray<NSValue*>* combCells;  // page rects, one character each
@property(nonatomic, copy) NSString* originalText;
@property(nonatomic) BOOL darkPage;         // the reading theme shows pages dark
@property(nonatomic, readonly) NSString* text;
@property(nonatomic) BOOL dirty;            // changed since the last flush

- (void)beginInOverlay:(SPDFMacFillOverlayView*)overlay
                  text:(NSString*)text
           suggestions:(NSArray<SPDFMacFillSuggestion*>*)suggestions
           highlighted:(NSInteger)highlighted;
- (void)layoutInOverlay:(SPDFMacFillOverlayView*)overlay;
- (void)setSuggestions:(NSArray<SPDFMacFillSuggestion*>*)suggestions;
- (void)commitAndClose;
- (void)close;
- (void)flushIfNeeded;
// The page-space box placed text needs for what was typed: at least the snapped box, wider for a long line, one line
// taller per extra line.
- (NSRect)placedTextBox;
- (NSInteger)lineCount;
@end
