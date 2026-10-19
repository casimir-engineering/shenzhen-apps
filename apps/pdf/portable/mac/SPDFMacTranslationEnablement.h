#pragma once

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacTranslationPolicy.h"

// The delegate's side of the Translate entry points: one description of the
// active tab, and the two commands driven from it. Implemented in
// SPDFMacTranslationEnablement.mm.
@interface ShenzhenMacDelegate (SPDFMacTranslationEnablement)
- (spdf_translation_context)translationContext;
- (void)updateTranslateCommandEnablement;
// The Translate command's front door: routes a selection to the selection
// panel, admits whole-document translation through a PDF rendition, and
// answers YES only when whole-document translation may actually proceed.
- (BOOL)beginTranslateCommandForSender:(id)sender;
@end
