// run_python with documents and ./out, read_attachment, and the chat's grants (SPDFMacAIPythonDocuments.h,
// SPDFMacAIPythonOutputs.h, SPDFMacAIAttachmentToolProvider.h, SPDFMacAIChatGrants.h): a chat's files and folders reach
// only its own requests and their parts; path checks refuse "..", absolute paths and links that lead out; the PDF
// images the code reads are the embedded pixels; what it keeps in ./out lands in Downloads. The real helper and a
// real Python run the code. Included by SPDFMacAIPythonTests.mm.
#pragma once
#import "SPDFMacAIPythonFakes.h"
#import "SPDFMacAIAttachmentToolProvider.h"
#import "SPDFMacAIChatGrants.h"
#import "SPDFMacAIOutputFiles.h"
#import "SPDFMacAIPythonDocuments.h"

#import <CoreGraphics/CoreGraphics.h>

#include <sys/stat.h>

static NSString* DocWrite(NSString* path, NSString* text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return path;
}

static SPDFMacAIRequestChip* DocChip(NSString* path, BOOL folder, NSString* identifier) {
    return [SPDFMacAIRequestChip attachmentChipWithFileURL:[NSURL fileURLWithPath:path isDirectory:folder]
                                                identifier:identifier displayName:path.lastPathComponent];
}

static void CheckDocumentArguments(void) {
    CHECK(!SPDFMacAIPythonDocumentsProblem(nil) &&
          !SPDFMacAIPythonDocumentsProblem(@[ @{@"id" : @"doc:abc", @"images_on_pages" : @[ @4, @5 ]} ]) &&
          !SPDFMacAIPythonDocumentsProblem(@[ @{@"id" : @"attachment:1f", @"path" : @"a/b.pdf", @"render_pages" : @[ @1 ],
                                                @"dpi" : @300} ]),
          "documents by doc:, collection: or attachment: id, with pages and dpi");
    for (id bad in @[ @[ @{@"id" : @"/Users/x/a.pdf"} ], @[ @{@"id" : @"doc:a", @"images_on_pages" : @[ @0 ]} ],
                      @[ @{@"id" : @"doc:a", @"render_pages" : @[ @1 ], @"dpi" : @2000} ],
                      @[ @{@"id" : @"doc:a", @"path" : @"x.pdf"} ], @[ @{@"id" : @"doc:a", @"pages" : @[ @1 ]} ],
                      @[ @{@"id" : @"doc:a"}, @{@"id" : @"doc:a"} ], @"doc:a" ])
        CHECK(SPDFMacAIPythonDocumentsProblem(bad).length > 0,
              [[NSString stringWithFormat:@"refused documents %@", bad] UTF8String]);
    NSDictionary* definition = SPDFMacAIPythonToolDefinition()[@"function"];
    NSString* description = definition[@"description"];
    CHECK(definition[@"parameters"][@"properties"][@"documents"] && [description containsString:@"./documents"] &&
          [description containsString:@"never ask the person to export"] && [description containsString:@"./out"] &&
          ![description containsString:@"no access to their files"],
          "the tool says it reads the documents and keeps files, never that it can't see them");
}

static void CheckGrantPaths(NSString* scratch) {
    NSString* reason = nil;
    CHECK(!SPDFMacAIChatGrantForURL([NSURL fileURLWithPath:NSHomeDirectory()], &reason) && reason.length &&
          !SPDFMacAIChatGrantForURL([NSURL fileURLWithPath:@"/System"], &reason) &&
          !SPDFMacAIChatGrantForURL([NSURL fileURLWithPath:@"/Users"], &reason) &&
          !SPDFMacAIChatGrantForURL([NSURL fileURLWithPath:@"/"], &reason),
          "the home folder, /Users, / and the system's folders are never granted");
    NSString* root = [scratch stringByAppendingPathComponent:@"grant"];
    NSString* file = DocWrite([root stringByAppendingPathComponent:@"folder/inner/a.txt"], @"a");
    DocWrite([root stringByAppendingPathComponent:@"outside.txt"], @"outside");
    NSString* folder = [root stringByAppendingPathComponent:@"folder"];
    symlink([root stringByAppendingPathComponent:@"outside.txt"].fileSystemRepresentation,
            [folder stringByAppendingPathComponent:@"leak"].fileSystemRepresentation);
    symlink(root.fileSystemRepresentation, [folder stringByAppendingPathComponent:@"up"].fileSystemRepresentation);
    NSDictionary* grant = SPDFMacAIChatGrantForURL([NSURL fileURLWithPath:folder], &reason);
    CHECK([grant[@"kind"] isEqual:@"folder"] && [grant[@"id"] hasPrefix:@"attachment:"] &&
          [SPDFMacAIChatGrantResolvedPath(grant) isEqual:folder],
          "a folder is granted, and found again from its bookmark");
    CHECK([SPDFMacAIChatGrantPathInside(folder, @"inner/a.txt", &reason) isEqual:file] &&
          [SPDFMacAIChatGrantPathInside(folder, @"", &reason) isEqual:folder],
          "paths inside the folder resolve");
    for (NSString* escape in @[ @"../outside.txt", @"inner/../../outside.txt", @"leak", @"up/outside.txt",
                                @"/etc/hosts", @"~/x", @"missing.txt" ])
        CHECK(!SPDFMacAIChatGrantPathInside(folder, escape, &reason) && reason.length,
              [[NSString stringWithFormat:@"refused path %@", escape] UTF8String]);
    CHECK(SPDFMacAIChatGrantContains(@"/a/b", @"/a/b/c") && !SPDFMacAIChatGrantContains(@"/a/b", @"/a/bc") &&
          SPDFMacAIChatGrantContains(@"/a/b", @"/a/b"), "containment is by whole path components");
    NSArray* chips = SPDFMacAIChatGrantChips(@[ grant, @{@"id" : @"attachment:gone", @"kind" : @"file",
                                                         @"name" : @"gone", @"path" : @"/nonexistent/gone"} ]);
    CHECK(chips.count == 1 && SPDFMacAIChatChipIsFolder(chips[0]) &&
          [SPDFMacAIChatGrantsNote(chips) containsString:grant[@"id"]],
          "a grant whose item is gone gives no chip; the note names each id for the model");
}

// A one-page PDF drawing a 40 × 30 RGB image whose every pixel is known.
static NSString* DocMakePDF(NSString* path, uint8_t* pixels) {
    for (int y = 0; y < 30; y++)
        for (int x = 0; x < 40; x++) {
            uint8_t* p = pixels + (y * 40 + x) * 3;
            p[0] = (uint8_t)(x * 6); p[1] = (uint8_t)(y * 8); p[2] = (uint8_t)((x + y) % 251);
        }
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef data = CGDataProviderCreateWithData(NULL, pixels, 40 * 30 * 3, NULL);
    CGImageRef image = CGImageCreate(40, 30, 8, 24, 120, rgb, kCGBitmapByteOrderDefault, data, NULL, false,
                                     kCGRenderingIntentDefault);
    CGRect box = CGRectMake(0, 0, 200, 150);
    CGContextRef pdf = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &box, NULL);
    CGPDFContextBeginPage(pdf, NULL);
    CGContextDrawImage(pdf, CGRectMake(20, 20, 160, 120), image);
    CGPDFContextEndPage(pdf);
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
    CGImageRelease(image);
    CGDataProviderRelease(data);
    CGColorSpaceRelease(rgb);
    return path;
}

// Pure Python: the sums of an RGB PNG's channels (MuPDF writes rows without prediction filters).
static NSString* const kDocPNGSums =
    @"import json, struct, zlib\n"
     "def png_sums(path):\n"
     "    data = open(path, 'rb').read()\n"
     "    pos, idat, size = 8, b'', None\n"
     "    while pos < len(data):\n"
     "        length, kind = struct.unpack('>I4s', data[pos:pos + 8])\n"
     "        body = data[pos + 8:pos + 8 + length]\n"
     "        if kind == b'IHDR': size = struct.unpack('>II', body[:8])\n"
     "        if kind == b'IDAT': idat += body\n"
     "        pos += 12 + length\n"
     "    raw, (w, h) = zlib.decompress(idat), size\n"
     "    sums = [0, 0, 0]\n"
     "    for y in range(h):\n"
     "        row = raw[y * (w * 3 + 1) + 1:(y + 1) * (w * 3 + 1)]\n"
     "        for c in range(3): sums[c] += sum(row[c::3])\n"
     "    return w, h, sums\n";

static void CheckDocumentRuns(NSString* helper, NSString* python, NSString* scratch) {
    FakeEnvironment* environment = [FakeEnvironment new];
    environment.installed = YES;
    environment.interpreterPath = python;
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc]
        initWithRunner:[[SPDFMacAIPythonSandboxRunner alloc] initWithHelperPath:helper] environment:environment];
    NSString* root = [scratch stringByAppendingPathComponent:@"session"];
    uint8_t pixels[40 * 30 * 3];
    NSString* pdf = DocMakePDF([root stringByAppendingPathComponent:@"plates/plate.pdf"], pixels);
    DocWrite([root stringByAppendingPathComponent:@"plates/sibling.txt"], @"sibling-secret");
    NSString* folder = [root stringByAppendingPathComponent:@"folder"];
    DocWrite([folder stringByAppendingPathComponent:@"inner/data.csv"], @"x,y\n1,2\n");
    // Chat A was given the folder and the PDF; chat B nothing.
    NSArray* chipsA = @[ DocChip(folder, YES, @"attachment:aaaa"), DocChip(pdf, NO, @"attachment:bbbb") ];
    provider.documentResolver = ^(NSArray<NSDictionary*>* requests, SPDFMacAIRequestContext* context,
                                  void (^completion)(NSArray<SPDFMacAIPythonDocument*>*, NSString*)) {
        NSMutableArray* documents = [NSMutableArray array];
        for (NSDictionary* request in requests) {
            NSString* problem = nil;
            SPDFMacAIPythonDocument* document = SPDFMacAIPythonAttachmentDocument(request, context.chips, &problem);
            if (!document) { completion(nil, problem); return; }
            [documents addObject:document];
        }
        completion(documents, nil);
    };
    NSString* downloads = [scratch stringByAppendingPathComponent:@"Downloads"];
    NSMutableArray* shown = [NSMutableArray array];
    provider.saveOutput = ^NSDictionary*(NSData* data, NSString* name, NSError** error) {
        return SPDFMacAIOutputWriteData(data, downloads, name, error);
    };
    provider.showOutput = ^(id<SPDFMacAIActivityReporting> activity, NSString* path, NSString* image) {
        (void)activity;
        [shown addObject:@{@"path" : path, @"image" : @(image != nil)}];
    };
    SPDFMacAIChatActivity* activity = FakeActivity();
    SPDFMacAIRequestContext* chatA = FakeContext(activity, YES, chipsA);
    NSString* code = [kDocPNGSums stringByAppendingString:
        @"index = json.load(open('documents/index.json'))['documents']\n"
         "images = [i for d in index for i in d.get('images', [])]\n"
         "print('IMAGE', images[0]['width'], images[0]['height'], images[0]['lossless'], png_sums(images[0]['file']))\n"
         "renders = [r for d in index for r in d.get('renders', [])]\n"
         "print('RENDER', renders[0]['width'], renders[0]['height'])\n"
         "folder = [d for d in index if d['id'] == 'attachment:aaaa'][0]['file']\n"
         "print('CSV', open(folder + '/inner/data.csv').read().split())\n"
         "try:\n"
         "    open('%@').read(); print('LEAK')\n"
         "except Exception as e: print('SIBLING', type(e).__name__)\n"
         "open('out/result.csv', 'w').write('page,gray\\n4,12.5\\n')\n"
         "open('out/report.md', 'w').write('# Result\\n')\n"];
    code = [NSString stringWithFormat:code, [root stringByAppendingPathComponent:@"plates/sibling.txt"]];
    NSDictionary* arguments = @{@"code" : code, @"documents" : @[
        @{@"id" : @"attachment:bbbb", @"images_on_pages" : @[ @1 ], @"render_pages" : @[ @1 ], @"dpi" : @72},
        @{@"id" : @"attachment:aaaa"} ]};
    NSDictionary* result = FakeCall(provider, arguments, chatA);
    long sums[3] = {0, 0, 0};
    for (int i = 0; i < 40 * 30; i++) for (int c = 0; c < 3; c++) sums[c] += pixels[i * 3 + c];
    NSString* expected = [NSString stringWithFormat:@"IMAGE 40 30 True (40, 30, [%ld, %ld, %ld])", sums[0], sums[1],
                                                    sums[2]];
    NSString* out = result[@"stdout"] ?: @"";
    CHECK([out containsString:expected], [[NSString stringWithFormat:@"the embedded image, exact pixels: %@ in %@ %@",
                                           expected, out, result] UTF8String]);
    CHECK([out containsString:@"RENDER 200 150"] && [out containsString:@"CSV ['x,y', '1,2']"] &&
          [out containsString:@"SIBLING PermissionError"] && ![out containsString:@"LEAK"],
          "a page rendered at 72 dpi, a file in the given folder, and the file beside the PDF refused");
    NSArray* kept = result[@"out"];
    CHECK(kept.count == 2 && [NSFileManager.defaultManager fileExistsAtPath:[downloads stringByAppendingPathComponent:@"result.csv"]] &&
          [NSFileManager.defaultManager fileExistsAtPath:[downloads stringByAppendingPathComponent:@"report.md"]] &&
          shown.count == 2 && [result[@"documents"] count] == 2,
          "files kept in ./out are saved to Downloads and shown; the model reads the index");
    CHECK(![result[@"tables"] count], "a CSV kept in ./out is a saved file, not a table");

    // Chat B was given nothing: the same ids are unknown to it, in Python and in read_attachment.
    SPDFMacAIRequestContext* chatB = FakeContext(FakeActivity(), YES, @[]);
    NSDictionary* refused = FakeCall(provider, @{@"code" : @"print('ran')", @"documents" : @[ @{@"id" : @"attachment:aaaa"} ]},
                                     chatB);
    CHECK([refused[@"error"] containsString:@"not attached to this chat"] && !refused[@"stdout"],
          "another chat can't read this chat's folder through Python");
    CHECK([SPDFMacAIAttachmentRead(@{@"id" : @"attachment:aaaa"}, chatB.chips)[@"error"] length] > 0,
          "nor through read_attachment");
    // A part of chat A (run_subagents) reads it: its context carries A's chips.
    SPDFMacAIRequestContext* part = [chatA childContextWithText:@"part"
        budget:[[SPDFMacAIRequestBudget alloc] initWithSteps:2 tokens:1000 toolCalls:2] error:nil];
    NSDictionary* partResult = FakeCall(provider, @{@"code" : @"print(open('documents/folder/inner/data.csv').read().split())\n"
                                                              "open('out/x.txt','w').write('x')",
                                                    @"documents" : @[ @{@"id" : @"attachment:aaaa"} ]}, part);
    CHECK([partResult[@"stdout"] containsString:@"['x,y', '1,2']"] &&
          [[partResult[@"out"] firstObject][@"error"] containsString:@"main conversation"],
          "a part of the same chat reads its folder, and keeps no files");
    NSDictionary* listing = SPDFMacAIAttachmentRead(@{@"id" : @"attachment:aaaa"}, chipsA);
    NSDictionary* csv = SPDFMacAIAttachmentRead(@{@"id" : @"attachment:aaaa", @"path" : @"inner/data.csv"}, chipsA);
    NSDictionary* pages = SPDFMacAIAttachmentRead(@{@"id" : @"attachment:bbbb"}, chipsA);
    CHECK([listing[@"kind"] isEqual:@"folder"] && [listing[@"entries"] count] == 2 &&
          [csv[@"text"] isEqual:@"x,y\n1,2\n"] && [pages[@"kind"] isEqual:@"pdf"] && [pages[@"page_count"] isEqual:@1],
          "read_attachment lists a folder, reads a file in it as text, and a PDF's pages");
    CHECK([SPDFMacAIAttachmentRead(@{@"id" : @"attachment:aaaa", @"path" : @"../plates/sibling.txt"}, chipsA)[@"error"]
              length] > 0 &&
          [SPDFMacAIAttachmentRead(@{@"id" : @"attachment:bbbb", @"path" : @"x"}, chipsA)[@"error"] length] > 0,
          "read_attachment refuses paths out of a folder, and paths under a file");
}

// Two chats in one window: what chat A was given reaches A's requests (its model is told, its Python is given the
// folder) and is kept with A's file; chat B, though it runs through the same providers, has no such id.
#import "SPDFMacAIChatSessionGrants.h"
#import "SPDFMacAIPythonStorageChecks.h"

static NSDictionary* DocPythonCall(NSString* identifier, NSDictionary* arguments) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil];
    return @{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[ @{@"id" : identifier, @"type" : @"function",
        @"function" : @{@"name" : SPDFMacAIPythonToolName,
                        @"arguments" : [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]}} ]};
}

static void CheckSessionGrants(NSString* scratch) {
    NSString* folder = [scratch stringByAppendingPathComponent:@"chat-a/Captures"];
    DocWrite([folder stringByAppendingPathComponent:@"frame.raw"], @"raw");
    NSString* chats = [scratch stringByAppendingPathComponent:@"chats"];
    [NSFileManager.defaultManager createDirectoryAtPath:chats withIntermediateDirectories:YES attributes:nil error:nil];
    FakeRunner* runner = [FakeRunner new];
    runner.reply = @{@"ok" : @YES, @"status" : @"completed", @"exit_code" : @0, @"seconds" : @0.1, @"stdout" : @"ok\n",
                     @"stderr" : @""};
    FakeEnvironment* environment = [FakeEnvironment new];
    environment.installed = YES;
    environment.interpreterPath = @"/fake/bin/python3";
    SPDFMacAIPythonToolProvider* python = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                  environment:environment];
    python.documentResolver = ^(NSArray<NSDictionary*>* requests, SPDFMacAIRequestContext* context,
                                void (^completion)(NSArray<SPDFMacAIPythonDocument*>*, NSString*)) {
        NSString* problem = nil;
        SPDFMacAIPythonDocument* document = SPDFMacAIPythonAttachmentDocument(requests[0], context.chips, &problem);
        completion(document ? @[ document ] : nil, problem);
    };
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    [registry registerProvider:python error:nil];
    [registry registerProvider:[SPDFMacAIAttachmentToolProvider new] error:nil];
    SPDFMacAIChatStore* store = [[SPDFMacAIChatStore alloc] initWithDirectory:[NSURL fileURLWithPath:chats]];
    PythonScriptedModel* modelA = [PythonScriptedModel new], *modelB = [PythonScriptedModel new];
    SPDFMacAIChatSession* chatA = [[SPDFMacAIChatSession alloc] initWithTransport:modelA registry:registry store:store];
    SPDFMacAIChatSession* chatB = [[SPDFMacAIChatSession alloc] initWithTransport:modelB registry:registry store:store];
    [chatA newChat];
    [chatB newChat];
    NSArray* problems = [chatA addGrantsForURLs:@[ [NSURL fileURLWithPath:folder],
                                                   [NSURL fileURLWithPath:NSHomeDirectory()] ]];
    NSString* identifier = chatA.grants.firstObject[@"id"];
    CHECK(chatA.grants.count == 1 && problems.count == 1 && !chatB.grants.count && chatB.grantChips.count == 0,
          "a folder dropped on chat A is A's alone; the home folder is refused with a reason");
    CHECK([chatA addGrantsForURLs:@[ [NSURL fileURLWithPath:folder] ]].count == 0 && chatA.grants.count == 1,
          "the same folder twice is one grant");
    SPDFMacAIRequestContext* contextA = [[SPDFMacAIRequestContext alloc] initWithText:@"What is in Captures?"
        chips:chatA.grantChips origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:FakeSettings(YES)
        budget:nil activity:chatA.activity];
    [chatA sendContext:contextA model:@"example/model-for-tests" apiKey:@"sk-or-v1-test-key-not-real-000000"];
    CHECK(SandboxWait(^BOOL { return modelA.sends == 1; }), "chat A asks its model");
    NSString* system = [modelA.messages.firstObject[@"content"] description];
    CHECK([system containsString:identifier] && [system containsString:@"Captures (folder"] &&
          [system containsString:@"run_python can read the documents you can see"] &&
          [[modelA.definitions valueForKeyPath:@"function.name"] containsObject:SPDFMacAIAttachmentToolName],
          "A's model is told what it was given and how to read it, and is offered read_attachment");
    modelA.reply(DocPythonCall(@"a-1", @{@"code" : @"print(1)", @"documents" : @[ @{@"id" : identifier} ]}), nil);
    CHECK(SandboxWait(^BOOL { return modelA.sends == 2; }) &&
          [[runner.requests.lastObject[@"document_files"] firstObject] isEqual:folder],
          "A's Python is given exactly the folder");
    modelA.reply(@{@"role" : @"assistant", @"content" : @"It holds frame.raw."}, nil);
    CHECK(SandboxWait(^BOOL { return !chatA.running; }), "A's request ends");

    SPDFMacAIRequestContext* contextB = [[SPDFMacAIRequestContext alloc] initWithText:@"Read it" chips:chatB.grantChips
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:FakeSettings(YES) budget:nil
        activity:chatB.activity];
    NSUInteger runs = runner.requests.count;
    [chatB sendContext:contextB model:@"example/model-for-tests" apiKey:@"sk-or-v1-test-key-not-real-000000"];
    CHECK(SandboxWait(^BOOL { return modelB.sends == 1; }) &&
          ![[modelB.messages.firstObject[@"content"] description] containsString:identifier] &&
          ![[modelB.definitions valueForKeyPath:@"function.name"] containsObject:SPDFMacAIAttachmentToolName],
          "chat B is told of nothing and offered no read_attachment");
    modelB.reply(DocPythonCall(@"b-1", @{@"code" : @"print(1)", @"documents" : @[ @{@"id" : identifier} ]}), nil);
    CHECK(SandboxWait(^BOOL { return modelB.sends == 2; }) && runner.requests.count == runs &&
          [[modelB.messages.lastObject[@"content"] description] containsString:@"not attached to this chat"],
          "chat B using A's id runs nothing and is told it is not its own");
    modelB.reply(@{@"role" : @"assistant", @"content" : @"I can't."}, nil);
    SandboxWait(^BOOL { return !chatB.running; });

    NSString* chatID = chatA.chat[@"id"];
    SPDFMacAIChatSession* reopened = [[SPDFMacAIChatSession alloc] initWithTransport:modelA registry:registry store:store];
    [reopened loadChat:[store chatWithID:chatID]];
    CHECK([reopened.grants.firstObject[@"id"] isEqual:identifier] && reopened.grantChips.count == 1,
          "reopened, chat A still has its folder");
    [reopened removeGrantWithIdentifier:identifier];
    SPDFMacAIChatSession* again = [[SPDFMacAIChatSession alloc] initWithTransport:modelA registry:registry store:store];
    [again loadChat:[store chatWithID:chatID]];
    CHECK(!again.grants.count && !again.grantChips.count, "removing the chip ends the grant, also after reopening");
    [chatA cancel];
    [chatB cancel];
}
