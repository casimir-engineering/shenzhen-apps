#import <AppKit/AppKit.h>

#import "SPDFMacContextPage.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        NSRect firstPage = NSMakeRect(120, 24, 595, 842);
        CGFloat gap = 18;
        NSRect secondPage = NSOffsetRect(firstPage, 0, NSHeight(firstPage) + gap);

        // A context click names the sheet under the pointer. The gutter and
        // gap name no page instead of borrowing the viewport's current page.
        assert(SPDFMacMarkdownPageIndexAtPoint(NSMakePoint(NSMidX(firstPage), NSMidY(firstPage)), 3,
                                               firstPage, gap) == 0);
        assert(SPDFMacMarkdownPageIndexAtPoint(NSMakePoint(NSMidX(secondPage), NSMidY(secondPage)), 3,
                                               firstPage, gap) == 1);
        assert(SPDFMacMarkdownPageIndexAtPoint(NSMakePoint(NSMidX(firstPage), NSMaxY(firstPage) + 2), 3,
                                               firstPage, gap) == -1);
        assert(SPDFMacMarkdownPageIndexAtPoint(NSMakePoint(NSMinX(firstPage) - 2, NSMidY(firstPage)), 3,
                                               firstPage, gap) == -1);

        NSMenuItem* contextCopy = [[NSMenuItem alloc] initWithTitle:@"Copy Page" action:nil keyEquivalent:@""];
        contextCopy.representedObject = @1;
        assert(SPDFMacPageIndexForActionSender(contextCopy, -1, 0) == 1);
        assert(SPDFMacPageIndexForActionSender(nil, -1, 2) == 2);
        assert([SPDFMacCopyPageMenuTitle(2, NO) isEqualToString:@"Copy Page 3 as PDF"]);
        assert([SPDFMacCopyPageMenuTitle(2, YES) isEqualToString:@"Copy Page 3 as Image"]);
        assert([SPDFMacCopyPageMenuTitle(-1, NO) isEqualToString:@"Copy Page as PDF"]);
    }
    puts("SPDF mac context-page tests passed");
    return 0;
}
