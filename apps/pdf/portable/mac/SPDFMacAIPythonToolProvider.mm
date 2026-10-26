#import "SPDFMacAIPythonToolProvider.h"

#import "SPDFMacAIChatActivity.h"
#import "SPDFMacAIPythonResults.h"
#import "SPDFMacAISettings.h"

NSString* const SPDFMacAIPythonToolName = @"run_python";

static const NSUInteger kSPDFMaxFiles = 8;
static const NSUInteger kSPDFMaxCodeCharacters = 60000;
static NSString* const kSPDFInstallAction = @"install";
static NSString* const kSPDFSandboxUnavailable =
    @"Python cannot run on this Mac because its sandbox could not be applied, so the code did not run. Answer "
    @"without running code.";

NSString* const SPDFMacAIPythonPromptGuidance =
    @"run_python can read the documents you can see, exactly: list them in its documents argument to get each PDF "
    @"page's embedded images at native resolution, losslessly, or pages rendered at a chosen dpi, then measure "
    @"pixels, tables or data in the code yourself. Never ask the person to export files or run code you can run. Save "
    @"files they should keep (reports, CSV, charts) in ./out.";

static NSDictionary* SPDFDescribed(NSDictionary* schema, NSString* description) {
    NSMutableDictionary* described = [schema mutableCopy];
    described[@"description"] = description;
    return described;
}

NSDictionary* SPDFMacAIPythonToolDefinition(void) {
    NSDictionary* file = @{@"type" : @"object", @"additionalProperties" : @NO, @"required" : @[ @"name", @"content" ],
        @"properties" : @{@"name" : @{@"type" : @"string", @"description" : @"A plain file name such as data.csv."},
                          @"content" : @{@"type" : @"string", @"description" : @"The file's text."}}};
    NSDictionary* pages = @{@"type" : @"array", @"maxItems" : @10, @"items" : @{@"type" : @"integer", @"minimum" : @1}};
    NSDictionary* document = @{@"type" : @"object", @"additionalProperties" : @NO, @"required" : @[ @"id" ],
        @"properties" : @{
            @"id" : @{@"type" : @"string", @"description" : @"doc: id from list_workspace, collection: id from "
                                                            @"list_collection, or attachment: id of a file or folder "
                                                            @"the person gave this chat."},
            @"path" : @{@"type" : @"string", @"description" : @"For an attached folder: a file inside it, relative "
                                                              @"to it, to extract images from or render."},
            @"images_on_pages" : SPDFDescribed(pages,
                @"PDF pages (from 1) whose embedded images to extract at native resolution, losslessly: PNG, or the "
                @"original JPEG bytes."),
            @"render_pages" : SPDFDescribed(pages,
                @"PDF pages (from 1) to render whole as PNG at dpi."),
            @"dpi" : @{@"type" : @"integer", @"minimum" : @36, @"maximum" : @600,
                       @"description" : @"Resolution for render_pages; default 150."}}};
    return @{@"type" : @"function", @"function" : @{
        @"name" : SPDFMacAIPythonToolName,
        @"description" :
            @"Run Python 3 code on the person's Mac in a sandbox: numpy, pandas, matplotlib and Pillow; no network; at "
            @"most 30 seconds and 512 MB of memory. It reads the documents you can see, exactly: list them in "
            @"documents and they appear read only under ./documents, with ./documents/index.json saying which file "
            @"is which (each document's own file, the images extracted from images_on_pages with their size and "
            @"colour space, the pages rendered from render_pages). Measure pixels and data from those files yourself; "
            @"never ask the person to export them or run code. Large images: crop first and use uint8 or float32 "
            @"arrays. Nothing else of theirs is readable. Files you pass in files are written to the working "
            @"directory first. Print what you need (the first 64 KB is returned). PNG charts saved in the working "
            @"directory are shown in the chat; CSV files there come back as tables, other text files as text. Save "
            @"files the person should keep (PDF or Markdown reports, CSV, PNG, any type) in ./out: each one is saved "
            @"to their Downloads folder, PDFs and Markdown also to Collection, and the chat shows each with Open and "
            @"Show in Finder. Every call starts fresh; nothing is kept between runs.",
        @"parameters" : @{@"type" : @"object", @"additionalProperties" : @NO, @"required" : @[ @"code" ],
            @"properties" : @{
                @"code" : @{@"type" : @"string", @"description" : @"The Python program."},
                @"files" : @{@"type" : @"array", @"maxItems" : @(kSPDFMaxFiles), @"items" : file,
                             @"description" : @"Input files, written into the working directory first."},
                @"documents" : @{@"type" : @"array", @"maxItems" : @8, @"items" : document,
                                 @"description" : @"Documents the code may read under ./documents."}}}}};
}

// The same rule as the helper's SPDFPythonSandboxValidInputName, checked here so the model hears about a bad name
// in words it can act on; the suite checks the two agree.
static BOOL SPDFValidFileName(id name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString* text = name;
    if (!text.length || text.length > 100 || [text isEqual:@"main.py"] || [text isEqual:@"documents"] ||
        [text isEqual:@"out"] || [text hasPrefix:@"."] ||
        [text hasSuffix:@" "])
        return NO;
    NSCharacterSet* allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                                            "0123456789._- "];
    return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL gSandboxRefused;
BOOL SPDFMacAIPythonSandboxRefused(void) { return gSandboxRefused; }

@implementation SPDFMacAIPythonToolProvider {
    id<SPDFMacAIPythonRunning> _runner;
    id<SPDFMacAIPythonEnvironment> _environment;
    NSMutableDictionary<NSString*, dispatch_block_t>* _runs;
    BOOL _sandboxUnavailable;
    NSString* _offerEntry;
    __weak id<SPDFMacAIActivityReporting> _offerActivity;
}

- (instancetype)initWithRunner:(id<SPDFMacAIPythonRunning>)runner
                   environment:(id<SPDFMacAIPythonEnvironment>)environment {
    if (!(self = [super init])) return nil;
    _runner = runner;
    _environment = environment;
    _runs = [NSMutableDictionary dictionary];
    _maximumConcurrentRuns = 2;
    return self;
}

- (NSString*)providerIdentifier { return @"python"; }
- (BOOL)providesTool:(NSString*)name { return [name isEqual:SPDFMacAIPythonToolName]; }
- (BOOL)isReadOnlyTool:(NSString*)name { return [self providesTool:name]; }
// In a request that includes Friends chats the code, written after reading them, and what it printed may quote a
// friend: the chat file keeps only a stub of each call (SPDFMacAIToolProvider.h § 4).
// While run_python is offered, the prompt says it reads the documents themselves, so the model measures rather than
// asking the person to export files or run code.
- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context {
    NSDictionary* system = messages.firstObject;
    if (![self toolDefinitionsForContext:context].count || ![system isKindOfClass:NSDictionary.class] ||
        ![system[@"role"] isEqual:@"system"] || ![system[@"content"] isKindOfClass:NSString.class])
        return messages;
    NSMutableArray* told = [messages mutableCopy];
    told[0] = @{@"role" : @"system",
                @"content" : [system[@"content"] stringByAppendingFormat:@" %@", SPDFMacAIPythonPromptGuidance]};
    return told;
}
- (BOOL)isRequestOnlyTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    return [self providesTool:name] && context.includesFriendsChats;
}

- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    return context.settings.aiPythonEnabled && !_sandboxUnavailable ? @[ SPDFMacAIPythonToolDefinition() ] : @[];
}

- (NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context {
    (void)name;
    (void)context;
    return _sandboxUnavailable ? kSPDFSandboxUnavailable
                               : @"Running Python is switched off in the assistant's settings, so the code did not "
                                 @"run. Answer without running code.";
}

- (void)cancel {
    for (dispatch_block_t stop in _runs.allValues) stop();
}

- (NSString*)problemWithArguments:(NSDictionary*)arguments code:(NSString**)code files:(NSArray**)files {
    for (NSString* key in arguments)
        if (![key isEqual:@"code"] && ![key isEqual:@"files"] && ![key isEqual:@"documents"])
            return [NSString stringWithFormat:@"Unknown argument %@. run_python takes code, files and documents.", key];
    NSString* documentsProblem = SPDFMacAIPythonDocumentsProblem(arguments[@"documents"]);
    if (documentsProblem) return documentsProblem;
    id program = arguments[@"code"];
    if (![program isKindOfClass:NSString.class] || ![program length] || [program length] > kSPDFMaxCodeCharacters)
        return @"code must be the Python program, as a string of at most 60,000 characters.";
    id list = arguments[@"files"] ?: @[];
    if (![list isKindOfClass:NSArray.class] || [list count] > kSPDFMaxFiles)
        return @"files must be a list of at most 8.";
    NSMutableArray* inputs = [NSMutableArray array];
    NSMutableSet* names = [NSMutableSet set];
    for (id file in list) {
        if (![file isKindOfClass:NSDictionary.class] || [file count] != 2 || !SPDFValidFileName(file[@"name"]) ||
            ![file[@"content"] isKindOfClass:NSString.class] || [names containsObject:file[@"name"]])
            return @"Each file needs a unique name (letters, digits, dots, dashes, underscores and spaces; not "
                   @"main.py, documents or out, not starting with a dot) and its content as text.";
        [names addObject:file[@"name"]];
        [inputs addObject:@{@"name" : file[@"name"], @"text" : file[@"content"]}];
    }
    *code = program;
    *files = inputs;
    return nil;
}

- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    (void)name;
    NSString* code = nil;
    NSArray* files = nil;
    NSString* problem = [self problemWithArguments:arguments code:&code files:&files];
    if (problem) { completion(@{@"error" : problem}); return; }
    if (_sandboxUnavailable) { completion(@{@"error" : kSPDFSandboxUnavailable}); return; }
    if (!_environment.installed) { completion([self offerInstallationInContext:context]); return; }
    if (_runs.count >= _maximumConcurrentRuns) {
        completion(@{@"error" : @"Other Python runs are still going. Wait for one to finish, then try again."});
        return;
    }
    // The same rule as -isRequestOnlyTool:context:, so the rows go with the calls the chat file stubs.
    BOOL friends = context.includesFriendsChats;
    id<SPDFMacAIActivityReporting> activity = context.activity;
    __block dispatch_block_t stop = nil;
    __block BOOL stopped = NO;
    NSString* step = [activity beginStepWithTitle:@"Running Python" detail:SPDFMacAIPythonClip(code, 2500)
                                          options:friends ? SPDFMacAIActivityRequestOnly : SPDFMacAIActivityOptionsNone
                                           cancel:^{ stopped = YES; if (stop) stop(); }];
    // The detail is only the code: the chat shows it in its code box. What it printed goes under its own key.
    if (step) [activity updateEntry:step changes:@{SPDFMacAIActivityDetailStyleKey : @"python"}];
    // No stored title: a step's titles are fixed words that never quote anyone, so a failed or stopped run reopens
    // under its own title rather than one chosen before it finished.
    if (step && friends)
        [activity updateEntry:step changes:@{SPDFMacAIActivityStoredNoticeKey : SPDFMacAIPythonFriendsNotice}];
    NSString* runID = NSUUID.UUID.UUIDString;
    _runs[runID] = ^{ stopped = YES; };
    [context.cancellation onCancel:^{ stopped = YES; if (stop) stop(); }];
    __weak SPDFMacAIPythonToolProvider* weakSelf = self;
    // Output from ./out is kept only in the person's own request: not a part's (depth 1), not one with Friends chats.
    BOOL keepOutputs = self.saveOutput && !friends && context.depth == 0;
    void (^finish)(NSDictionary*, SPDFMacAIPythonDocumentFolder*) = ^(NSDictionary* result,
                                                                      SPDFMacAIPythonDocumentFolder* folder) {
        [folder remove];
        SPDFMacAIPythonToolProvider* owner = weakSelf;
        if (!owner) { completion(@{@"error" : @"The run was abandoned."}); return; }
        [owner->_runs removeObjectForKey:runID];
        NSDictionary* rest = result;
        NSArray* outputs = [result[@"ok"] boolValue] ? SPDFMacAIPythonOutputFiles(result, &rest) : @[];
        void (^answer)(NSArray*) = ^(NSArray* kept) {
            NSMutableDictionary* model = [[owner finishRun:rest code:code step:step activity:activity
                                                   friends:friends] mutableCopy];
            if (folder) model[@"documents"] = folder.index[@"documents"];
            if (kept.count) model[@"out"] = kept;
            completion(model);
        };
        if (!outputs.count) { answer(nil); return; }
        if (!keepOutputs) {
            NSMutableArray* refused = [NSMutableArray array];
            for (NSDictionary* file in outputs)
                [refused addObject:@{@"file" : file[@"name"], @"error" : context.depth
                    ? @"Not kept: only the main conversation keeps files. Return the result instead."
                    : @"Not kept: files are not saved in requests that include Friends chats."}];
            answer(refused);
            return;
        }
        SPDFMacAIPythonKeepOutputs(outputs, owner.saveOutput, owner.showOutput, activity, answer);
    };
    void (^run)(SPDFMacAIPythonDocumentFolder*) = ^(SPDFMacAIPythonDocumentFolder* folder) {
        SPDFMacAIPythonToolProvider* owner = weakSelf;
        if (!owner || stopped) {
            finish(@{@"ok" : @NO, @"error" : @"stopped", @"message" : @"The run was stopped."}, folder);
            return;
        }
        if (folder) [activity updateEntry:step changes:@{SPDFMacAIActivityStatusKey : @"Running…"}];
        NSMutableDictionary* request = [@{@"interpreter" : owner->_environment.interpreterPath, @"code" : code,
                                          @"files" : files} mutableCopy];
        if (folder) { request[@"documents_dir"] = folder.path; request[@"document_files"] = folder.files; }
        stop = [[owner->_runner runRequest:request completion:^(NSDictionary* result) { finish(result, folder); }]
            copy];
        if (owner->_runs[runID]) owner->_runs[runID] = stop;
    };
    NSArray* requests = arguments[@"documents"];
    if (!requests.count) { run(nil); return; }
    if (!self.documentResolver) {
        finish(@{@"ok" : @NO, @"error" : @"documents", @"message" : @"Documents can't be read in this window."}, nil);
        return;
    }
    [activity updateEntry:step changes:@{SPDFMacAIActivityStatusKey : @"Getting the documents ready…"}];
    self.documentResolver(requests, context, ^(NSArray<SPDFMacAIPythonDocument*>* documents, NSString* problem) {
        if (!documents) {
            finish(@{@"ok" : @NO, @"error" : @"documents", @"message" : problem ?: @"The documents were not found."},
                   nil);
            return;
        }
        [activity updateEntry:step changes:@{SPDFMacAIActivityStatusKey : [NSString stringWithFormat:
            @"Getting %@ ready…", SPDFMacAIPythonDocumentsSummary(requests, documents)]}];
        SPDFMacAIPythonPrepareDocuments(requests, documents, ^BOOL { return stopped; },
            ^(SPDFMacAIPythonDocumentFolder* folder, NSString* failure) {
                if (folder) run(folder);
                else finish(@{@"ok" : @NO, @"error" : stopped ? @"stopped" : @"documents",
                              @"message" : failure ?: @"The documents could not be prepared."}, nil);
            });
    });
}

- (NSDictionary*)finishRun:(NSDictionary*)result code:(NSString*)code step:(NSString*)step
                  activity:(id<SPDFMacAIActivityReporting>)activity friends:(BOOL)friends {
    if (![result[@"ok"] boolValue]) {
        NSString* error = result[@"error"], *status = @"Didn’t run";
        NSDictionary* answer = nil;
        if ([error isEqual:@"sandbox_unavailable"]) {
            // Refused before any code ran. It will refuse again, so stop offering the tool in this window, and let
            // Settings say why the switch does nothing on this Mac.
            _sandboxUnavailable = YES;
            gSandboxRefused = YES;
            status = @"Didn’t run: this Mac can’t isolate Python from your files";
            answer = @{@"error" : kSPDFSandboxUnavailable};
        } else if ([error isEqual:@"interpreter_unavailable"]) {
            [_environment forgetInstallation];
            status = @"Python needs to be installed again";
            answer = @{@"error" : @"The assistant's Python could not start, so the code did not run. Calling "
                                  @"run_python again asks the person to reinstall it."};
        } else if ([error isEqual:@"stopped"]) {
            status = @"Stopped";
            answer = @{@"error" : @"The run was stopped before it finished."};
        } else if ([error isEqual:@"documents"]) {
            status = @"Didn’t run: the documents couldn’t be read";
            answer = @{@"error" : [NSString stringWithFormat:@"The code did not run: %@", result[@"message"]]};
        } else {
            answer = @{@"error" : [NSString stringWithFormat:@"The code did not run: %@",
                                                             result[@"message"] ?: @"the sandbox failed."]};
        }
        BOOL stopped = [error isEqual:@"stopped"];
        // Past tense once it is over, so a finished step folded into one line reads right (D6).
        [activity updateEntry:step changes:@{SPDFMacAIActivityStatusKey : status, SPDFMacAIActivityStateKey :
            stopped ? SPDFMacAIActivityStateStopped : SPDFMacAIActivityStateFailed,
            SPDFMacAIActivityTitleKey : stopped ? @"Python run stopped" : @"Python run failed"}];
        return answer;
    }
    SPDFMacAIPythonPresentation* shown = SPDFMacAIPythonPresent(result, code, activity, friends);
    NSMutableDictionary* changes = [@{SPDFMacAIActivityStateKey : shown.state, SPDFMacAIActivityTitleKey : shown.title,
        SPDFMacAIActivityStatusKey : shown.status, SPDFMacAIActivityDetailKey : shown.detail} mutableCopy];
    if (shown.output.length) changes[SPDFMacAIActivityOutputKey] = shown.output;
    if (shown.note.length) changes[SPDFMacAIActivityNoteKey] = shown.note;
    [activity updateEntry:step changes:changes];
    return shown.modelResult;
}

// Until the person presses Install, nothing is downloaded: the call adds this card and tells the model why the code
// did not run. One card at a time while its Install button still works in this chat.
- (NSDictionary*)offerInstallationInContext:(SPDFMacAIRequestContext*)context {
    if (_environment.installing)
        return @{@"error" : @"The assistant's Python is being installed right now, so the code did not run. Answer "
                            @"without running code; the person can ask again once it is installed."};
    id<SPDFMacAIActivityReporting> activity = context.activity;
    BOOL showing = _offerEntry && activity && _offerActivity == activity &&
        [(id)activity respondsToSelector:@selector(liveActionsForEntry:)] &&
        [[(SPDFMacAIChatActivity*)activity liveActionsForEntry:_offerEntry] count] > 0;
    if (activity && !showing) {
        __weak SPDFMacAIPythonToolProvider* weakSelf = self;
        __weak id<SPDFMacAIActivityReporting> weakActivity = activity;
        __block NSString* entry = nil;
        entry = [activity addCard:@{
            SPDFMacAIActivityTitleKey : SPDFMacAIPythonInstallTitle(),
            SPDFMacAIActivityBodyKey : SPDFMacAIPythonInstallBody(),
            SPDFMacAIActivityCardKindKey : @"python.install",
            SPDFMacAIActivityStateKey : SPDFMacAIActivityStateRunning,
            SPDFMacAIActivityStatusKey : @"Not installed",
            SPDFMacAIActivityInterruptedStatusKey : @"Not installed",
            SPDFMacAIActivityActionsKey : @[ @{@"id" : kSPDFInstallAction, @"title" : @"Install"} ]}
            options:SPDFMacAIActivityOptionsNone handler:^(NSString* action) {
                if ([action isEqual:kSPDFInstallAction]) [weakSelf installFromEntry:entry activity:weakActivity];
            }];
        _offerEntry = entry;
        _offerActivity = activity;
    }
    return @{@"error" : @"Python is not installed for the assistant yet, so the code did not run. A card in the chat "
                        @"now asks the person to install it. Tell them, and answer without running code for now; once "
                        @"it is installed they can ask again.",
             @"install_offered" : @(activity != nil)};
}

- (void)installFromEntry:(NSString*)entry activity:(id<SPDFMacAIActivityReporting>)activity {
    if (!entry || _environment.installing) return;
    // Installed meanwhile from Settings or another card: installing again would download it all a second time.
    if (_environment.installed) {
        [activity updateEntry:entry changes:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
            SPDFMacAIActivityActionsKey : @[],
            SPDFMacAIActivityStatusKey : @"Installed. Ask again and the assistant can run Python."}];
        return;
    }
    [activity updateEntry:entry changes:@{SPDFMacAIActivityStatusKey : @"Installing…",
                                          SPDFMacAIActivityActionsKey : @[]}];
    __weak id<SPDFMacAIActivityReporting> weakActivity = activity;
    [_environment installWithProgress:^(NSString* stage) {
        [weakActivity updateEntry:entry changes:@{SPDFMacAIActivityStatusKey : [stage stringByAppendingString:@"…"]}];
    } completion:^(NSString* failure) {
        if (!failure) {
            [weakActivity updateEntry:entry changes:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
                SPDFMacAIActivityStatusKey : @"Installed. Ask again and the assistant can run Python."}];
        } else {
            [weakActivity updateEntry:entry changes:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateFailed,
                SPDFMacAIActivityStatusKey : failure,
                SPDFMacAIActivityActionsKey : @[ @{@"id" : kSPDFInstallAction, @"title" : @"Try Again"} ]}];
        }
    }];
}

@end
