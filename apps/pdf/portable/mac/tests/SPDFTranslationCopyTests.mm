// Headless end-to-end test for whole-document translation output:
// spdf_save_translated_copy_full on a synthetic PDF with a 3-level outline,
// text-bearing annotations, a link, and mixed Chinese/Latin/digit text blocks,
// using a stubbed "translator" and the spdf_translation_should_translate
// decision (source zh, target en) exactly like the Mac UI pipeline.
//
// Verifies that the written copy:
//   (a) keeps the full outline tree (count, nesting levels, destinations,
//       expansion state) -- the "chapters disappear" regression,
//   (b) has translated outline titles and comment texts where the decision
//       says translate,
//   (c) leaves items not in the source language untouched (Latin outline
//       title, Latin comment, Latin/digit body blocks),
//   (d) keeps the page count and draws body overlays only for translated
//       blocks, and keeps link annotations working.

#import <Foundation/Foundation.h>

#include <unistd.h>
#include <vector>

#include "mupdf/fitz.h"
#include "mupdf/pdf.h"

#import "shenzhen_pdf_core.h"

static int gFailureCount = 0;

#define EXPECT(cond, ...)                          \
    do {                                           \
        if (!(cond)) {                             \
            fprintf(stderr, "FAIL " __VA_ARGS__);  \
            fprintf(stderr, " [line %d]\n", __LINE__); \
            ++gFailureCount;                       \
        }                                          \
    } while (0)

// --- Synthetic PDF fixture -------------------------------------------------
// Chinese body text is made extractable without embedding a CJK font: a
// Helvetica-based font (/F2) carries a /ToUnicode CMap mapping the bytes
// A-D to Han code points, so structured text extraction yields real Han
// ideographs while the file stays pure ASCII.

static void append_object(NSMutableData* pdf, NSUInteger* offsets, NSUInteger num, NSString* body) {
    offsets[num] = pdf.length;
    NSString* text = [NSString stringWithFormat:@"%lu 0 obj\n%@\nendobj\n", (unsigned long)num, body];
    [pdf appendData:[text dataUsingEncoding:NSASCIIStringEncoding]];
}

static void append_stream_object(NSMutableData* pdf, NSUInteger* offsets, NSUInteger num, NSString* stream) {
    NSString* body = [NSString stringWithFormat:@"<</Length %lu>>\nstream\n%@\nendstream",
                                                (unsigned long)[stream lengthOfBytesUsingEncoding:NSASCIIStringEncoding],
                                                stream];
    append_object(pdf, offsets, num, body);
}

static NSData* build_fixture_pdf(void) {
    static const NSUInteger kObjectCount = 22;
    NSMutableData* pdf = [NSMutableData data];
    NSUInteger offsets[kObjectCount + 1] = {0};

    [pdf appendData:[@"%PDF-1.7\n" dataUsingEncoding:NSASCIIStringEncoding]];

    append_object(pdf, offsets, 1, @"<</Type/Catalog/Pages 2 0 R/Outlines 16 0 R>>");
    append_object(pdf, offsets, 2, @"<</Type/Pages/Kids[3 0 R 4 0 R 5 0 R]/Count 3>>");
    append_object(pdf, offsets, 3,
                  @"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 6 0 R"
                  @"/Resources<</Font<</F1 9 0 R/F2 10 0 R>>>>/Annots[12 0 R]>>");
    append_object(pdf, offsets, 4,
                  @"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 7 0 R"
                  @"/Resources<</Font<</F1 9 0 R/F2 10 0 R>>>>/Annots[13 0 R 14 0 R 15 0 R]>>");
    append_object(pdf, offsets, 5,
                  @"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 8 0 R"
                  @"/Resources<</Font<</F1 9 0 R>>>>/Annots[21 0 R]>>");

    // Page 1: Latin heading, Han block ("ABCD" -> U+786C U+4EF6 U+8BBE U+8BA1), digits-only block.
    append_stream_object(pdf, offsets, 6,
                         @"BT /F1 14 Tf 72 700 Td (Hardware Design Manual) Tj ET\n"
                         @"BT /F2 12 Tf 72 640 Td (ABCD) Tj ET\n"
                         @"BT /F1 10 Tf 72 580 Td (3.3 100 42) Tj ET");
    // Page 2: Han block ("AB" -> U+786C U+4EF6), Latin block.
    append_stream_object(pdf, offsets, 7,
                         @"BT /F2 12 Tf 72 700 Td (AB) Tj ET\n"
                         @"BT /F1 12 Tf 72 600 Td (Purely Latin caption) Tj ET");
    // Page 3: Latin only.
    append_stream_object(pdf, offsets, 8, @"BT /F1 12 Tf 72 700 Td (Appendix content only) Tj ET");

    append_object(pdf, offsets, 9, @"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>");
    append_object(pdf, offsets, 10, @"<</Type/Font/Subtype/Type1/BaseFont/Helvetica/ToUnicode 11 0 R>>");
    append_stream_object(pdf, offsets, 11,
                         @"/CIDInit /ProcSet findresource begin\n"
                         @"12 dict begin\n"
                         @"begincmap\n"
                         @"/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def\n"
                         @"/CMapName /Adobe-Identity-UCS def\n"
                         @"/CMapType 2 def\n"
                         @"1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
                         @"4 beginbfchar\n<41> <786C>\n<42> <4EF6>\n<43> <8BBE>\n<44> <8BA1>\nendbfchar\n"
                         @"endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend");

    // Annotations. Chinese strings are UTF-16BE hex text strings.
    append_object(pdf, offsets, 12,
                  @"<</Type/Annot/Subtype/Text/Rect[500 700 524 724]/Contents<FEFF786C4EF6>/T(Zhang)>>");
    append_object(pdf, offsets, 13,
                  @"<</Type/Annot/Subtype/Text/Rect[500 700 524 724]/Contents(Looks good)/T(Bob)>>");
    append_object(pdf, offsets, 14,
                  @"<</Type/Annot/Subtype/Highlight/Rect[72 694 200 712]"
                  @"/QuadPoints[72 712 200 712 72 694 200 694]/Contents<FEFF8BBE8BA1>/T(Zhang)>>");
    append_object(pdf, offsets, 15,
                  @"<</Type/Annot/Subtype/Link/Rect[72 640 200 652]/Border[0 0 0]"
                  @"/A<</S/URI/URI(https://example.com/)>>>>");

    // Outline, three levels: A (Chinese, collapsed) -> A.1 (Chinese, open) ->
    // A.1.1 (Chinese); then B (Latin) at the top level.
    append_object(pdf, offsets, 16, @"<</Type/Outlines/First 17 0 R/Last 20 0 R/Count 2>>");
    append_object(pdf, offsets, 17,
                  @"<</Title<FEFF786C4EF6>/Parent 16 0 R/Next 20 0 R/First 18 0 R/Last 18 0 R/Count -1"
                  @"/Dest[3 0 R /XYZ 0 792 0]>>");
    append_object(pdf, offsets, 18,
                  @"<</Title<FEFF8BBE8BA1>/Parent 17 0 R/First 19 0 R/Last 19 0 R/Count 1"
                  @"/Dest[4 0 R /XYZ 0 792 0]>>");
    append_object(pdf, offsets, 19, @"<</Title<FEFF75356E90>/Parent 18 0 R/Dest[4 0 R /XYZ 100 500 0]>>");
    append_object(pdf, offsets, 20, @"<</Title(Appendix)/Parent 16 0 R/Prev 17 0 R/Dest[5 0 R /XYZ 0 792 0]>>");

    // FreeText comment (page 3) with Chinese contents and a pre-existing
    // appearance stream: translation must regenerate the appearance, not
    // keep drawing the stale one.
    append_object(pdf, offsets, 21,
                  @"<</Type/Annot/Subtype/FreeText/Rect[72 600 300 640]/Contents<FEFF786C4EF6>"
                  @"/DA(/Helv 12 Tf 0 g)/T(Zhang)/AP<</N 22 0 R>>>>");
    offsets[22] = pdf.length;
    NSString* apStream = @"BT /F1 12 Tf 4 10 Td (STALE-AP-TEXT) Tj ET";
    NSString* apBody = [NSString
        stringWithFormat:@"22 0 obj\n<</Type/XObject/Subtype/Form/BBox[0 0 228 40]"
                         @"/Resources<</Font<</F1 9 0 R>>>>/Length %lu>>\nstream\n%@\nendstream\nendobj\n",
                         (unsigned long)[apStream lengthOfBytesUsingEncoding:NSASCIIStringEncoding], apStream];
    [pdf appendData:[apBody dataUsingEncoding:NSASCIIStringEncoding]];

    NSUInteger xref_offset = pdf.length;
    NSMutableString* xref = [NSMutableString string];
    [xref appendFormat:@"xref\n0 %lu\n", (unsigned long)(kObjectCount + 1)];
    [xref appendString:@"0000000000 65535 f \n"];
    for (NSUInteger i = 1; i <= kObjectCount; ++i) [xref appendFormat:@"%010lu 00000 n \n", (unsigned long)offsets[i]];
    [xref appendFormat:@"trailer\n<</Size %lu/Root 1 0 R>>\nstartxref\n%lu\n%%%%EOF\n",
                       (unsigned long)(kObjectCount + 1), (unsigned long)xref_offset];
    [pdf appendData:[xref dataUsingEncoding:NSASCIIStringEncoding]];
    return pdf;
}

// --- Helpers ---------------------------------------------------------------

// Decompressed /AP/N stream of the first FreeText annotation on a page
// (annotation appearances are not part of structured text extraction, so the
// test reads the appearance stream directly through mupdf).
static NSString* freetext_appearance_stream(NSString* path, int page_index) {
    fz_context* ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    NSString* result = nil;
    if (!ctx) return nil;
    fz_var(result);
    fz_try(ctx) {
        pdf_document* doc = pdf_open_document(ctx, path.fileSystemRepresentation);
        pdf_obj* page = pdf_lookup_page_obj(ctx, doc, page_index);
        pdf_obj* annots = pdf_dict_get(ctx, page, PDF_NAME(Annots));
        int i;
        for (i = 0; i < pdf_array_len(ctx, annots); ++i) {
            pdf_obj* annot = pdf_array_get(ctx, annots, i);
            pdf_obj* ap;
            fz_buffer* buf;
            unsigned char* data = NULL;
            size_t len;
            if (!pdf_name_eq(ctx, pdf_dict_get(ctx, annot, PDF_NAME(Subtype)), PDF_NAME(FreeText))) continue;
            ap = pdf_dict_getl(ctx, annot, PDF_NAME(AP), PDF_NAME(N), NULL);
            if (!pdf_is_stream(ctx, ap)) continue;
            buf = pdf_load_stream(ctx, ap);
            len = fz_buffer_storage(ctx, buf, &data);
            result = [[NSString alloc] initWithBytes:data length:len encoding:NSISOLatin1StringEncoding];
            fz_drop_buffer(ctx, buf);
            break;
        }
        pdf_drop_document(ctx, doc);
    }
    fz_catch(ctx) {
        result = nil;
    }
    fz_drop_context(ctx);
    return result;
}

static NSString* page_text(spdf_document* doc, int page_index) {
    spdf_text_lines lines;
    char err[512];
    NSMutableString* text = [NSMutableString string];
    memset(&lines, 0, sizeof(lines));
    if (!spdf_extract_page_text_lines(doc, page_index, &lines, err, sizeof(err))) return @"";
    for (int i = 0; i < lines.count; ++i) {
        NSString* line = lines.items[i].text ? [NSString stringWithUTF8String:lines.items[i].text] : nil;
        if (!line) continue;
        [text appendString:line];
        [text appendString:@"\n"];
    }
    spdf_free_text_lines(&lines);
    return text;
}

static const char* kHanBlock1 = "\xE7\xA1\xAC\xE4\xBB\xB6\xE8\xAE\xBE\xE8\xAE\xA1"; // 硬件设计
static const char* kHanBlock2 = "\xE7\xA1\xAC\xE4\xBB\xB6";                         // 硬件
static const char* kHanComment1 = "\xE7\xA1\xAC\xE4\xBB\xB6";                       // 硬件
static const char* kHanComment2 = "\xE8\xAE\xBE\xE8\xAE\xA1";                       // 设计
static const char* kHanOutline2 = "\xE8\xAE\xBE\xE8\xAE\xA1";                       // 设计
static const char* kHanOutline3 = "\xE7\x94\xB5\xE6\xBA\x90";                       // 电源

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSString* dir = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"spdf-translation-copy-%d", getpid()]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
        NSString* sourcePath = [dir stringByAppendingPathComponent:@"fixture.pdf"];
        NSString* outputPath = [dir stringByAppendingPathComponent:@"fixture_english.pdf"];
        NSString* plainCopyPath = [dir stringByAppendingPathComponent:@"fixture_plain.pdf"];
        [build_fixture_pdf() writeToFile:sourcePath atomically:YES];

        char err[1024] = {0};
        spdf_document* doc = spdf_open(sourcePath.fileSystemRepresentation, err, sizeof(err));
        EXPECT(doc != NULL, "open fixture: %s", err);
        if (!doc) return 1;
        EXPECT(spdf_page_count(doc) == 3, "fixture page count");

        // Sanity: the fixture parses the way the pipeline expects.
        spdf_outline outline;
        EXPECT(spdf_load_outline(doc, &outline, err, sizeof(err)), "load fixture outline: %s", err);
        EXPECT(outline.count == 4, "fixture outline count %d", outline.count);
        spdf_comments comments;
        EXPECT(spdf_load_comments(doc, &comments, err, sizeof(err)), "load fixture comments: %s", err);
        EXPECT(comments.count == 4, "fixture comment count %d", comments.count);
        NSString* fixturePage1 = page_text(doc, 0);
        EXPECT([fixturePage1 rangeOfString:[NSString stringWithUTF8String:kHanBlock1]].location != NSNotFound,
               "fixture page 1 contains Han block");

        // The same decision the Mac pipeline makes per item (source zh, target en).
        spdf_translation_script source_script = spdf_translation_script_for_language("zh");
        spdf_translation_script target_script = spdf_translation_script_for_language("en");

        // Body blocks: stub-translate every line that passes the decision.
        NSMutableArray<NSString*>* bodyTexts = [NSMutableArray array];
        std::vector<spdf_translated_line> lines;
        for (int page = 0; page < spdf_page_count(doc); ++page) {
            spdf_text_lines pageLines;
            memset(&pageLines, 0, sizeof(pageLines));
            EXPECT(spdf_extract_page_text_lines(doc, page, &pageLines, err, sizeof(err)), "extract page %d: %s", page,
                   err);
            for (int i = 0; i < pageLines.count; ++i) {
                if (!spdf_translation_should_translate(pageLines.items[i].text, source_script, target_script)) continue;
                NSString* stub = [NSString stringWithFormat:@"EN-BODY-P%d", page + 1];
                [bodyTexts addObject:stub];
                spdf_translated_line line;
                memset(&line, 0, sizeof(line));
                line.page_index = page;
                line.bounds = pageLines.items[i].bounds;
                line.font_size = pageLines.items[i].font_size;
                line.opaque_background = SPDF_TRANSLATION_BACKGROUND_OPAQUE;
                line.text = bodyTexts.lastObject.UTF8String;
                lines.push_back(line);
            }
            spdf_free_text_lines(&pageLines);
        }
        EXPECT(lines.size() == 2, "exactly the two Han body blocks are translated, got %zu", lines.size());

        // Outline titles: expect Han items 0..2 translated, Latin item 3 untouched.
        NSMutableArray<NSString*>* outlineTexts = [NSMutableArray array];
        std::vector<spdf_translated_text> outlineUpdates;
        for (int i = 0; i < outline.count; ++i) {
            if (!spdf_translation_should_translate(outline.items[i].title, source_script, target_script)) continue;
            [outlineTexts addObject:[NSString stringWithFormat:@"EN-OUT-%d", i]];
            spdf_translated_text update;
            update.index = i;
            update.text = outlineTexts.lastObject.UTF8String;
            outlineUpdates.push_back(update);
        }
        EXPECT(outlineUpdates.size() == 3, "three Han outline titles are translated, got %zu", outlineUpdates.size());

        // Comments: expect Han comments 0 and 2 translated, Latin comment 1 untouched.
        NSMutableArray<NSString*>* commentTexts = [NSMutableArray array];
        std::vector<spdf_translated_text> commentUpdates;
        for (int i = 0; i < comments.count; ++i) {
            if (!spdf_translation_should_translate(comments.items[i].text, source_script, target_script)) continue;
            [commentTexts addObject:[NSString stringWithFormat:@"EN-COM-%d", comments.items[i].index]];
            spdf_translated_text update;
            update.index = comments.items[i].index;
            update.text = commentTexts.lastObject.UTF8String;
            commentUpdates.push_back(update);
        }
        EXPECT(commentUpdates.size() == 3, "three Han comments are translated, got %zu", commentUpdates.size());

        EXPECT(spdf_save_translated_copy_full(doc, outputPath.fileSystemRepresentation, lines.data(), (int)lines.size(),
                                              outlineUpdates.data(), (int)outlineUpdates.size(), commentUpdates.data(),
                                              (int)commentUpdates.size(), err, sizeof(err)),
               "save translated copy: %s", err);

        // The legacy entry point (no metadata updates) must also preserve the
        // outline and annotations now -- the original disappearing-chapters bug.
        EXPECT(spdf_save_translated_copy(doc, plainCopyPath.fileSystemRepresentation, lines.data(), (int)lines.size(),
                                         err, sizeof(err)),
               "save plain translated copy: %s", err);

        // --- Verify the translated output ---
        spdf_document* out = spdf_open(outputPath.fileSystemRepresentation, err, sizeof(err));
        EXPECT(out != NULL, "open translated output: %s", err);
        if (out) {
            EXPECT(spdf_page_count(out) == 3, "output page count");

            spdf_outline outOutline;
            EXPECT(spdf_load_outline(out, &outOutline, err, sizeof(err)), "load output outline: %s", err);
            EXPECT(outOutline.count == 4, "output outline keeps all %d entries, got %d", outline.count,
                   outOutline.count);
            if (outOutline.count == 4) {
                const char* expectedTitles[4] = {"EN-OUT-0", "EN-OUT-1", "EN-OUT-2", "Appendix"};
                for (int i = 0; i < 4; ++i) {
                    EXPECT(strcmp(outOutline.items[i].title, expectedTitles[i]) == 0,
                           "output outline title %d is '%s', expected '%s'", i, outOutline.items[i].title,
                           expectedTitles[i]);
                    EXPECT(outOutline.items[i].level == outline.items[i].level, "output outline level %d preserved", i);
                    EXPECT(outOutline.items[i].page_index == outline.items[i].page_index,
                           "output outline destination page %d preserved (%d vs %d)", i,
                           outOutline.items[i].page_index, outline.items[i].page_index);
                    EXPECT(outOutline.items[i].has_dest == outline.items[i].has_dest &&
                               outOutline.items[i].dest_x == outline.items[i].dest_x &&
                               outOutline.items[i].dest_y == outline.items[i].dest_y,
                           "output outline destination point %d preserved", i);
                }
            }
            spdf_free_outline(&outOutline);

            // Expansion state: item A was written collapsed (/Count -1) and must stay so.
            NSData* outputBytes = [NSData dataWithContentsOfFile:outputPath];
            NSData* collapsedMarker = [@"/Count -1" dataUsingEncoding:NSASCIIStringEncoding];
            EXPECT([outputBytes rangeOfData:collapsedMarker options:0 range:NSMakeRange(0, outputBytes.length)]
                           .location != NSNotFound,
                   "output keeps the collapsed /Count -1 outline state");

            spdf_comments outComments;
            EXPECT(spdf_load_comments(out, &outComments, err, sizeof(err)), "load output comments: %s", err);
            EXPECT(outComments.count == 4, "output keeps all 4 comments, got %d", outComments.count);
            if (outComments.count == 4) {
                const char* expectedTexts[4] = {"EN-COM-0", "Looks good", "EN-COM-2", "EN-COM-3"};
                const char* expectedTypes[4] = {"Text", "Text", "Highlight", "FreeText"};
                int expectedPages[4] = {0, 1, 1, 2};
                for (int i = 0; i < 4; ++i) {
                    EXPECT(strcmp(outComments.items[i].text, expectedTexts[i]) == 0,
                           "output comment %d text is '%s', expected '%s'", i, outComments.items[i].text,
                           expectedTexts[i]);
                    EXPECT(strcmp(outComments.items[i].type, expectedTypes[i]) == 0, "output comment %d type preserved",
                           i);
                    EXPECT(outComments.items[i].page_index == expectedPages[i], "output comment %d page preserved", i);
                    EXPECT(strcmp(outComments.items[i].author, i == 1 ? "Bob" : "Zhang") == 0,
                           "output comment %d author preserved", i);
                }
            }
            spdf_free_comments(&outComments);

            // Body overlays: translated text drawn on pages 1-2, Latin/digit
            // blocks untouched, no overlay on page 3; the original Han text
            // stays under the semi-transparent overlay.
            NSString* outPage1 = page_text(out, 0);
            EXPECT([outPage1 rangeOfString:@"EN-BODY-P1"].location != NSNotFound, "page 1 overlay text present");
            EXPECT([outPage1 rangeOfString:@"Hardware Design Manual"].location != NSNotFound,
                   "page 1 Latin heading untouched");
            EXPECT([outPage1 rangeOfString:@"3.3 100 42"].location != NSNotFound, "page 1 digits block untouched");
            EXPECT([outPage1 rangeOfString:[NSString stringWithUTF8String:kHanBlock1]].location != NSNotFound,
                   "page 1 original Han text remains under the overlay");
            NSString* outPage2 = page_text(out, 1);
            EXPECT([outPage2 rangeOfString:@"EN-BODY-P2"].location != NSNotFound, "page 2 overlay text present");
            EXPECT([outPage2 rangeOfString:@"Purely Latin caption"].location != NSNotFound,
                   "page 2 Latin caption untouched");
            NSString* outPage3 = page_text(out, 2);
            EXPECT([outPage3 rangeOfString:@"EN-BODY"].location == NSNotFound, "page 3 has no overlay");
            EXPECT([outPage3 rangeOfString:@"Appendix content only"].location != NSNotFound, "page 3 text untouched");
            // The FreeText comment draws its contents on the page: its
            // appearance must be regenerated with the translated text.
            NSString* outAp = freetext_appearance_stream(outputPath, 2);
            EXPECT(outAp != nil, "output FreeText appearance stream readable");
            EXPECT(outAp && [outAp rangeOfString:@"EN-COM-3"].location != NSNotFound,
                   "output FreeText appearance shows the translated text");
            EXPECT(outAp && [outAp rangeOfString:@"STALE-AP-TEXT"].location == NSNotFound,
                   "output FreeText stale appearance is gone");

            // The link annotation survives with its URI (fz link rects are in
            // y-down page space: PDF y 640..652 -> 792-652=140..152).
            spdf_link_target link;
            int hit = spdf_link_at_point(out, 1, 100.0f, 146.0f, &link, 0, err, sizeof(err));
            EXPECT(hit == 1, "output link annotation hit, got %d (%s)", hit, err);
            EXPECT(hit == 1 && link.kind == SPDF_LINK_URI && link.uri &&
                       strcmp(link.uri, "https://example.com/") == 0,
                   "output link URI preserved");
            if (hit == 1) spdf_free_link_target(&link);

            // The cursor-region cache builder sees the same link: one rect on
            // page 2 (the annotation; the fixture has no plain-text URLs), in
            // the same y-down page space as the at-point test.
            spdf_rect linkRects[8];
            int linkRectCount = spdf_page_link_rects(out, 1, /*detect_text_links=*/1, linkRects, 8, err, sizeof(err));
            EXPECT(linkRectCount == 1, "page 2 link rect collected, got %d (%s)", linkRectCount, err);
            if (linkRectCount == 1) {
                EXPECT(linkRects[0].x0 >= 71.0f && linkRects[0].x1 <= 201.0f && linkRects[0].y0 >= 139.0f &&
                           linkRects[0].y1 <= 153.0f,
                       "link rect matches the annotation bounds, got (%.1f %.1f %.1f %.1f)", linkRects[0].x0,
                       linkRects[0].y0, linkRects[0].x1, linkRects[0].y1);
            }
            int page3LinkCount = spdf_page_link_rects(out, 2, /*detect_text_links=*/1, linkRects, 8, err, sizeof(err));
            EXPECT(page3LinkCount == 0, "page 3 has no links, got %d (%s)", page3LinkCount, err);

            spdf_close(out);
        }

        // --- Verify the legacy no-metadata copy: everything preserved untranslated ---
        spdf_document* plain = spdf_open(plainCopyPath.fileSystemRepresentation, err, sizeof(err));
        EXPECT(plain != NULL, "open plain copy: %s", err);
        if (plain) {
            spdf_outline plainOutline;
            EXPECT(spdf_load_outline(plain, &plainOutline, err, sizeof(err)), "load plain outline: %s", err);
            EXPECT(plainOutline.count == 4, "plain copy keeps the outline (%d entries), got %d", outline.count,
                   plainOutline.count);
            if (plainOutline.count == 4) {
                EXPECT(strcmp(plainOutline.items[0].title, kHanBlock2) == 0, "plain outline title 0 untranslated");
                EXPECT(strcmp(plainOutline.items[1].title, kHanOutline2) == 0, "plain outline title 1 untranslated");
                EXPECT(strcmp(plainOutline.items[2].title, kHanOutline3) == 0, "plain outline title 2 untranslated");
                EXPECT(strcmp(plainOutline.items[3].title, "Appendix") == 0, "plain outline title 3 untranslated");
            }
            spdf_free_outline(&plainOutline);

            spdf_comments plainComments;
            EXPECT(spdf_load_comments(plain, &plainComments, err, sizeof(err)), "load plain comments: %s", err);
            EXPECT(plainComments.count == 4, "plain copy keeps all comments, got %d", plainComments.count);
            if (plainComments.count == 4) {
                EXPECT(strcmp(plainComments.items[0].text, kHanComment1) == 0, "plain comment 0 untranslated");
                EXPECT(strcmp(plainComments.items[1].text, "Looks good") == 0, "plain comment 1 untranslated");
                EXPECT(strcmp(plainComments.items[2].text, kHanComment2) == 0, "plain comment 2 untranslated");
                EXPECT(strcmp(plainComments.items[3].text, kHanComment1) == 0, "plain comment 3 untranslated");
            }
            NSString* plainAp = freetext_appearance_stream(plainCopyPath, 2);
            EXPECT(plainAp && [plainAp rangeOfString:@"STALE-AP-TEXT"].location != NSNotFound,
                   "plain copy keeps the untouched FreeText appearance");
            spdf_free_comments(&plainComments);
            spdf_close(plain);
        }

        spdf_free_outline(&outline);
        spdf_free_comments(&comments);
        spdf_close(doc);
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFTranslationCopyTests passed\n");
    return 0;
}
