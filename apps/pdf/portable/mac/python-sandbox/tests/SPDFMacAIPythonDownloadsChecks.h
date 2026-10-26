// Downloads is write-only for the assistant (SPDFMacAISaveFileToolProvider.h): Python and save_file save any file
// there, in folders inside it, never replacing one ("name 2.ext"), each shown with a card; the code can't list or read
// Downloads, a file there it didn't save, or one another chat saved; the chat that saved a file reads it back by id.
// Runs the real helper, so the refusals are the sandbox's own.
#import "SPDFMacAISaveFileToolProvider.h"
#import "SPDFMacAIOutputFiles.h"
#import "SPDFMacAIChatSessionGrants.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFPythonSandbox.h"

static NSString* SandboxQuotePython(NSString* text) { // a Python string literal (JSON's is one)
    NSData* data = [NSJSONSerialization dataWithJSONObject:@[ text ] options:0 error:nil];
    NSString* array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

static SPDFMacAIRequestContext* DownloadsContext(SPDFMacAIChatSession* session, NSArray* chips) {
    SPDFMacAIRequestContext* context = FakeContext(FakeActivity(), YES, chips ?: @[]);
    [context bindToSession:session];
    return context;
}

static SPDFMacAIPythonDocumentResolver DownloadsResolver(void) {
    return ^(NSArray<NSDictionary*>* requests, SPDFMacAIRequestContext* context,
             void (^completion)(NSArray<SPDFMacAIPythonDocument*>*, NSString*)) {
        NSMutableArray* documents = [NSMutableArray array];
        for (NSDictionary* request in requests) {
            NSString* problem = nil;
            SPDFMacAIPythonDocument* document = SPDFMacAIPythonAttachmentDocument(request,
                SPDFMacAIRequestReadableAttachments(context), &problem);
            if (!document) { completion(nil, problem); return; }
            [documents addObject:document];
        }
        completion(documents, nil);
    };
}

static void CheckSaveFileTool(NSString* downloads, SPDFMacAIChatSession* chat) {
    SPDFMacAISaveFileToolProvider* save = [SPDFMacAISaveFileToolProvider new];
    NSMutableArray* cards = [NSMutableArray array];
    save.saver = ^NSDictionary*(NSData* data, NSString* folder, NSString* name, NSError** error) {
        NSString* problem = nil;
        NSString* directory = SPDFMacAIDownloadsSubfolder(folder, &problem);
        if (!directory && error) *error = [NSError errorWithDomain:@"test" code:1
                                                          userInfo:@{NSLocalizedDescriptionKey : problem}];
        return directory ? SPDFMacAIOutputWriteData(data, directory, name, error) : nil;
    };
    save.presenter = ^(id<SPDFMacAIActivityReporting> activity, NSString* path) { (void)activity; [cards addObject:path]; };
    save.documentResolver = DownloadsResolver();
    SPDFMacAIRequestContext* context = DownloadsContext(chat, nil);
    CHECK([[save toolDefinitionsForContext:context] count] == 1 &&
          [[save messagesForRequest:@[ @{@"role" : @"system", @"content" : @"base"} ] context:context][0][@"content"]
              containsString:@"save files to the person's Downloads folder"],
          "save_file is offered and the prompt says it can save to Downloads and should when asked");
    NSDictionary* first = FakeCall(save, @{@"name" : @"Notes.md", @"folder" : @"Meeting/October",
                                           @"content" : @"# Notes\n"}, context);
    NSDictionary* second = FakeCall(save, @{@"name" : @"Notes.md", @"folder" : @"Meeting/October",
                                            @"content" : @"# Other\n"}, context);
    NSString* folder = [downloads stringByAppendingPathComponent:@"Meeting/October"];
    CHECK([first[@"saved_as"] isEqual:@"Notes.md"] && [second[@"saved_as"] isEqual:@"Notes 2.md"] &&
          [[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:@"Notes.md"]
              encoding:NSUTF8StringEncoding error:nil] isEqual:@"# Notes\n"] && cards.count == 2 &&
          [first[@"id"] hasPrefix:@"attachment:saved-"],
          "save_file writes text into a folder in Downloads, never over a file, with a card and an id");
    NSDictionary* copy = FakeCall(save, @{@"name" : @"Notes copy", @"document" : first[@"id"]}, context);
    CHECK([copy[@"saved_as"] isEqual:@"Notes copy.md"] &&
          [NSFileManager.defaultManager fileExistsAtPath:[downloads stringByAppendingPathComponent:@"Notes copy.md"]],
          "save_file saves a copy of a document it can see, keeping its extension");
    for (NSDictionary* bad in @[ @{@"name" : @"../x.txt", @"content" : @"x"}, @{@"name" : @"x.txt", @"folder" : @"../..",
                                  @"content" : @"x"}, @{@"name" : @"x.txt"}, @{@"name" : @".hidden", @"content" : @"x"} ])
        CHECK([FakeCall(save, bad, context)[@"error"] length] > 0, "save_file refuses names and folders out of Downloads");
    SPDFMacAIRequestContext* part = [context childContextWithText:@"part"
        budget:[[SPDFMacAIRequestBudget alloc] initWithSteps:2 tokens:1000 toolCalls:2] error:nil];
    CHECK(![[save toolDefinitionsForContext:part] count], "a part of the chat can't save files");
}

static void CheckDownloadsWriteOnly(NSString* helper, NSString* python, NSString* scratch) {
    NSString* downloads = [scratch stringByAppendingPathComponent:@"home/Downloads"];
    SPDFMacAISetDownloadsDirectoryForTesting(downloads);
    DocWrite([downloads stringByAppendingPathComponent:@"private.txt"], @"PRIVATE-4471");
    DocWrite([downloads stringByAppendingPathComponent:@"Reports/table.csv"], @"theirs\n");
    NSString* profile = SPDFPythonSandboxProfile(@{@"deny_read_subpaths" : SPDFPythonSandboxWriteOnlyPaths(@[ downloads ]),
                                                   @"document_literals" : @[ @"/tmp/x" ]}, @"/tmp/work");
    NSRange deny = [profile rangeOfString:[NSString stringWithFormat:@"(subpath \"%@\")", downloads]];
    deny.location = [profile rangeOfString:@"(deny file-read*"].location < deny.location ? deny.location : NSNotFound;
    CHECK(deny.location != NSNotFound && deny.location < [profile rangeOfString:@"(literal \"/tmp/x\")"].location,
          "the profile refuses Downloads by name, before the run's own documents");

    FakeEnvironment* environment = [FakeEnvironment new];
    environment.installed = YES;
    environment.interpreterPath = python;
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc]
        initWithRunner:[[SPDFMacAIPythonSandboxRunner alloc] initWithHelperPath:helper] environment:environment];
    provider.writeOnlyDirectories = @[ downloads ];
    provider.documentResolver = DownloadsResolver();
    provider.saveOutput = ^NSDictionary*(NSData* data, NSString* name, NSError** error) {
        NSString* directory = SPDFMacAIDownloadsSubfolder(name.stringByDeletingLastPathComponent, NULL);
        return directory ? SPDFMacAIOutputWriteData(data, directory, name.lastPathComponent, error) : nil;
    };
    NSMutableArray* shown = [NSMutableArray array];
    provider.showOutput = ^(id<SPDFMacAIActivityReporting> activity, NSString* path, NSString* image) {
        (void)activity, (void)image;
        [shown addObject:path];
    };
    SPDFMacAIChatStore* store = [[SPDFMacAIChatStore alloc] initWithDirectory:
        [NSURL fileURLWithPath:[scratch stringByAppendingPathComponent:@"downloads-chats"]]];
    SPDFMacAIChatSession* chatA = [[SPDFMacAIChatSession alloc] initWithTransport:[SPDFMacAITransport new]
        registry:[SPDFMacAIToolRegistry new] store:store];
    SPDFMacAIChatSession* chatB = [[SPDFMacAIChatSession alloc] initWithTransport:[SPDFMacAITransport new]
        registry:[SPDFMacAIToolRegistry new] store:store];
    NSString* code = [NSString stringWithFormat:
        @"import os\n"
         "for label, attempt in (('LIST', lambda: os.listdir(%@)), ('READ', lambda: open(%@).read())):\n"
         "    try:\n"
         "        print('LEAK', label, attempt())\n"
         "    except Exception as error:\n"
         "        print('REFUSED', label, type(error).__name__)\n"
         "os.makedirs('out/Reports', exist_ok=True)\n"
         "open('out/Reports/table.csv', 'w').write('page,gray\\n4,12.5\\n')\n"
         "open('out/summary.txt', 'w').write('SAVED-BY-A')\n",
        SandboxQuotePython(downloads), SandboxQuotePython([downloads stringByAppendingPathComponent:@"private.txt"])];
    NSDictionary* result = FakeCall(provider, @{@"code" : code}, DownloadsContext(chatA, nil));
    NSString* out = result[@"stdout"] ?: @"";
    CHECK([out containsString:@"REFUSED LIST"] && [out containsString:@"REFUSED READ"] &&
          ![out containsString:@"LEAK"] && ![out containsString:@"PRIVATE-4471"],
          [[@"Python can't list Downloads or read a file there: " stringByAppendingString:out] UTF8String]);
    NSArray* kept = result[@"out"];
    NSString* reports = [downloads stringByAppendingPathComponent:@"Reports"];
    NSDictionary* summary = nil;
    for (NSDictionary* entry in kept) if ([entry[@"file"] isEqual:@"out/summary.txt"]) summary = entry;
    CHECK(kept.count == 2 && shown.count == 2 &&
          [[NSString stringWithContentsOfFile:[reports stringByAppendingPathComponent:@"table 2.csv"]
              encoding:NSUTF8StringEncoding error:nil] hasPrefix:@"page,gray"] &&
          [[NSString stringWithContentsOfFile:[reports stringByAppendingPathComponent:@"table.csv"]
              encoding:NSUTF8StringEncoding error:nil] isEqual:@"theirs\n"] &&
          [summary[@"id"] hasPrefix:@"attachment:saved-"] && !summary[@"_path"],
          "Python saves into Downloads and a folder in it, beside a file it didn't make, with a card and an id each");
    NSString* readBack = @"print(open(__import__('json').load(open('documents/index.json'))['documents'][0]['file']).read())";
    NSDictionary* own = FakeCall(provider, @{@"code" : readBack, @"documents" : @[ @{@"id" : summary[@"id"] ?: @"x"} ]},
                                 DownloadsContext(chatA, nil));
    CHECK([own[@"stdout"] containsString:@"SAVED-BY-A"], "the chat that saved a file reads it back by its id");
    NSDictionary* other = FakeCall(provider, @{@"code" : readBack, @"documents" : @[ @{@"id" : summary[@"id"] ?: @"x"} ]},
                                   DownloadsContext(chatB, nil));
    CHECK([other[@"error"] containsString:@"not attached to this chat"] && ![other[@"stdout"] length],
          "another chat can't read it");
    CHECK(!chatA.grantChips.count || chatA.savedFileChips.count == chatA.grantChips.count,
          "saved files are the chat's own, apart from what the person attached");
    CheckSaveFileTool(downloads, chatA);
    SPDFMacAISetDownloadsDirectoryForTesting(nil);
}
