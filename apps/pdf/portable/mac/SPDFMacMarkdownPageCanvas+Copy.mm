#import "SPDFMacMarkdownPageCanvasPrivate.h"

#import "SPDFMacMarkdownCopyText.h"

// Image-aware selection copy backing the Markdown tab's Cmd+C / Copy chain
// (the canvas's copy: fallback and the reader's copySelection:). An
// image-only selection writes the attachment's image itself, a mixed
// selection writes the plain text plus an RTFD rendition that keeps the
// attachments, and a plain-text selection writes the string exactly as the
// pre-image copy path did.

// The image an attachment can put on the pasteboard: its natural decoded
// image when present, else a decode of the attachment's file-wrapper bytes.
static NSImage* SPDFMarkdownAttachmentImage(NSTextAttachment* attachment) {
    if (![attachment isKindOfClass:NSTextAttachment.class]) return nil;
    if (attachment.image) return attachment.image;
    NSData* contents = attachment.fileWrapper.regularFileContents;
    return contents.length ? [[NSImage alloc] initWithData:contents] : nil;
}

@implementation SPDFMacMarkdownPageCanvas (Copy)

- (NSArray<NSImage*>*)spdf_imagesInSelection {
    NSRange range = self.selectedRange;
    if (!range.length || NSMaxRange(range) > self.attributedString.length) return @[];
    NSMutableArray<NSImage*>* images = [NSMutableArray array];
    [self.attributedString enumerateAttribute:NSAttachmentAttributeName
                                      inRange:range
                                      options:0
                                   usingBlock:^(NSTextAttachment* attachment, NSRange attachmentRange, BOOL* stop) {
                                     (void)attachmentRange;
                                     (void)stop;
                                     NSImage* image = SPDFMarkdownAttachmentImage(attachment);
                                     if (image) [images addObject:image];
                                   }];
    return images;
}

- (BOOL)selectionContainsImageAttachment {
    return [self spdf_imagesInSelection].count > 0;
}

// RTFD serialization needs file-wrapper-backed attachments, so image-backed
// attachments are rewrapped around a PNG (TIFF fallback) of their natural-size
// image while keeping the original display bounds.
- (NSData*)spdf_RTFDDataForSelectionRange:(NSRange)range {
    NSMutableAttributedString* substring = [[self.attributedString attributedSubstringFromRange:range] mutableCopy];
    __block NSUInteger imageNumber = 0;
    [substring enumerateAttribute:NSAttachmentAttributeName
                          inRange:NSMakeRange(0, substring.length)
                          options:0
                       usingBlock:^(NSTextAttachment* attachment, NSRange attachmentRange, BOOL* stop) {
                         (void)stop;
                         if (![attachment isKindOfClass:NSTextAttachment.class]) return;
                         if (attachment.fileWrapper.regularFileContents.length) return;
                         NSData* tiff = attachment.image.TIFFRepresentation;
                         if (!tiff) return;
                         NSData* png = [[NSBitmapImageRep imageRepWithData:tiff]
                             representationUsingType:NSBitmapImageFileTypePNG
                                          properties:@{}];
                         NSFileWrapper* wrapper = [[NSFileWrapper alloc] initRegularFileWithContents:png ?: tiff];
                         wrapper.preferredFilename = [NSString stringWithFormat:@"image %lu.%@",
                                                                                (unsigned long)++imageNumber,
                                                                                png ? @"png" : @"tiff"];
                         NSTextAttachment* serializable = [NSTextAttachment new];
                         serializable.fileWrapper = wrapper;
                         serializable.image = attachment.image;
                         serializable.bounds = attachment.bounds;
                         [substring addAttribute:NSAttachmentAttributeName value:serializable range:attachmentRange];
                       }];
    return [substring RTFDFromRange:NSMakeRange(0, substring.length)
                 documentAttributes:@{NSDocumentTypeDocumentAttribute : NSRTFDTextDocumentType}];
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard*)pasteboard
                plainTextTransform:(NSString* (^)(NSString* text))transform {
    NSRange range = self.selectedRange;
    if (!pasteboard || !range.length || NSMaxRange(range) > self.attributedString.length) return NO;
    // Structure-aware plain text (blocks apart, list items and table rows on
    // their own lines, cells tab-separated); the transform runs inside each
    // cell, never across a break. See SPDFMacMarkdownCopyText.h.
    NSString* plain = [self.attributedString.string substringWithRange:range];
    NSString* text = SPDFMacMarkdownCopyText(self.attributedString, range, transform);
    NSArray<NSImage*>* images = [self spdf_imagesInSelection];
    if (!images.count) {
        [pasteboard clearContents];
        return [pasteboard setString:text forType:NSPasteboardTypeString];
    }
    // Exactly one image and nothing but its attachment character (plus
    // surrounding whitespace) selected: the pasteboard gets the image itself
    // at its natural decoded size — the Copy Page Image convention.
    NSString* trimmed = [plain stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (images.count == 1 && trimmed.length == 1 && [trimmed characterAtIndex:0] == NSAttachmentCharacter) {
        [pasteboard clearContents];
        return [pasteboard writeObjects:@[ images.firstObject ]];
    }
    // Mixed selection: the plain text exactly as a text-only copy writes it,
    // plus an RTFD rendition carrying the selected attachments.
    NSPasteboardItem* item = [NSPasteboardItem new];
    [item setString:text forType:NSPasteboardTypeString];
    NSData* rtfd = [self spdf_RTFDDataForSelectionRange:range];
    if (rtfd.length) [item setData:rtfd forType:NSPasteboardTypeRTFD];
    [pasteboard clearContents];
    return [pasteboard writeObjects:@[ item ]];
}

- (NSImage*)imageAtPoint:(NSPoint)point {
    NSUInteger index = [self characterIndexAtPoint:point];
    if (index == NSNotFound) return nil;
    NSAttributedString* string = self.attributedString;
    // CTLine hit-testing returns a caret index, which lands after the
    // character for a click on its right half, so probe the index and the one
    // before it. No selection is read or written: right-click copy is
    // independent of whatever the user had selected.
    NSUInteger candidates[2] = {index, index > 0 ? index - 1 : index};
    for (NSUInteger i = 0; i < 2; ++i) {
        if (candidates[i] >= string.length) continue;
        NSImage* image = SPDFMarkdownAttachmentImage([string attribute:NSAttachmentAttributeName
                                                               atIndex:candidates[i]
                                                        effectiveRange:NULL]);
        if (image) return image;
    }
    return nil;
}

- (void)spdf_retargetCopyItemInMenu:(NSMenu*)menu forImageAtPoint:(NSPoint)point {
    NSImage* image = [self imageAtPoint:point];
    if (!image) return;
    for (NSMenuItem* item in menu.itemArray) {
        if (item.action != @selector(copySelection:) && item.action != @selector(copy:)) continue;
        item.action = @selector(spdf_copyContextImage:);
        item.target = self;
        item.representedObject = image;
        return;
    }
}

- (void)spdf_copyContextImage:(id)sender {
    NSImage* image = [sender isKindOfClass:NSMenuItem.class] ? ((NSMenuItem*)sender).representedObject : nil;
    if (![image isKindOfClass:NSImage.class]) {
        NSBeep();
        return;
    }
    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[ image ]]) NSBeep();
}

@end
