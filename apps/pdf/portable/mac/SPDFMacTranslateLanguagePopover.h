#pragma once
#import <Cocoa/Cocoa.h>
// Translate's one question: into which language. A popover under the Translate button, worked from the keyboard:
// it opens with the field focused and English highlighted, so Return translates into English at once. Typing narrows
// the list (recent languages first) and highlights the first match; Return chooses it and the line under the field
// says "⏎ translates into French"; Return again translates. A name that matches nothing becomes "Use “Breton”", so
// any language works. Arrows move, a click translates, Escape closes. Built when Translate is clicked, never earlier.
@interface SPDFMacTranslateLanguagePopover : NSObject
// `translate` gets the language's English name ("French") or the name typed ("Breton").
+ (instancetype)showRelativeToView:(NSView*)anchor translate:(void (^)(NSString* language))translate;
// The picker now open, or nil.
+ (instancetype)shownPicker;
@property(nonatomic, readonly) NSPopover* popover;
@property(nonatomic, readonly) NSSearchField* field;
// What a Return in the field does now (the suites and the offscreen check press it as the keyboard would).
- (void)pressReturn;
- (void)moveSelection:(NSInteger)delta;
- (void)close;
@end
// Languages chosen before, most recent first: English names or names typed. Kept in the user defaults.
FOUNDATION_EXPORT NSArray<NSString*>* SPDFMacTranslateRecentLanguages(void);
FOUNDATION_EXPORT void SPDFMacTranslateRememberLanguage(NSString* language);
