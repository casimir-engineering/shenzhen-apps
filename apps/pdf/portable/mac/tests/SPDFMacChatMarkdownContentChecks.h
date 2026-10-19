// Chat scale and blocks: what a message is made of once rendered (SPDFMacChatMarkdown.h).
#pragma once
#import "SPDFMacChatMarkdownFixtures.h"
#import "../SPDFMacAIChatMarkdown.h"
#import "../markdown/SPDFMarkdownDiagram.h"

static NSFont* ChatFontAt(NSAttributedString* text, NSString* needle) {
    NSRange range = [text.string rangeOfString:needle];
    Check(range.location != NSNotFound, [@"rendered text contains " stringByAppendingString:needle]);
    return [text attribute:NSFontAttributeName atIndex:range.location effectiveRange:NULL];
}

static CGFloat ChatWeight(NSFont* font) {
    return [[font.fontDescriptor objectForKey:NSFontTraitsAttribute][NSFontWeightTrait] doubleValue];
}

static void RunChatScaleChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    NSString* source = @"Body text with `inline code`.\n\n# One\n\n## Two\n\n### Three\n\n$$x^2 + y$$\n\n"
                        "- [ ] open task\n- [x] done task\n\n> [!WARNING]\n> Careful with the input.";
    NSAttributedString* text = SPDFMacChatMarkdownRender(source, ChatOptions(360, NO, recorder));
    Check(fabs(ChatFontAt(text, @"Body").pointSize - 13) < .01, @"body text is 13 pt");
    Check(fabs(ChatFontAt(text, @"inline code").pointSize - 12) < .01, @"code is 12 pt");
    NSFont* one = ChatFontAt(text, @"One"), *two = ChatFontAt(text, @"Two"), *three = ChatFontAt(text, @"Three");
    Check(fabs(one.pointSize - 17) < .01 && fabs(two.pointSize - 15) < .01 && fabs(three.pointSize - 13) < .01,
          @"headings are 17, 15 and 13 pt, not the page's 22.75, 19.5 and 16.25");
    Check(ChatWeight(three) >= NSFontWeightSemibold - .01, @"H3 is semibold");
    // Display math at the text size: the page sets it 1.15 times larger.
    NSFont* math = ChatFontAt(text, @"y");
    Check(fabs(math.pointSize - 13) < .05, @"display math sits at the 13 pt text size");
    Check([text.string containsString:@"☐ open task"] && [text.string containsString:@"☑ done task"],
          @"task lists keep their boxes");
    Check([text.string containsString:@"Careful with the input."] &&
              [text.string rangeOfString:@"warning" options:NSCaseInsensitiveSearch].location != NSNotFound,
          @"callouts keep their title");
    Check(![text.string hasSuffix:@"\n"], @"the message ends at its last line, not a blank one");
    // Formulas copy as their LaTeX, inline and display, and leave no trace of how they were found.
    NSAttributedString* formulas = SPDFMacChatMarkdownRender(@"Energy $E = mc^2$ holds.\n\n$$\\frac{a}{b}$$\n\nEnd",
                                                            ChatOptions(360, NO, recorder));
    NSString* copied = SPDFMacChatMarkdownCopyText(formulas, NSMakeRange(0, formulas.length));
    Check([copied containsString:@"Energy $E = mc^2$ holds."] && [copied containsString:@"$$\\frac{a}{b}$$"],
          [@"formulas copy as LaTeX: " stringByAppendingString:copied]);
    NSCharacterSet* markers = [NSCharacterSet characterSetWithRange:NSMakeRange(0xE000, 0x10)];
    Check([formulas.string rangeOfCharacterFromSet:markers].location == NSNotFound &&
              [formulas.string containsString:@"mc"],
          @"the typeset formula stays and no marker remains");
    Check(recorder.count == 0, @"rendering text fetches nothing");
}

static void CheckDiagramFloor(NSString* name, NSString* fence, CGFloat width) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    NSAttributedString* text = SPDFMacChatMarkdownRender(fence, ChatOptions(width, NO, recorder));
    NSArray<SPDFMacChatBlock*>* blocks = ChatBlocks(text);
    Check(blocks.count == 1 && blocks.firstObject.kind == SPDFMacChatBlockDiagram,
          [name stringByAppendingString:@" is drawn as a diagram, not downgraded to code"]);
    NSUInteger labels = 0;
    CGFloat smallest = CGFLOAT_MAX;
    for (SPDFMarkdownPageDecoration* decoration in [blocks.firstObject.plan decorationsForPageIndex:0])
        for (SPDFMarkdownDiagramLabel* label in decoration.diagramLayout.labels) {
            labels++;
            smallest = MIN(smallest, label.fontSize);
        }
    Check(labels > 0, [name stringByAppendingString:@" has labels"]);
    Check(smallest >= SPDFMacChatMarkdownMinimumDiagramLabelSize - .01,
          [NSString stringWithFormat:@"%@ labels never go below 11 pt (smallest %.2f)", name, smallest]);
    // The labels the text pass draws are the same size.
    NSAttributedString* drawn = blocks.firstObject.rendered.attributedString;
    [drawn enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, drawn.length) options:0
                   usingBlock:^(NSFont* font, NSRange range, BOOL* stop) {
                     (void)stop;
                     NSString* part = [[drawn.string substringWithRange:range]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                     if (part.length && font) Check(font.pointSize >= 10.99, [name stringByAppendingString:@" text"]);
                   }];
}

static void RunChatBlockChecks(void) {
    ChatFetchRecorder* recorder = [ChatFetchRecorder new];
    // Tables: one drawn block with the page's chrome, copied as GitHub Markdown.
    NSString* narrow = @"| Rail | Volts |\n|:--|--:|\n| VBUS | 5.0 |\n| 3V3 | 3.3 |";
    NSAttributedString* text = SPDFMacChatMarkdownRender(narrow, ChatOptions(360, NO, recorder));
    NSArray<SPDFMacChatBlock*>* blocks = ChatBlocks(text);
    Check(blocks.count == 1 && blocks.firstObject.kind == SPDFMacChatBlockTable, @"a table is one drawn block");
    Check(NSWidth(blocks.firstObject.contentRect) <= 360, @"a table whose columns fit stays inside the bubble");
    BOOL header = NO;
    for (SPDFMarkdownPageDecoration* decoration in [blocks.firstObject.plan decorationsForPageIndex:0])
        header = header || decoration.type == SPDFMarkdownPageDecorationTypeTableHeaderBand;
    Check(header, @"the table keeps its header band and grid");
    NSString* table = @"| Rail | Volts |\n| :--- | ---: |\n| VBUS | 5.0 |\n| 3V3 | 3.3 |";
    Check([blocks.firstObject.source isEqualToString:table],
          [@"the table copies as Markdown: " stringByAppendingString:blocks.firstObject.source]);
    NSMutableString* wide = [NSMutableString stringWithString:@"| A | B | C | D | E | F |\n"];
    [wide appendString:@"|---|---|---|---|---|---|\n"];
    [wide appendString:@"| a long first cell that keeps going | second | third cell | fourth cell | fifth | the "
                        "sixth column holds a whole sentence of notes about the rail and its regulator |\n"];
    blocks = ChatBlocks(SPDFMacChatMarkdownRender(wide, ChatOptions(300, NO, recorder)));
    CGFloat tableWidth = NSWidth(blocks.firstObject.contentRect);
    Check(tableWidth > 300 && tableWidth <= 2048, @"a table whose columns cannot fit grows past the bubble to scroll");
    Check(tableWidth < 6 * 300, @"an over-long column wraps at its cap instead of running for thousands of points");

    // Code: one drawn block that does not wrap, copied as its code.
    NSString* code = @"def efficiency(p_out, p_in):\n    return p_out / p_in  # a comment long enough to run well past "
                      "the right edge of a chat bubble";
    text = SPDFMacChatMarkdownRender([NSString stringWithFormat:@"```python\n%@\n```", code],
                                     ChatOptions(300, NO, recorder));
    blocks = ChatBlocks(text);
    Check(blocks.count == 1 && blocks.firstObject.kind == SPDFMacChatBlockCode, @"code is one drawn block");
    Check([blocks.firstObject.source isEqualToString:code], @"code copies as exactly its code");
    Check(NSWidth(blocks.firstObject.contentRect) > 300, @"a long code line widens the block instead of wrapping");
    NSUInteger lines = 0;
    for (SPDFMarkdownPageFragment* fragment in blocks.firstObject.plan.pages.firstObject.fragments)
        if (fragment.attributedRange.length) lines++;
    Check(lines == 2, [NSString stringWithFormat:@"two code lines stay two lines (%lu)", (unsigned long)lines]);
    Check(fabs(ChatFontAt(blocks.firstObject.rendered.attributedString, @"def").pointSize - 12) < .01,
          @"code in its box is 12 pt");
    Check([blocks.firstObject.language isEqualToString:@"python"], @"the code header names its language");

    // Rules become a drawn line; nothing from these blocks remains as loose text.
    text = SPDFMacChatMarkdownRender(@"Above\n\n---\n\nBelow", ChatOptions(300, NO, recorder));
    Check(ChatAttachments(text).count == 1 && [text.string containsString:@"Above"], @"a rule is one drawn line");

    // Diagrams: drawn, never shown as their source, and legible at chat width.
    CheckDiagramFloor(@"A wide flowchart", @"```mermaid\nflowchart LR\n  A[USB-C VBUS] -->|5 V| B{PD controller}\n"
                      "  B --> C[Buck converter 3V3] --> D[Microcontroller]\n"
                      "  C --> E[LDO 1V8] --> F[Sensor]\n```", 300);
    CheckDiagramFloor(@"A sequence diagram", @"```mermaid\nsequenceDiagram\n  participant Phone\n  participant Host\n"
                      "  participant Friend\n  Phone->>Host: check in\n  Host-->>Phone: friends online\n"
                      "  Phone->>Friend: hello over the relay\n"
                      "  Note over Phone,Friend: end-to-end encrypted\n```", 300);
    CheckDiagramFloor(@"A Gantt chart", @"```mermaid\ngantt\n  title Release\n  dateFormat YYYY-MM-DD\n"
                      "  section Build\n  Engine :done, a1, 2026-10-01, 5d\n  Chat :active, a2, after a1, 4d\n"
                      "  section Ship\n  Review :a3, after a2, 3d\n```", 300);
    CheckDiagramFloor(@"A pie chart", @"```mermaid\npie title Power\n  \"MCU\" : 40\n  \"Radio\" : 35\n"
                      "  \"Sensor\" : 25\n```", 300);
    CheckDiagramFloor(@"A class diagram", @"```mermaid\nclassDiagram\n  class Session {\n    +String id\n"
                      "    +send(text)\n  }\n  class Store\n  Session --> Store\n```", 300);
    CheckDiagramFloor(@"A state diagram", @"```mermaid\nstateDiagram-v2\n  [*] --> Queued\n  Queued --> Sending\n"
                      "  Sending --> Delivered\n  Sending --> Failed\n  Failed --> Queued\n```", 300);
    CheckDiagramFloor(@"A js-sequence diagram", @"```sequence\nTitle: Hello\nAlice->Bob: Hi Bob\nBob-->Alice: Hi\n```",
                      300);
    CheckDiagramFloor(@"A flowchart.js diagram", @"```flow\nst=>start: Start\nop=>operation: Read the page\n"
                      "e=>end: Done\nst->op->e\n```", 300);
    blocks = ChatBlocks(SPDFMacChatMarkdownRender(@"```mermaid\nflowchart TD\n  A[Start] --> B[End]\n```",
                                                  ChatOptions(300, NO, recorder)));
    Check(NSWidth(blocks.firstObject.contentRect) <= 300, @"a diagram that fits the bubble is not widened");
    // The AI chat's own entry (activity cards) draws diagrams too; it used to show every Mermaid fence as code.
    NSAttributedString* card = SPDFMacAIChatMarkdown(@"```mermaid\nflowchart TD\n  A[Start] --> B[End]\n```", 300, NO);
    Check(ChatBlocks(card).firstObject.kind == SPDFMacChatBlockDiagram && ![card.string containsString:@"flowchart"],
          @"AI chat Markdown draws a Mermaid diagram instead of printing its source");
    // A diagram the engine cannot draw shows its source as code, the engine's own degradation.
    blocks = ChatBlocks(SPDFMacChatMarkdownRender(@"```mermaid\nnot a diagram at all\n```",
                                                  ChatOptions(300, NO, recorder)));
    Check(blocks.count == 1 && blocks.firstObject.kind == SPDFMacChatBlockCode, @"an undrawable diagram shows as code");
    Check(recorder.count == 0, @"blocks fetch nothing");
}
