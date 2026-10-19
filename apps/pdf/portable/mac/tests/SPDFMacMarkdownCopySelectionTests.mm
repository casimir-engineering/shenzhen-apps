#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownPageCanvasPrivate.h"
#import "../SPDFMacMarkdownPagedView.h"
#import "../markdown/SPDFMarkdown.h"

#include <assert.h>
#include <stdio.h>

// Image-aware selection copy (the Cmd+C / Copy chain for Markdown tabs):
// - an image-only selection writes the attachment's image at its NATURAL
//   decoded size (the Copy Page Image convention), never the display bounds;
// - a mixed selection writes the plain text exactly as before PLUS an RTFD
//   rendition that keeps the attachments;
// - double-clicking an image selects exactly its attachment character;
// - the Copy menu validation seam (selectionContainsImage) reports image-only
//   selections whose plain text carries no word characters at all.

static NSImage* SPDFTestImageWithPixelSize(NSInteger width, NSInteger height) {
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:width
                                                                    pixelsHigh:height
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image addRepresentation:rep];
    return image;
}

static NSUInteger SPDFTestAttachmentCount(NSAttributedString* string) {
    __block NSUInteger count = 0;
    [string enumerateAttribute:NSAttachmentAttributeName
                       inRange:NSMakeRange(0, string.length)
                       options:0
                    usingBlock:^(NSTextAttachment* attachment, NSRange range, BOOL* stop) {
                      (void)range;
                      (void)stop;
                      if ([attachment isKindOfClass:NSTextAttachment.class]) count++;
                    }];
    return count;
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;

        // "Alpha " + image A (64x40 natural, 320x200 display) + " " +
        // image B (32x20 natural) + " beside words\n"
        NSTextAttachment* attachmentA = [NSTextAttachment new];
        attachmentA.image = SPDFTestImageWithPixelSize(64, 40);
        attachmentA.bounds = NSMakeRect(0, 0, 320, 200);  // scaled display bounds, NOT the natural size
        NSTextAttachment* attachmentB = [NSTextAttachment new];
        attachmentB.image = SPDFTestImageWithPixelSize(32, 20);
        attachmentB.bounds = NSMakeRect(0, 0, 16, 10);
        NSMutableAttributedString* line = [[NSMutableAttributedString alloc] initWithString:@"Alpha "];
        [line appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachmentA]];
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{}]];
        [line appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachmentB]];
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:@" beside words\n" attributes:@{}]];
        const NSUInteger attachmentAIndex = 6;
        const NSUInteger attachmentBIndex = 8;
        assert([line.string characterAtIndex:attachmentAIndex] == NSAttachmentCharacter);
        assert([line.string characterAtIndex:attachmentBIndex] == NSAttachmentCharacter);

        SPDFMarkdownPageConfiguration* configuration = [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
        SPDFMarkdownTextLine* textLine = [[SPDFMarkdownTextLine alloc]
            initWithAttributedRange:NSMakeRange(0, line.length) height:30 xOffset:0 baselineOffset:24];
        SPDFMarkdownPaginationItem* item = [[SPDFMarkdownPaginationItem alloc]
            initWithBlockIndex:0 kind:SPDFMarkdownBlockKindParagraph headingLevel:0 lines:@[ textLine ]];
        SPDFMarkdownPaginationPlan* plan = [[SPDFMarkdownPaginator new] paginateItems:@[ item ]
                                                                        configuration:configuration];
        SPDFMacMarkdownPagedView* view = [[SPDFMacMarkdownPagedView alloc] initWithPaginationPlan:plan
                                                                                 attributedString:line];
        view.frame = NSMakeRect(0, 0, 900, 700);
        [view layoutSubtreeIfNeeded];
        SPDFMacMarkdownPageCanvas* canvas = (SPDFMacMarkdownPageCanvas*)view.documentView;

        // --- Image-only selection: the attachment character plus surrounding
        // whitespace writes the image itself at its natural decoded size ---
        view.selectedRange = NSMakeRange(attachmentAIndex - 1, 3);  // " <image A> "
        assert(view.selectionContainsImage);
        NSPasteboard* imagePasteboard = [NSPasteboard pasteboardWithUniqueName];
        assert([view writeSelectionToPasteboard:imagePasteboard plainTextTransform:nil]);
        NSBitmapImageRep* pastedRep =
            [NSBitmapImageRep imageRepWithData:[imagePasteboard dataForType:NSPasteboardTypeTIFF]];
        assert(pastedRep != nil);
        assert(pastedRep.pixelsWide == 64 && pastedRep.pixelsHigh == 40);  // natural size, not 320x200 bounds
        assert([imagePasteboard stringForType:NSPasteboardTypeString] == nil);  // the image, plus nothing else

        // Copy validation seam: the selection's plain text holds no word
        // characters at all (whitespace + the attachment character), yet the
        // image keeps Copy enabled through selectionContainsImage.
        NSMutableCharacterSet* ignorable = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [ignorable addCharactersInString:[NSString stringWithFormat:@"%C", (unichar)NSAttachmentCharacter]];
        assert([view.selectedText stringByTrimmingCharactersInSet:ignorable].length == 0);
        assert(view.selectionContainsImage);

        // --- Mixed selection (text + images): plain text as before PLUS an
        // RTFD rendition that carries the attachments ---
        view.selectedRange = NSMakeRange(0, line.length);
        NSPasteboard* mixedPasteboard = [NSPasteboard pasteboardWithUniqueName];
        assert([view writeSelectionToPasteboard:mixedPasteboard plainTextTransform:nil]);
        assert([[mixedPasteboard stringForType:NSPasteboardTypeString] isEqualToString:line.string]);
        NSData* rtfd = [mixedPasteboard dataForType:NSPasteboardTypeRTFD];
        assert(rtfd.length > 0);
        NSAttributedString* roundTrip = [[NSAttributedString alloc] initWithRTFD:rtfd documentAttributes:NULL];
        assert(roundTrip != nil);
        assert([roundTrip.string containsString:@"Alpha"] && [roundTrip.string containsString:@"beside words"]);
        assert(SPDFTestAttachmentCount(roundTrip) == 2);
        // The first round-tripped attachment decodes at image A's natural size.
        NSString* attachmentCharacter = [NSString stringWithFormat:@"%C", (unichar)NSAttachmentCharacter];
        NSRange effective = NSMakeRange(0, 0);
        NSTextAttachment* decoded = [roundTrip attribute:NSAttachmentAttributeName
                                                 atIndex:[roundTrip.string rangeOfString:attachmentCharacter].location
                                          effectiveRange:&effective];
        assert(decoded != nil);
        NSBitmapImageRep* decodedRep =
            [NSBitmapImageRep imageRepWithData:decoded.fileWrapper.regularFileContents];
        assert(decodedRep != nil && decodedRep.pixelsWide == 64 && decodedRep.pixelsHigh == 40);

        // Two images with only whitespace between them are a mixed selection
        // (never the single-image fast path): text plus RTFD with both.
        view.selectedRange = NSMakeRange(attachmentAIndex - 1, 4);  // " <A> <B>"
        NSPasteboard* twoImagePasteboard = [NSPasteboard pasteboardWithUniqueName];
        assert([view writeSelectionToPasteboard:twoImagePasteboard plainTextTransform:nil]);
        assert([twoImagePasteboard stringForType:NSPasteboardTypeString] != nil);
        NSData* twoImageRTFD = [twoImagePasteboard dataForType:NSPasteboardTypeRTFD];
        NSAttributedString* twoImages = [[NSAttributedString alloc] initWithRTFD:twoImageRTFD
                                                              documentAttributes:NULL];
        assert(SPDFTestAttachmentCount(twoImages) == 2);

        // --- Text-only selection: the plain string only, transform applied
        // (the collapse-whitespace preference hook), no image types ---
        view.selectedRange = [line.string rangeOfString:@"beside words"];
        assert(!view.selectionContainsImage);
        NSPasteboard* textPasteboard = [NSPasteboard pasteboardWithUniqueName];
        assert([view writeSelectionToPasteboard:textPasteboard
                             plainTextTransform:^NSString*(NSString* text) {
                               return [text stringByReplacingOccurrencesOfString:@" " withString:@"_"];
                             }]);
        assert([[textPasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"beside_words"]);
        assert([textPasteboard dataForType:NSPasteboardTypeRTFD] == nil);
        assert([textPasteboard dataForType:NSPasteboardTypeTIFF] == nil);

        // An empty selection writes nothing and reports NO.
        view.selectedRange = NSMakeRange(0, 0);
        assert(!view.selectionContainsImage);
        NSPasteboard* emptyPasteboard = [NSPasteboard pasteboardWithUniqueName];
        assert(![view writeSelectionToPasteboard:emptyPasteboard plainTextTransform:nil]);

        // --- Double-click parity: word selection still wins for words, and an
        // image resolves to exactly its attachment character — including the
        // caret index CTLine hit-testing returns for a right-half click ---
        NSRange word = [canvas wordRangeAtIndex:1];
        assert(NSEqualRanges(word, [line.string rangeOfString:@"Alpha"]));
        assert(NSEqualRanges([canvas wordRangeAtIndex:attachmentAIndex], NSMakeRange(attachmentAIndex, 1)));
        // Index just after the attachment (a whitespace gap, no word) falls
        // back to the attachment character.
        assert(NSEqualRanges([canvas wordRangeAtIndex:attachmentAIndex + 1], NSMakeRange(attachmentAIndex, 1)));
        assert(NSEqualRanges([canvas wordRangeAtIndex:attachmentBIndex], NSMakeRange(attachmentBIndex, 1)));
        // A word right after an image still word-selects (the fallback never
        // steals clicks that land on real words).
        NSUInteger besideIndex = [line.string rangeOfString:@"beside"].location;
        assert(NSEqualRanges([canvas wordRangeAtIndex:besideIndex], [line.string rangeOfString:@"beside"]));
        // Past-the-end and out-of-range indices stay empty.
        assert([canvas wordRangeAtIndex:line.length + 5].length == 0);

        // --- Right-click copy: the image under the pointer is copied
        // directly, with the selection neither read nor disturbed ---
        NSRect canvasPage = [canvas frameForPageAtIndex:0];
        NSRect printable = configuration.printableRect;
        // Image A occupies the first 320pt after "Alpha " on the line; probe
        // its middle, well inside the attachment.
        CGFloat lineY = NSMinY(canvasPage) + configuration.topContentInset + 15.0;
        NSPoint overImage = NSMakePoint(NSMinX(canvasPage) + NSMinX(printable) + 200.0, lineY);
        NSPoint overText = NSMakePoint(NSMinX(canvasPage) + NSMinX(printable) + 2.0, lineY);
        assert([canvas imageAtPoint:overImage] != nil);
        assert([canvas imageAtPoint:overText] == nil);
        // A text selection is deliberately left in place: the right-click copy
        // path must not consult or rewrite it (the earlier select-then-copy
        // approach failed exactly here).
        NSRange textSelection = [line.string rangeOfString:@"Alpha"];
        view.selectedRange = textSelection;
        NSMenu* contextMenu = [NSMenu new];
        NSMenuItem* copyItem = [[NSMenuItem alloc] initWithTitle:@"Copy"
                                                          action:@selector(copySelection:)
                                                   keyEquivalent:@""];
        [contextMenu addItem:copyItem];
        [canvas spdf_retargetCopyItemInMenu:contextMenu forImageAtPoint:overImage];
        assert(copyItem.target == canvas);
        assert(copyItem.action == @selector(spdf_copyContextImage:));
        NSImage* carried = copyItem.representedObject;
        assert([carried isKindOfClass:NSImage.class]);
        NSBitmapImageRep* carriedRep = [NSBitmapImageRep imageRepWithData:carried.TIFFRepresentation];
        assert(carriedRep.pixelsWide == 64 && carriedRep.pixelsHigh == 40);  // image A at natural size
        assert(NSEqualRanges(view.selectedRange, textSelection));            // selection untouched
        // Off an image the Copy item keeps its original selection-copy wiring.
        NSMenu* textMenu = [NSMenu new];
        NSMenuItem* textCopyItem = [[NSMenuItem alloc] initWithTitle:@"Copy"
                                                              action:@selector(copySelection:)
                                                       keyEquivalent:@""];
        [textMenu addItem:textCopyItem];
        [canvas spdf_retargetCopyItemInMenu:textMenu forImageAtPoint:overText];
        assert(textCopyItem.action == @selector(copySelection:));
        assert(textCopyItem.representedObject == nil);

        [imagePasteboard releaseGlobally];
        [mixedPasteboard releaseGlobally];
        [twoImagePasteboard releaseGlobally];
        [textPasteboard releaseGlobally];
        [emptyPasteboard releaseGlobally];
        puts("SPDFMacMarkdownCopySelectionTests passed");
    }
    return 0;
}
