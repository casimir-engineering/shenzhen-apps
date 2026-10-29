#pragma once
#import <Foundation/Foundation.h>
@class SPDFMacAITransport;
// The assistant's model translating for document_job translate (SPDFMacAIDocumentJobs.h): the lines of a PDF, put back
// where each one was, or the whole text of a Markdown or text document. Called on a worker thread only: each call
// waits for the model, and returns nil with *error when it fails or `progress` is cancelled. Construction is inert.
@interface SPDFMacAIJobTranslator : NSObject
- (instancetype)initWithTransport:(SPDFMacAITransport*)transport model:(NSString*)model key:(NSString*)key
                         language:(NSString*)language;
// The language as the model is told it and as the output is named: "French", or a name the person typed ("Breton").
@property(nonatomic, readonly, copy) NSString* language;
// One translation per line, in order. A sentence may run over several lines; each keeps its own place.
- (NSArray<NSString*>*)translateLines:(NSArray<NSString*>*)lines progress:(NSProgress*)progress error:(NSError**)error;
// A whole Markdown or text document, part by part, keeping its Markdown.
- (NSString*)translateText:(NSString*)text progress:(NSProgress*)progress error:(NSError**)error;
@end
// "fr" or "French" -> "French"; a name not in the list as given, trimmed; nil when it can't be a language name.
FOUNDATION_EXPORT NSString* SPDFMacAITranslationLanguageName(NSString* value);
@protocol SPDFMacAIActivityReporting;
// A document_job translate in the chat: "Translating into French" with how far it has got and Cancel, which stops
// `progress`. Main thread. Returns what ends the row, called once when the job has finished, saying whether it
// failed; nil for other jobs.
FOUNDATION_EXPORT void (^SPDFMacAITranslationStep(id<SPDFMacAIActivityReporting> activity,
    NSDictionary* arguments, NSProgress* progress))(BOOL failed);
