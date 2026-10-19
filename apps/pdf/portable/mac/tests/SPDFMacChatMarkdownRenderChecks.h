// Offscreen renders of every block type at chat scale, light and dark, 1x and 2x, for checking by eye. Written to
// $SPDF_CHAT_MARKDOWN_RENDERS when set; otherwise drawn into a temporary folder that is removed afterwards, so the
// drawing code still runs in every test pass.
#pragma once
#import "SPDFMacChatMarkdownFixtures.h"

static NSString* const ChatEveryBlock =
    @"# Power budget\nThe board takes **5 V** at up to *2 A*; see [the schematic](https://example.com/schematic) "
     "and [page 2](spdf-ai://document?path=a.pdf&page=2). Inline `code`, ~~old~~, and $E = mc^2$ on the baseline.\n\n"
     "## Checklist\n- [x] Regulator chosen\n- [ ] Thermal check\n  1. Measure at 25 °C\n  2. Measure at 60 °C\n\n"
     "### Notes\n> [!NOTE]\n> Keep the input under 5.5 V.\n\n> A quoted line from the datasheet.\n\n"
     "| Rail | Voltage |\n|:--|--:|\n| VBUS | 5.0 V |\n| 3V3 | 3.3 V |\n\n"
     "| Rail | Voltage | Current | Notes |\n|:--|--:|:-:|---|\n| VBUS | 5.0 V | 2 A | From USB-C, negotiated by "
     "the PD controller |\n| 3V3 | 3.3 V | 600 mA | Buck converter, 92% efficient at full load |\n\n"
     "```python\ndef efficiency(p_out, p_in):\n    return p_out / p_in  # ratio, not percent; a long comment past "
     "the edge\n```\n\n$$\\frac{a}{b} = \\sum_{i=0}^{n} x_i^2$$\n\n"
     "```mermaid\nflowchart LR\n  USB[USB-C VBUS] -->|5 V| PD{PD controller} --> BUCK[Buck 3V3] --> MCU[MCU]\n"
     "  BUCK --> LDO[LDO 1V8] --> SENSOR[Sensor]\n```\n\n"
     "```mermaid\nsequenceDiagram\n  Phone->>Host: check in\n  Host-->>Phone: friends online\n```\n\n"
     "```mermaid\npie title Power\n  \"MCU\" : 40\n  \"Radio\" : 35\n  \"Sensor\" : 25\n```\n\n"
     "```mermaid\ngantt\n  dateFormat YYYY-MM-DD\n  section Build\n  Engine :done, a1, 2026-10-01, 5d\n"
     "  Chat :active, a2, after a1, 4d\n```\n\n"
     "---\n\n![Board photo](https://example.com/board.png)\n\n![Loaded photo](https://example.com/loaded.png)\n\nEnd.";

static void WriteChatRender(NSView* view, CGFloat scale, NSString* path) {
    NSSize size = view.bounds.size;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(size.width * scale) pixelsHigh:(NSInteger)(size.height * scale) bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = size;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    Check([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],
          [@"render written: " stringByAppendingString:path]);
    // Something was drawn: the bubble is not one flat colour.
    NSColor* corner = [rep colorAtX:2 y:2];
    NSUInteger different = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 7)
        for (NSInteger x = 0; x < rep.pixelsWide; x += 7)
            if (![[rep colorAtX:x y:y] isEqual:corner]) different++;
    Check(different > 200, [@"the render shows content: " stringByAppendingString:path]);
}

// The temporary render folder, removed when the suite exits, a failed check's exit included.
static NSString* ChatRenderFolder;
static void ChatRemoveRenderFolder(void) {
    if (ChatRenderFolder) [NSFileManager.defaultManager removeItemAtPath:ChatRenderFolder error:nil];
}

static void RunChatRenderChecks(void) {
    NSString* folder = NSProcessInfo.processInfo.environment[@"SPDF_CHAT_MARKDOWN_RENDERS"];
    BOOL temporary = !folder.length;
    if (temporary) {
        folder = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[@"spdf-chat-markdown-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        ChatRenderFolder = folder;
        atexit(ChatRemoveRenderFolder);
    }
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    SPDFMacChatForgetLoadedImages();
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    // One image already loaded for this message, so the render shows both the placeholder and a loaded picture.
    NSURL* loaded = [NSURL URLWithString:@"https://example.com/loaded.png"];
    SPDFMacChatLoadImage(ChatEveryBlock, loaded, recorder.fetcher, nil);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    for (NSString* name in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        NSWindow* window = ChatWindow(NSMakeRect(0, 0, 440, 3000));
        window.appearance = [NSAppearance appearanceNamed:name];
        BOOL dark = [name isEqualToString:NSAppearanceNameDarkAqua];
        SPDFMacChatMarkdownOptions* options = ChatOptions(0, dark, recorder);
        SPDFMacChatMarkdownView* view = [[SPDFMacChatMarkdownView alloc] initWithMarkdown:ChatEveryBlock width:420
                                                                                  options:options];
        [window.contentView addSubview:view];
        [view viewDidChangeEffectiveAppearance];
        view.backgroundColor = SPDFMacChatConcreteColor(dark ? [NSColor colorWithSRGBRed:0x23 / 255.0 green:0x24 / 255.0
                                                                                    blue:0x26 / 255.0 alpha:1]
                                                             : [NSColor colorWithSRGBRed:0xf6 / 255.0 green:0xf6 / 255.0
                                                                                    blue:0xf5 / 255.0 alpha:1], dark);
        view.translatesAutoresizingMaskIntoConstraints = YES;
        view.frame = NSMakeRect(0, 0, 420, view.contentHeight.constant);
        Check(view.wideBlocks.count >= 2, @"the render has sideways strips for its wide blocks");
        for (NSNumber* scale in @[ @1, @2 ])
            WriteChatRender(view, scale.doubleValue,
                            [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"chat-%@-%@x.png",
                                                                                              dark ? @"dark" : @"light",
                                                                                              scale]]);
        // Each strip scrolled to its end: the rest of the table, the code line and the diagram.
        for (NSScrollView* strip in view.wideBlocks) {
            [strip.contentView scrollToPoint:NSMakePoint(NSWidth(strip.documentView.frame) - NSWidth(strip.bounds), 0)];
            [strip reflectScrolledClipView:strip.contentView];
        }
        NSString* scrolled = [NSString stringWithFormat:@"chat-%@-2x-scrolled.png", dark ? @"dark" : @"light"];
        WriteChatRender(view, 2, [folder stringByAppendingPathComponent:scrolled]);
        [window close];
    }
    Check(recorder.count == 1, @"rendering every block fetched only the image loaded on purpose");
    SPDFMacChatForgetLoadedImages();
    if (temporary) [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
}
