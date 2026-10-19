// Fictional public documentation content; never read the user's documents.
static NSString* SPDFReadmeMarkdown(void) {
    return @"# Project notes\n\nA compact workspace for documents, research and ideas.\n\n"
        @"## Reading workspace\n\nKeep related documents together and return to the same place.\n\n"
        @"```mermaid\nflowchart LR\n  A[Open document] --> B[Read and search]\n  B --> C[Save history]\n```\n\n"
        @"| Document | Purpose | Status |\n| --- | --- | --- |\n"
        @"| Interface specification | Reader controls | Reviewed |\n"
        @"| Hardware reference | Measurements | In progress |\n"
        @"| Project notes | Decisions and next steps | Current |\n\n"
        @"## Interaction\n\nSelect a document to read; collapse a group without changing the document.\n\n"
        @"- Search includes the matching phrase and nearby context.\n"
        @"- The map keeps the whole document within reach.\n"
        @"- Versions preserve earlier work as read-only copies.\n\n"
        @"<!-- pagebreak -->\n\n# Code and calculations\n\n"
        @"For $n$ samples, the mean is $m = \\frac{1}{n}\\sum x_i$.\n\n"
        @"```python\ndef mean(samples):\n    return sum(samples) / len(samples)\n\n"
        @"measurements = [12.4, 12.5, 12.6]\nprint(mean(measurements))\n```\n\n"
        @"## Delivery plan\n\n```mermaid\ngantt\n  title Reader delivery\n  dateFormat YYYY-MM-DD\n"
        @"  section Workspace\n  Reading and search :done, a, 2026-09-01, 8d\n"
        @"  Groups and history :done, b, after a, 12d\n"
        @"  section Validation\n  Regression checks :active, c, after b, 6d\n```\n";
}

static NSData* SPDFReadmePDFData(void) {
    NSMutableData* data=[NSMutableData data]; CGRect paper=CGRectMake(0,0,595,842);
    CGDataConsumerRef consumer=CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGContextRef context=CGPDFContextCreate(consumer,&paper,NULL); CGDataConsumerRelease(consumer);
    for(NSUInteger page=0;page<3;page++) {
        CGPDFContextBeginPage(context,NULL);
        NSGraphicsContext* saved=NSGraphicsContext.currentContext;
        NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
        [NSColor.whiteColor setFill]; NSRectFill(NSRectFromCGRect(paper));
        NSColor* ink=[NSColor colorWithSRGBRed:.12 green:.15 blue:.19 alpha:1];
        NSColor* accent=[NSColor colorWithSRGBRed:.29 green:.39 blue:.64 alpha:1];
        NSDictionary* title=@{NSFontAttributeName:[NSFont boldSystemFontOfSize:27],NSForegroundColorAttributeName:ink};
        NSDictionary* body=@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:ink};
        NSDictionary* small=@{NSFontAttributeName:[NSFont systemFontOfSize:10],NSForegroundColorAttributeName:accent};
        [@"READER DESIGN / TECHNICAL NOTES" drawAtPoint:NSMakePoint(48,786) withAttributes:small];
        [@[@"Interface specification",@"Reading workspace",@"Technical decisions"][page]
            drawAtPoint:NSMakePoint(48,735) withAttributes:title];
        [@"A focused workspace for reading and organizing documents."
            drawAtPoint:NSMakePoint(48,700) withAttributes:body];
        [accent setFill]; NSRectFill(NSMakeRect(48,680,499,2));
        [@"01  Document organization" drawAtPoint:NSMakePoint(48,643)
            withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:16],NSForegroundColorAttributeName:ink}];
        [@"Keep related references together. Compact tabs leave room for the document,\nwhile named groups retain the structure of a research session."
            drawInRect:NSMakeRect(48,579,499,49) withAttributes:body];
        NSArray* labels=@[@"Open",@"Read and search",@"Preserve history"];
        for(NSUInteger column=0;column<3;column++) {
            CGFloat x=48+column*174;
            [[NSColor colorWithSRGBRed:.94 green:.95 blue:.98 alpha:1] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,513,151,48) xRadius:6 yRadius:6] fill];
            [labels[column] drawAtPoint:NSMakePoint(x+12,530) withAttributes:body];
        }
        [@"02  Validation checklist" drawAtPoint:NSMakePoint(48,466)
            withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:16],NSForegroundColorAttributeName:ink}];
        NSArray* rows=@[@[@"Capability",@"Expected behavior"],@[@"Search",@"Matching text and nearby context"],
            @[@"Groups",@"Persist names, order and document positions"],@[@"Collection",@"Read originals; preserve immutable revisions"],
            @[@"Navigation",@"Chapters, history and a full-document map"]];
        for(NSUInteger row=0;row<rows.count;row++) {
            CGFloat y=420-row*34;
            [[NSColor colorWithSRGBRed:row%2 ? .98 : .94 green:row%2 ? .98 : .95 blue:row%2 ? .99 : .97 alpha:1] setFill];
            NSRectFill(NSMakeRect(48,y,499,34));
            [rows[row][0] drawAtPoint:NSMakePoint(58,y+10) withAttributes:body];
            [rows[row][1] drawAtPoint:NSMakePoint(198,y+10) withAttributes:body];
        }
        [@"03  Delivery notes" drawAtPoint:NSMakePoint(48,233)
            withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:16],NSForegroundColorAttributeName:ink}];
        [@"The reader remembers its layout and reading position. Local inspection\nuses the same document geometry, without starting a background listener.\n\nReview the page, inspect its layout, then refine the source."
            drawInRect:NSMakeRect(48,115,499,100) withAttributes:body];
        [[NSString stringWithFormat:@"ShenzhenPDF / Example document                                      Page %lu of 3",page+1]
            drawAtPoint:NSMakePoint(48,36) withAttributes:small];
        NSGraphicsContext.currentContext=saved; CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context); CGContextRelease(context); return data;
}
