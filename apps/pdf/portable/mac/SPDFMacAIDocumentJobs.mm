#import "SPDFMacAIDocumentJobs.h"
#import "SPDFMacOCRCommand.h"
#import "SPDFMacOCRValidation.h"
#import "SPDFMacAIOutputFiles.h"
#include "shenzhen_pdf_core.h"
#include <vector>

static id Fail(NSError** error, NSString* message) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.AI.Job" code:1
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Document operation failed."}];
    return nil;
}
BOOL SPDFAIJobReceiptIsCurrent(NSDictionary* receipt) { return SPDFMacAIOutputIsCurrent(receipt); }
BOOL SPDFAIRemoveJobOutput(NSDictionary* receipt) { return SPDFMacAIOutputRemove(receipt); }
static NSString* OneLine(NSString* text) {
    NSArray* words=[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}
static NSArray<NSString*>* TranslationLines(NSString* output) {
    NSMutableArray<NSString*>* kept=[NSMutableArray array]; BOOL previousDiagnostic=NO;
    for (NSString* line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString* trimmed=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        // Argos emits package-version warnings on stdout; the native command
        // recognizes these same two forms before mapping translated geometry.
        BOOL diagnostic=([trimmed containsString:@"WARNING: Language "] &&
            [trimmed containsString:@" package "] && [trimmed containsString:@" expects "]) ||
            (previousDiagnostic && ([trimmed isEqual:@"added"] || [trimmed hasPrefix:@"which has been added"]));
        previousDiagnostic=diagnostic; if (!diagnostic) [kept addObject:line];
    }
    while (kept.count && ![kept.lastObject length]) [kept removeLastObject];
    return kept;
}
static BOOL Translate(spdf_document* doc, NSString* output, NSString* executable, NSDictionary* environment,
    NSDictionary* options, NSString* scratch, NSProgress* progress, NSError** error) {
    NSString* source=options[@"sourceLanguage"], *target=options[@"targetLanguage"];
    spdf_translation_script from=spdf_translation_script_for_language(source.UTF8String);
    spdf_translation_script to=spdf_translation_script_for_language(target.UTF8String);
    NSMutableArray<NSDictionary*>* items=[NSMutableArray array]; char detail[1024]={};
    for (int page=0;page<spdf_page_count(doc);page++) {
        if (progress.cancelled) { Fail(error,@"Cancelled."); return NO; }
        spdf_text_lines lines={};
        if (!spdf_extract_page_text_lines(doc,page,&lines,detail,sizeof(detail))) { Fail(error,@(detail)); return NO; }
        for (int i=0;i<lines.count;i++) {
            NSString* text=OneLine(lines.items[i].text ? @(lines.items[i].text) : @"");
            if (!text.length || !spdf_translation_should_translate(text.UTF8String,from,to)) continue;
            spdf_rect r=lines.items[i].bounds;
            [items addObject:@{@"page":@(page),@"text":text,@"font":@(lines.items[i].font_size),
                @"bounds":[NSValue valueWithRect:NSMakeRect(r.x0,r.y0,r.x1-r.x0,r.y1-r.y0)]}];
        }
        spdf_free_text_lines(&lines);
    }
    spdf_outline outline={};
    if (spdf_load_outline(doc,&outline,detail,sizeof(detail))) {
        for (int i=0;i<outline.count;i++) {
            NSString* text=OneLine(outline.items[i].title ? @(outline.items[i].title) : @"");
            if (text.length && spdf_translation_should_translate(text.UTF8String,from,to))
                [items addObject:@{@"kind":@"outline",@"index":@(i),@"page":@(-1),@"text":text}];
        }
        spdf_free_outline(&outline);
    }
    spdf_comments comments={};
    if (spdf_load_comments(doc,&comments,detail,sizeof(detail))) {
        for (int i=0;i<comments.count;i++) {
            NSString* text=OneLine(comments.items[i].text ? @(comments.items[i].text) : @"");
            if (text.length && spdf_translation_should_translate(text.UTF8String,from,to))
                [items addObject:@{@"kind":@"comment",@"index":@(comments.items[i].index),@"page":@(-2),@"text":text}];
        }
        spdf_free_comments(&comments);
    }
    if (!items.count) { Fail(error,@"No translatable text was found. Run OCR first for scanned documents."); return NO; }
    progress.totalUnitCount=(int64_t)items.count;
    NSMutableArray<NSString*>* translated=[NSMutableArray array];
    for (NSUInteger start=0;start<items.count;) {
        NSUInteger end=start+1;
        while (end<items.count && end-start<100 && [items[end][@"page"] isEqual:items[start][@"page"]]) end++;
        NSMutableArray* texts=[NSMutableArray array];
        for (NSUInteger i=start;i<end;i++) [texts addObject:items[i][@"text"]];
        NSString* result=SPDFAIRunLocalTool(executable,@[@"--from-lang",source,@"--to-lang",target],environment,
            [[texts componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"],scratch,progress,error);
        if (!result) return NO;
        NSArray* lines=TranslationLines(result);
        // Guessing a shifted line mapping silently translates the wrong geometry.
        if (lines.count!=end-start) { Fail(error,@"Translation returned a different number of text lines; output was not installed."); return NO; }
        for (NSString* line in lines) {
            if (!OneLine(line).length) { Fail(error,@"Translation returned an empty text line."); return NO; }
            [translated addObject:line];
        }
        progress.completedUnitCount=(int64_t)end; start=end;
    }
    std::vector<spdf_translated_line> lines;
    std::vector<spdf_translated_text> titles, notes;
    for (NSUInteger i=0;i<items.count;i++) {
        NSDictionary* item=items[i]; const char* text=translated[i].UTF8String;
        if ([item[@"kind"] isEqual:@"outline"]) titles.push_back({[item[@"index"] intValue],text});
        else if ([item[@"kind"] isEqual:@"comment"]) notes.push_back({[item[@"index"] intValue],text});
        else {
            NSRect r=[item[@"bounds"] rectValue];
            lines.push_back({[item[@"page"] intValue],{(float)NSMinX(r),(float)NSMinY(r),(float)NSMaxX(r),(float)NSMaxY(r)},
                text,[item[@"font"] floatValue],SPDF_TRANSLATION_BACKGROUND_OPAQUE});
        }
    }
    if (progress.cancelled) { Fail(error,@"Cancelled."); return NO; }
    BOOL ok=spdf_save_translated_copy_full(doc,output.fileSystemRepresentation,lines.data(),(int)lines.size(),
        titles.data(),(int)titles.size(),notes.data(),(int)notes.size(),detail,sizeof(detail));
    if (!ok) Fail(error,@(detail));
    return ok;
}
NSDictionary* SPDFAIRunPDFJob(NSString* kind, NSString* source, NSString* directory, NSString* name,
    NSString* executable, NSDictionary* environment, NSDictionary* options, NSProgress* progress, NSError** error) {
    if (progress.cancelled) return Fail(error,@"Cancelled.");
    if (![@[@"ocr",@"translate",@"export-pdf"] containsObject:kind]) return Fail(error,@"Unknown document job.");
    NSFileManager* fm=NSFileManager.defaultManager;
    // Private, outside the destination: a long OCR run leaves nothing half-made in the person's Downloads.
    NSString* scratch=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ShenzhenPDF-job-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700}
        error:error]) return nil;
    NSString* input=[scratch stringByAppendingPathComponent:@"input.pdf"];
    NSString* output=[scratch stringByAppendingPathComponent:@"output.pdf"];
    NSDictionary* receipt=nil;
    @try {
        if (![fm copyItemAtPath:source toPath:input error:error]) return nil;
        char detail[1024]={}; spdf_document* doc=spdf_open(input.fileSystemRepresentation,detail,sizeof(detail));
        if (!doc) return Fail(error,@(detail));
        BOOL ok=NO; int pages=spdf_page_count(doc);
        if (spdf_is_password_protected(doc)) { spdf_close(doc); return Fail(error,@"Create an unprotected copy before exporting, OCR or translation."); }
        if ([kind isEqual:@"ocr"]) {
            int hasText=spdf_document_has_text(doc,0,detail,sizeof(detail));
            BOOL imageBacked=spdf_mac_ocr_document_is_image_backed(doc);
            spdf_close(doc); doc=NULL;
            if (hasText<0) return Fail(error,@(detail));
            NSArray* args=spdf_mac_ocr_arguments(options[@"language"] ?: @"eng",input,output,
                MAX(1,NSProcessInfo.processInfo.activeProcessorCount),hasText>0 && !imageBacked,YES);
            ok=SPDFAIRunLocalTool(executable,args,environment,nil,scratch,progress,error)!=nil;
        } else if ([kind isEqual:@"translate"]) {
            ok=Translate(doc,output,executable,environment,options,scratch,progress,error); spdf_close(doc); doc=NULL;
        } else {
            spdf_close(doc); doc=NULL; ok=[fm copyItemAtPath:input toPath:output error:error];
        }
        if (!ok || progress.cancelled) return progress.cancelled ? Fail(error,@"Cancelled.") : nil;
        spdf_document* verified=spdf_open(output.fileSystemRepresentation,detail,sizeof(detail));
        if (!verified) return Fail(error,@"The tool did not produce a readable PDF.");
        BOOL valid=spdf_page_count(verified)==pages && pages>0;
        if ([kind isEqual:@"ocr"]) valid=valid && spdf_document_has_text(verified,0,detail,sizeof(detail))>0;
        spdf_close(verified);
        if (!valid) return Fail(error,@"Output validation failed: page count changed or OCR produced no text.");
        if (progress.cancelled) return Fail(error,@"Cancelled.");
        // Exclusive rename under the first free name: never replaces a file already there.
        receipt=SPDFMacAIOutputInstallFile(output,directory,name,error);
        if (!receipt) return nil;
        if (progress.cancelled) { SPDFAIRemoveJobOutput(receipt); return Fail(error,@"Cancelled."); }
        return receipt;
    } @finally { [fm removeItemAtPath:scratch error:nil]; }
}
