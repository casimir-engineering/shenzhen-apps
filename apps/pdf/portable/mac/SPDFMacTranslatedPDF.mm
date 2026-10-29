#import "SPDFMacTranslatedPDF.h"

#import "SPDFMacAIIntegration.h"
#import "SPDFMacTranslateChapters.h"

// Moved from ShenzhenPDFMac.mm as they were.

NSString* SPDFTextByCollapsingWhitespace(NSString* text) {
    NSString* trimmed = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return @"";
    return [trimmed stringByReplacingOccurrencesOfString:@"[\\s\\u00a0]+"
                                              withString:@" "
                                                 options:NSRegularExpressionSearch
                                                   range:NSMakeRange(0, trimmed.length)];
}

@implementation ShenzhenMacDelegate (SPDFMacTranslatedPDF)

// Whole-document translation: per-item translate/skip decision shared with
// the core (script of the item's text vs. the selected languages; a Chinese
// or Latin-script source takes precedence, otherwise the target decides).
// Skipped blocks are left completely untouched -- not sent to Argos and no
// overlay drawn. Rebuilds _pendingTranslationItems in lockstep and returns
// the filtered source text (empty when nothing passes).
- (NSString*)sourceTextByKeepingTranslatableLines:(NSString*)sourceText
                                     sourceScript:(spdf_translation_script)sourceScript
                                     targetScript:(spdf_translation_script)targetScript {
    NSArray<NSString*>* sourceLines =
        [sourceText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSArray<NSDictionary*>* items = _pendingTranslationItems ?: @[];
    NSMutableArray<NSDictionary*>* keptItems = [NSMutableArray arrayWithCapacity:items.count];
    NSMutableString* keptText = [NSMutableString string];
    for (NSUInteger i = 0; i < items.count; ++i) {
        NSString* line = i < sourceLines.count ? sourceLines[i] : @"";
        if (!spdf_translation_should_translate(line.UTF8String, sourceScript, targetScript)) continue;
        [keptItems addObject:items[i]];
        [keptText appendString:line];
        [keptText appendString:@"\n"];
    }
    _pendingTranslationItems = keptItems;
    return keptText;
}

// Chapter (outline) titles and comment texts join the same batched Argos
// pipeline as body blocks: one source line per item, appended after the body
// lines under the same per-item translate/skip decision. Titles and comment
// texts are collapsed to single lines so the one-line-per-item mapping
// through Argos holds. "index" identifies the entry for the core writer
// (spdf_load_outline pre-order index / visible comment index); "page" only
// groups the items into spawn batches after the last body page.
- (NSString*)sourceTextByAppendingOutlineAndCommentItems:(NSString*)sourceText
                                            sourceScript:(spdf_translation_script)sourceScript
                                            targetScript:(spdf_translation_script)targetScript {
    if (!_doc) return sourceText;
    NSMutableArray<NSDictionary*>* items = [_pendingTranslationItems mutableCopy] ?: [NSMutableArray array];
    NSMutableString* text = [sourceText mutableCopy] ?: [NSMutableString string];
    int pageCount = spdf_page_count(_doc);
    char err[512];

    spdf_outline outline;
    memset(&outline, 0, sizeof(outline));
    BOOL authoredOutline = NO;
    if (spdf_load_outline(_doc, &outline, err, sizeof(err))) {
        authoredOutline = outline.count > 0;
        for (int i = 0; i < outline.count; ++i) {
            NSString* title = outline.items[i].title ? [NSString stringWithUTF8String:outline.items[i].title] : nil;
            title = SPDFTextByCollapsingWhitespace(title ?: @"");
            if (title.length == 0) continue;
            if (!spdf_translation_should_translate(title.UTF8String, sourceScript, targetScript)) continue;
            [items addObject:@{@"kind" : @"outline", @"index" : @(i), @"page" : @(pageCount)}];
            [text appendString:title];
            [text appendString:@"\n"];
        }
        spdf_free_outline(&outline);
    }
    // No outline of its own: the chapters generated for it become the translation's outline, their titles
    // translated with the rest (SPDFMacTranslateChapters.h).
    _pendingTranslationChapters =
        authoredOutline ? nil : SPDFMacTranslateChaptersFromAnalysis([self aiAnalysisForPath:_path][@"chapters"]);
    for (NSUInteger i = 0; i < _pendingTranslationChapters.count; ++i) {
        NSString* title = SPDFTextByCollapsingWhitespace(_pendingTranslationChapters[i][@"title"] ?: @"");
        if (title.length == 0) continue;
        if (!spdf_translation_should_translate(title.UTF8String, sourceScript, targetScript)) continue;
        [items addObject:@{@"kind" : @"chapter", @"index" : @(i), @"page" : @(pageCount)}];
        [text appendString:title];
        [text appendString:@"\n"];
    }

    spdf_comments comments;
    memset(&comments, 0, sizeof(comments));
    if (spdf_load_comments(_doc, &comments, err, sizeof(err))) {
        for (int i = 0; i < comments.count; ++i) {
            NSString* body = comments.items[i].text ? [NSString stringWithUTF8String:comments.items[i].text] : nil;
            body = SPDFTextByCollapsingWhitespace(body ?: @"");
            if (body.length == 0) continue;
            if (!spdf_translation_should_translate(body.UTF8String, sourceScript, targetScript)) continue;
            [items
                addObject:@{@"kind" : @"comment", @"index" : @(comments.items[i].index), @"page" : @(pageCount + 1)}];
            [text appendString:body];
            [text appendString:@"\n"];
        }
        spdf_free_comments(&comments);
    }

    _pendingTranslationItems = items;
    return text;
}

- (BOOL)writeTranslatedPDFWithText:(NSString*)text
                        sourcePath:(NSString*)sourcePath
                        outputPath:(NSString*)outputPath
                             error:(NSError**)errorOut {
    (void)sourcePath;
    if (text.length == 0 || outputPath.length == 0 || _pendingTranslationItems.count == 0) return NO;

    NSArray<NSString*>* outputLines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString*>* mappedText = [NSMutableArray arrayWithCapacity:_pendingTranslationItems.count];
    if (_pendingTranslationItems.count == 1) {
        [mappedText addObject:text];
    } else {
        for (NSUInteger i = 0; i < _pendingTranslationItems.count; ++i) {
            NSString* translated = i < outputLines.count ? outputLines[i] : @"";
            [mappedText addObject:translated.length ? translated : @" "];
        }
        if (outputLines.count > _pendingTranslationItems.count && mappedText.count > 0) {
            NSMutableString* tail = [mappedText.lastObject mutableCopy];
            for (NSUInteger i = _pendingTranslationItems.count; i < outputLines.count; ++i) {
                NSString* extra = outputLines[i];
                if (extra.length == 0) continue;
                if (tail.length > 0) [tail appendString:@"\n"];
                [tail appendString:extra];
            }
            mappedText[mappedText.count - 1] = tail;
        }
    }

    NSUInteger count = MIN(_pendingTranslationItems.count, mappedText.count);
    spdf_translated_line* lines = (spdf_translated_line*)calloc(count ? count : 1, sizeof(spdf_translated_line));
    spdf_translated_text* outlineTitles =
        (spdf_translated_text*)calloc(count ? count : 1, sizeof(spdf_translated_text));
    spdf_translated_text* commentTexts = (spdf_translated_text*)calloc(count ? count : 1, sizeof(spdf_translated_text));
    if (!lines || !outlineTitles || !commentTexts) {
        free(lines);
        free(outlineTitles);
        free(commentTexts);
        return NO;
    }
    // Keeps the collapsed/trimmed strings (and their UTF8String buffers)
    // alive until the core call below returns.
    NSMutableArray<NSString*>* retainedTexts = [NSMutableArray arrayWithCapacity:count];
    NSUInteger lineCount = 0;
    NSUInteger outlineCount = 0;
    NSUInteger commentCount = 0;
    NSMutableArray<NSString*>* chapterTitles = [NSMutableArray array];
    for (NSUInteger i = 0; i < _pendingTranslationChapters.count; ++i) [chapterTitles addObject:@""];
    for (NSUInteger i = 0; i < count; ++i) {
        NSDictionary* item = _pendingTranslationItems[i];
        NSString* kind = item[@"kind"];
        if ([kind isEqualToString:@"chapter"]) {
            NSUInteger index = [item[@"index"] unsignedIntegerValue];
            if (index < chapterTitles.count) chapterTitles[index] = SPDFTextByCollapsingWhitespace(mappedText[i]);
        } else if ([kind isEqualToString:@"outline"]) {
            // Titles must stay single-line; keep the original when Argos
            // produced nothing for this line.
            NSString* title = SPDFTextByCollapsingWhitespace(mappedText[i]);
            if (title.length == 0) continue;
            [retainedTexts addObject:title];
            outlineTitles[outlineCount].index = [item[@"index"] intValue];
            outlineTitles[outlineCount].text = title.UTF8String;
            outlineCount++;
        } else if ([kind isEqualToString:@"comment"]) {
            NSString* body =
                [mappedText[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (body.length == 0) continue;
            [retainedTexts addObject:body];
            commentTexts[commentCount].index = [item[@"index"] intValue];
            commentTexts[commentCount].text = body.UTF8String;
            commentCount++;
        } else {
            NSRect rect = [item[@"rect"] rectValue];
            lines[lineCount].page_index = [item[@"page"] intValue];
            lines[lineCount].bounds.x0 = (float)NSMinX(rect);
            lines[lineCount].bounds.y0 = (float)NSMinY(rect);
            lines[lineCount].bounds.x1 = (float)NSMaxX(rect);
            lines[lineCount].bounds.y1 = (float)NSMaxY(rect);
            lines[lineCount].font_size = [item[@"font"] floatValue];
            lines[lineCount].opaque_background = SPDF_TRANSLATION_BACKGROUND_OPAQUE;
            lines[lineCount].text = mappedText[i].UTF8String;
            lineCount++;
        }
    }

    char err[1024];
    BOOL ok =
        spdf_save_translated_copy_full(_doc, outputPath.fileSystemRepresentation, lines, (int)lineCount, outlineTitles,
                                       (int)outlineCount, commentTexts, (int)commentCount, err, sizeof(err));
    (void)retainedTexts;
    free(lines);
    free(outlineTitles);
    free(commentTexts);
    NSString* chapterFailure = nil;
    if (ok && !SPDFMacTranslateWriteChapters(outputPath, _pendingTranslationChapters, chapterTitles, &chapterFailure)) {
        ok = NO;
        snprintf(err, sizeof(err), "%s", chapterFailure.UTF8String ?: "The chapters could not be written.");
    }
    if (!ok && errorOut) {
        NSString* detail = [NSString stringWithUTF8String:err[0] ? err : "Could not save translated PDF."];
        *errorOut =
            [NSError errorWithDomain:@"ShenzhenPDFTranslation"
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey : detail ?: @"Could not save translated PDF."}];
    }
    return ok;
}

@end
