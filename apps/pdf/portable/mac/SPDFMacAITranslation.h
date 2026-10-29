#pragma once
#import <Foundation/Foundation.h>
// A whole text document cut into parts the model translates one at a time (SPDFMacAIJobTranslator.h): at most 3,000
// characters, ending at a line break where one falls in the second half, never inside a character. Nothing is
// dropped: the parts joined are the text. nil with *error for no text or more than 500,000 characters.
FOUNDATION_EXPORT NSArray<NSString*>* SPDFMacAITranslationChunks(NSString* text, NSError** error);
