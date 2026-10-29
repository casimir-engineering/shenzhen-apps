#pragma once
#import <Cocoa/Cocoa.h>
// Translate's one question: into which language, and who translates. A popover under the Translate button, worked
// from the keyboard. At its top a switch, "On this Mac" | "AI": Tab, ⌘1 and ⌘2 change it, and the choice is kept for
// next time ("On this Mac" the first time). It opens with the field focused and English highlighted, so Return
// translates into English at once. Typing narrows the list (recent languages first) and highlights the first match;
// Return chooses it and the line under the field says "⏎ translates into French"; Return again translates. On this
// Mac the list holds only the languages the Mac's translator has; with AI a name that matches nothing becomes
// "Use “Breton”", so any language works. Arrows move, a click translates, Escape closes. Built when Translate is
// clicked, never earlier.
@interface SPDFMacTranslateLanguagePopover : NSObject
// `localLanguages`: what "On this Mac" offers, as {code, name} with the name in English (spdf_translation_languages).
// `translate` gets the language's English name ("French") or the name typed ("Breton"), and, on this Mac, its code.
+ (instancetype)showRelativeToView:(NSView*)anchor localLanguages:(NSArray<NSDictionary<NSString*, NSString*>*>*)localLanguages
                         translate:(void (^)(NSString* language, NSString* localCode))translate;
// The picker now open, or nil.
+ (instancetype)shownPicker;
@property(nonatomic, readonly) NSPopover* popover;
@property(nonatomic, readonly) NSSearchField* field;
@property(nonatomic, readonly) NSSegmentedControl* engine;
// YES when "On this Mac" is chosen.
@property(nonatomic, readonly) BOOL onThisMac;
// What a Return in the field does now (the suites and the offscreen check press it as the keyboard would).
- (void)pressReturn;
- (void)moveSelection:(NSInteger)delta;
// Tab: the other engine. ⌘1 and ⌘2 choose one.
- (void)switchEngine;
- (void)chooseOnThisMac:(BOOL)onThisMac;
- (void)close;
@end
// Languages chosen before, most recent first: English names or names typed. Kept in the user defaults.
FOUNDATION_EXPORT NSArray<NSString*>* SPDFMacTranslateRecentLanguages(void);
FOUNDATION_EXPORT void SPDFMacTranslateRememberLanguage(NSString* language);
