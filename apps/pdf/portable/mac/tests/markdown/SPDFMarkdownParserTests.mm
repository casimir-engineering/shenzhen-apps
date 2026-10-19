#import "SPDFMarkdownTestSupport.h"

#import "../../markdown/SPDFMarkdownParser.h"
#import "../../markdown/SPDFMarkdownRenderer.h"
#import "../../markdown/SPDFMarkdownResources.h"

static void SPDFAppendBlocks(NSArray<SPDFMarkdownBlock*>* blocks, NSMutableArray<SPDFMarkdownBlock*>* result) {
    for (SPDFMarkdownBlock* block in blocks) {
        [result addObject:block];
        SPDFAppendBlocks(block.children, result);
    }
}

static NSArray<SPDFMarkdownBlock*>* SPDFAllBlocks(NSArray<SPDFMarkdownBlock*>* roots) {
    NSMutableArray* result = [NSMutableArray array];
    SPDFAppendBlocks(roots, result);
    return result;
}

static NSString* SPDFDirectText(NSArray<SPDFMarkdownBlock*>* blocks) {
    NSMutableString* result = [NSMutableString string];
    for (SPDFMarkdownBlock* block in SPDFAllBlocks(blocks))
        for (SPDFMarkdownInlineRun* run in block.runs) [result appendString:run.text];
    return result;
}

static NSURL* SPDFCreateResourceFixture(NSString** temporaryRoot) {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* documentDirectory = [root stringByAppendingPathComponent:@"document"];
    NSString* imageDirectory = [documentDirectory stringByAppendingPathComponent:@"images"];
    NSString* outsideDirectory = [root stringByAppendingPathComponent:@"outside"];
    NSFileManager* files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:imageDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [files createDirectoryAtPath:outsideDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [@"inside" writeToFile:[imageDirectory stringByAppendingPathComponent:@"inside.bin"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"outside" writeToFile:[outsideDirectory stringByAppendingPathComponent:@"secret.bin"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [files createSymbolicLinkAtPath:[imageDirectory stringByAppendingPathComponent:@"escape"]
                withDestinationPath:outsideDirectory error:nil];
    [files createSymbolicLinkAtPath:[imageDirectory stringByAppendingPathComponent:@"broken"]
                withDestinationPath:[root stringByAppendingPathComponent:@"missing"] error:nil];
    NSString* documentPath = [documentDirectory stringByAppendingPathComponent:@"document.md"];
    [@"# Fixture\n" writeToFile:documentPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    *temporaryRoot = root;
    return [NSURL fileURLWithPath:documentPath];
}

static NSData* SPDFTinyPNG(NSColor* color) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                      pixelsWide:4 pixelsHigh:2 bitsPerSample:8
                                                                    samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSCalibratedRGBColorSpace
                                                                       bytesPerRow:0 bitsPerPixel:0];
    BOOL makeRed = [color isEqual:NSColor.redColor];
    for (NSInteger y = 0; y < bitmap.pixelsHigh; ++y) {
        unsigned char* row = bitmap.bitmapData + y * bitmap.bytesPerRow;
        for (NSInteger x = 0; x < bitmap.pixelsWide; ++x) {
            row[x * 4 + 0] = makeRed ? 255 : 0;
            row[x * 4 + 1] = 0;
            row[x * 4 + 2] = makeRed ? 0 : 255;
            row[x * 4 + 3] = 255;
        }
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static void SPDFTestModelPinsResourcesAcrossPathReplacement(void) {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString* documentDirectory = [root stringByAppendingPathComponent:@"document"];
    [NSFileManager.defaultManager createDirectoryAtPath:documentDirectory
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [SPDFTinyPNG(NSColor.redColor) writeToFile:[documentDirectory stringByAppendingPathComponent:@"proof.png"]
                                    atomically:YES];
    NSString* documentPath = [documentDirectory stringByAppendingPathComponent:@"proof.md"];
    [@"![Pinned](proof.png)\n" writeToFile:documentPath atomically:YES
                                  encoding:NSUTF8StringEncoding error:nil];

    NSError* error = nil;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new]
        loadURL:[NSURL fileURLWithPath:documentPath] error:&error];
    NSString* originalDirectory = [root stringByAppendingPathComponent:@"original"];
    [NSFileManager.defaultManager moveItemAtPath:documentDirectory toPath:originalDirectory error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:documentDirectory
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [SPDFTinyPNG(NSColor.blueColor) writeToFile:[documentDirectory stringByAppendingPathComponent:@"proof.png"]
                                     atomically:YES];
    [@"![Replacement](proof.png)\n" writeToFile:documentPath atomically:YES
                                       encoding:NSUTF8StringEncoding error:nil];

    SPDFMarkdownRenderedDocument* rendered = [[SPDFMarkdownRenderer new]
        renderModel:model options:SPDFMarkdownRenderOptions.defaultOptions languageOverrides:nil];
    __block NSImage* image = nil;
    [rendered.attributedString enumerateAttribute:NSAttachmentAttributeName
                                          inRange:NSMakeRange(0, rendered.attributedString.length)
                                          options:0
                                       usingBlock:^(NSTextAttachment* attachment, NSRange range, BOOL* stop) {
        (void)range;
        if (attachment.image) {
            image = attachment.image;
            *stop = YES;
        }
    }];
    NSBitmapImageRep* pixels = image ? [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation] : nil;
    NSColor* pixel = [[pixels colorAtX:0 y:0] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    SPDFExpect(model != nil && error == nil && pixel.redComponent > 0.9 && pixel.blueComponent < 0.1,
               @"parsed models retain the original resource root when their pathname is replaced before render");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void SPDFTestPinnedRootAndBudgets(NSURL* fixture, NSString* temporaryRoot) {
    NSString* documentDirectory = [temporaryRoot stringByAppendingPathComponent:@"document"];
    SPDFMarkdownResourceStore* pinned = [[SPDFMarkdownResourceStore alloc] initWithDocumentURL:fixture];
    NSString* movedDirectory = [temporaryRoot stringByAppendingPathComponent:@"original"];
    [NSFileManager.defaultManager moveItemAtPath:documentDirectory toPath:movedDirectory error:nil];
    NSString* replacementImages = [documentDirectory stringByAppendingPathComponent:@"images"];
    [NSFileManager.defaultManager createDirectoryAtPath:replacementImages withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    [@"replacement" writeToFile:[replacementImages stringByAppendingPathComponent:@"inside.bin"]
                      atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"# replacement\n" writeToFile:[documentDirectory stringByAppendingPathComponent:@"document.md"]
                           atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSURL* resolved = nil;
    NSData* pinnedData = [pinned dataForTarget:@"images/inside.bin" resolvedURL:&resolved];
    SPDFExpect([[[NSString alloc] initWithData:pinnedData encoding:NSUTF8StringEncoding] isEqualToString:@"inside"] &&
                   [resolved.path containsString:@"/original/images/inside.bin"],
               @"resource store remains attached to its verified root after pathname replacement");

    NSData* red = SPDFTinyPNG(NSColor.redColor);
    NSData* blue = SPDFTinyPNG(NSColor.blueColor);
    [red writeToFile:[movedDirectory stringByAppendingPathComponent:@"red.png"] atomically:YES];
    [blue writeToFile:[movedDirectory stringByAppendingPathComponent:@"blue.png"] atomically:YES];
    NSURL* movedDocument = [NSURL fileURLWithPath:[movedDirectory stringByAppendingPathComponent:@"document.md"]];
    SPDFMarkdownResourceStore* pixels = [[SPDFMarkdownResourceStore alloc]
        initWithDocumentURL:movedDocument maximumResourceBytes:red.length + blue.length
        maximumDecodedImagePixels:8];
    NSImage* first = [pixels imageForTarget:@"red.png" resolvedURL:nil];
    NSImage* repeated = [pixels imageForTarget:@"red.png#again" resolvedURL:nil];
    NSImage* overPixelBudget = [pixels imageForTarget:@"blue.png" resolvedURL:nil];
    SPDFExpect(first && first == repeated && !overPixelBudget && pixels.cachedResourceCount == 2 &&
                   pixels.decodedImagePixels == 8,
               @"image cache charges repeated references once and enforces the aggregate decoded-pixel budget");

    SPDFMarkdownResourceStore* bytes = [[SPDFMarkdownResourceStore alloc]
        initWithDocumentURL:movedDocument maximumResourceBytes:red.length
        maximumDecodedImagePixels:100];
    SPDFExpect([bytes dataForTarget:@"red.png" resolvedURL:nil] != nil &&
                   [bytes dataForTarget:@"blue.png" resolvedURL:nil] == nil &&
                   bytes.loadedResourceBytes == red.length,
               @"resource store enforces its aggregate compressed-byte budget");
}

int main(void) {
    @autoreleasepool {
        SPDFMarkdownParser* parser = [SPDFMarkdownParser new];
        NSError* error = nil;
        SPDFMarkdownDocumentModel* common = [parser loadURL:SPDFFixtureURL(@"commonmark-gfm.md") error:&error];
        SPDFExpect(common != nil && error == nil, @"CommonMark fixture parses");
        SPDFExpect(common.headings.count == 2, @"heading index contains both headings");
        SPDFExpect(common.codeFences.count == 2, @"both fenced code blocks are indexed");
        SPDFExpect([common.codeFences.firstObject.declaredLanguage isEqualToString:@"swift"],
                   @"declared fence language is retained");
        SPDFExpect(common.codeFences.lastObject.declaredLanguage == nil, @"missing fence language remains explicit");
        NSString* direct = SPDFDirectText(common.blocks);
        SPDFExpect([direct componentsSeparatedByString:@"Shenzhen PDF Markdown"].count == 2,
                   @"subtree text is not recursively duplicated");

        SPDFMarkdownDocumentModel* obsidian = [parser loadURL:SPDFFixtureURL(@"obsidian.md") error:&error];
        SPDFExpect([obsidian.frontMatter[@"title"] isEqualToString:@"Project Notes"], @"front matter is extracted");
        SPDFExpect(![SPDFDirectText(obsidian.blocks) containsString:@"title: Project Notes"],
                   @"front matter is not content");
        NSArray* blocks = SPDFAllBlocks(obsidian.blocks);
        NSPredicate* calloutPredicate = [NSPredicate predicateWithBlock:^BOOL(SPDFMarkdownBlock* block, NSDictionary* _) {
            return block.kind == SPDFMarkdownBlockKindCallout;
        }];
        SPDFMarkdownBlock* callout = [[blocks filteredArrayUsingPredicate:calloutPredicate] firstObject];
        SPDFExpect([callout.calloutKind isEqualToString:@"IMPORTANT"] &&
                       [callout.calloutTitle isEqualToString:@"Release gate"],
                   @"Obsidian callout metadata is recognized");
        SPDFMarkdownInlineRun* alias = nil;
        for (SPDFMarkdownBlock* block in blocks)
            for (SPDFMarkdownInlineRun* run in block.runs)
                if (run.traits & SPDFMarkdownInlineTraitWikiLink) { alias = run; break; }
        SPDFExpect([alias.text isEqualToString:@"the design note"] &&
                       [alias.destination isEqualToString:@"Design Notes"],
                   @"wikilink alias and target are retained separately");

        SPDFMarkdownDocumentModel* unsafe = [parser loadURL:SPDFFixtureURL(@"unsafe.md") error:&error];
        NSString* unsafeText = SPDFDirectText(unsafe.blocks);
        SPDFExpect(![unsafeText containsString:@"<script>"] && ![unsafeText containsString:@"alert"] &&
                       ![unsafeText containsString:@"onerror"] &&
                       ![unsafeText containsString:@"window.location"],
                   @"raw HTML is sanitized: scripts and event handlers never become text");
        NSString* temporaryRoot = nil;
        NSURL* fixture = SPDFCreateResourceFixture(&temporaryRoot);
        SPDFExpect([SPDFMarkdownParser localResourceDataForTarget:@"https://example.com/a.png"
                                            relativeToDocumentURL:fixture resolvedURL:nil] == nil,
                   @"remote resources are rejected");
        SPDFExpect([SPDFMarkdownParser localResourceDataForTarget:@"data:image/png;base64,AAAA"
                                            relativeToDocumentURL:fixture resolvedURL:nil] == nil,
                   @"data resources are rejected");
        SPDFExpect([SPDFMarkdownParser localResourceDataForTarget:@"../escape.png"
                                            relativeToDocumentURL:fixture resolvedURL:nil] == nil,
                   @"parent traversal is rejected");
        SPDFExpect([SPDFMarkdownParser localResourceDataForTarget:@"images/../escape.png"
                                            relativeToDocumentURL:fixture resolvedURL:nil] == nil,
                   @"embedded parent traversal is rejected even when it normalizes inside the root");
        SPDFExpect([SPDFMarkdownParser localResourceDataForTarget:@"/tmp/escape.png"
                                            relativeToDocumentURL:fixture resolvedURL:nil] == nil,
                   @"absolute paths are rejected");
        SPDFExpect([SPDFMarkdownParser localResourceDataForTarget:@"images/escape/secret.bin"
                                            relativeToDocumentURL:fixture resolvedURL:nil] == nil,
                   @"existing outward symlinks are rejected");
        SPDFExpect([SPDFMarkdownParser localResourceDataForTarget:@"images/broken/future.bin"
                                            relativeToDocumentURL:fixture resolvedURL:nil] == nil,
                   @"broken outward symlinks fail closed");
        NSURL* resolved = nil;
        NSData* local = [SPDFMarkdownParser localResourceDataForTarget:@"images/inside.bin#preview"
                                                 relativeToDocumentURL:fixture resolvedURL:&resolved];
        SPDFExpect([[[NSString alloc] initWithData:local encoding:NSUTF8StringEncoding] isEqualToString:@"inside"] &&
                       [resolved.path hasSuffix:@"document/images/inside.bin"],
                   @"document-root resources are read from a no-follow descriptor walk");
        SPDFTestPinnedRootAndBudgets(fixture, temporaryRoot);
        SPDFTestModelPinsResourcesAcrossPathReplacement();

        NSString* international = @"\uFEFF# 标题\r\n\r\nEmoji 😀 and e\u0301.\r\n";
        SPDFMarkdownDocumentModel* unicode = [parser parseString:international sourceURL:nil error:&error];
        SPDFExpect([SPDFDirectText(unicode.blocks) containsString:@"标题"], @"BOM and CRLF CJK parse");
        SPDFExpect([SPDFDirectText(unicode.blocks) containsString:@"😀"], @"emoji survives UTF-8 parsing");
        SPDFMarkdownDocumentModel* CRLFFrontMatter =
            [parser parseString:@"\uFEFF---\r\ntitle: Windows Notes\r\n---\r\n# Body\r\n"
                      sourceURL:nil error:&error];
        SPDFExpect([CRLFFrontMatter.frontMatter[@"title"] isEqualToString:@"Windows Notes"] &&
                       [SPDFDirectText(CRLFFrontMatter.blocks) containsString:@"Body"],
                   @"BOM and CRLF YAML front matter are normalized before parsing");

        const unsigned char invalidBytes[] = {0xc3, 0x28};
        NSData* invalid = [NSData dataWithBytes:invalidBytes length:sizeof(invalidBytes)];
        error = nil;
        SPDFExpect([parser parseData:invalid sourceURL:nil error:&error] == nil &&
                       error.code == SPDFMarkdownErrorInvalidUTF8,
                   @"invalid UTF-8 is rejected");
        parser.maximumInputBytes = 4;
        error = nil;
        SPDFExpect([parser parseString:@"12345" sourceURL:nil error:&error] == nil &&
                       error.code == SPDFMarkdownErrorTooLarge,
                   @"parseString enforces the byte cap");
        parser.maximumInputBytes = 1024 * 1024;
        error = nil;
        SPDFExpect([parser loadURL:[NSURL URLWithString:@"https://example.com/readme.md"] error:&error] == nil &&
                       error.code == SPDFMarkdownErrorNonFileURL,
                   @"loads accept file URLs only");

        parser.maximumNestingDepth = 8;
        NSMutableString* nested = [NSMutableString string];
        for (NSUInteger i = 0; i < 40; ++i) [nested appendString:@"> "];
        [nested appendString:@"deep\n"];
        error = nil;
        SPDFExpect([parser parseString:nested sourceURL:nil error:&error] == nil &&
                       error.code == SPDFMarkdownErrorBudgetExceeded,
                   @"pathological nesting is rejected safely");
        parser.maximumNestingDepth = 128;
        parser.maximumNodeCount = 3;
        error = nil;
        SPDFExpect([parser parseString:@"# a\n\n*b*\n\n[c](https://e.test)\n" sourceURL:nil error:&error] == nil &&
                       error.code == SPDFMarkdownErrorBudgetExceeded,
                   @"structural and inline nodes share one budget");

        parser.maximumNodeCount = 1000;
        SPDFMarkdownDocumentModel* table = [parser parseString:@"| left | right |\n| :--- | ---: |\n| a | b |\n"
                                                       sourceURL:nil error:&error];
        NSArray* tableBlocks = SPDFAllBlocks(table.blocks);
        SPDFMarkdownBlock* tableNode = nil;
        for (SPDFMarkdownBlock* block in tableBlocks)
            if (block.kind == SPDFMarkdownBlockKindTable) { tableNode = block; break; }
        NSPredicate* cellPredicate = [NSPredicate predicateWithBlock:^BOOL(SPDFMarkdownBlock* block, NSDictionary* _) {
            return block.kind == SPDFMarkdownBlockKindTableCell;
        }];
        NSArray* cells = [tableBlocks filteredArrayUsingPredicate:cellPredicate];
        SPDFExpect(tableNode.tableColumnCount == 2 && cells.count == 2 &&
                       [cells.firstObject tableAlignment] == SPDFMarkdownTableAlignmentLeft &&
                       [cells.lastObject tableAlignment] == SPDFMarkdownTableAlignmentRight,
                   @"table cell alignment is part of the model");
        [NSFileManager.defaultManager removeItemAtPath:temporaryRoot error:nil];
    }
    return SPDFFinishTests(@"SPDFMarkdownParserTests");
}
