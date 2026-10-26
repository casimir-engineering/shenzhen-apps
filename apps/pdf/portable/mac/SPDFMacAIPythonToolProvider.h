#pragma once
// run_python(code, files?, documents?): the assistant runs Python 3 in the sandbox helper
// (mac/python-sandbox/SPDFPythonSandbox.h) with numpy, pandas and matplotlib, and gets back what it printed, the files
// it wrote as text and tables, and its PNG images, which the chat shows with Save
// (portable/docs/plans/ai-agent-capabilities.md § 4).
//
// Documents: `documents` names what the code may read, by the ids the assistant already uses (doc:, collection:,
// attachment:), and SPDFMacAIPythonDocuments.h prepares them as ./documents, read only, with embedded images at
// native resolution and rendered pages when asked. Nothing else of the person's is readable. Files: what the code
// saves in ./out is kept (SPDFMacAIPythonOutputs.h): Downloads, documents also Collection, a card for each, only in
// the person's own request (not a subagent's, not one that read Friends chats).
//
// Offered while Settings' Python switch (aiPythonEnabled) is on and the sandbox has not reported that it cannot run
// on this Mac. Until the assistant's Python is installed, a call runs nothing: it adds a card asking the person to
// install it, and only their press of Install starts the download. Read-only, so subagents may run it too: a run
// changes nothing outside its own work directory, which is deleted afterwards.
#import <Foundation/Foundation.h>

#import "SPDFMacAIPythonDocuments.h"
#import "SPDFMacAIPythonInstall.h"
#import "SPDFMacAIPythonOutputs.h"
#import "SPDFMacAIPythonRunner.h"
#import "SPDFMacAIToolProvider.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAIPythonToolName; // "run_python"

// The OpenAI-style function definition the model is offered.
NSDictionary* SPDFMacAIPythonToolDefinition(void);

// YES once a run in this process was refused because the sandbox could not be applied on this Mac: Settings then
// says the switch cannot take effect here. Main thread.
BOOL SPDFMacAIPythonSandboxRefused(void);

@interface SPDFMacAIPythonToolProvider : NSObject <SPDFMacAIToolProvider>
- (instancetype)initWithRunner:(id<SPDFMacAIPythonRunning>)runner
                   environment:(id<SPDFMacAIPythonEnvironment>)environment NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// At most this many runs at once (subagents may call in parallel): each may hold 512 MB. 2.
@property(nonatomic) NSUInteger maximumConcurrentRuns;
// Finds the documents a run asks for; nil offers none (the model is told).
@property(nonatomic, copy, nullable) SPDFMacAIPythonDocumentResolver documentResolver;
// Keeps a file from ./out and shows it; nil keeps none (the model is told).
@property(nonatomic, copy, nullable) SPDFMacAIPythonOutputSaver saveOutput;
@property(nonatomic, copy, nullable) SPDFMacAIPythonOutputPresenter showOutput;
@end

NS_ASSUME_NONNULL_END
