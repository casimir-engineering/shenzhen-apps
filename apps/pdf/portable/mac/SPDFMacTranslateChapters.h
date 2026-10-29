#pragma once
#import <Foundation/Foundation.h>
#include "shenzhen_pdf_core.h"
#include <vector>
// Chapters a translated PDF keeps when the PDF being translated has none of its own: the chapters ShenzhenPDF shows for
// the original (generated ones for a PDF without an outline, an EPUB's table of contents, a Markdown document's
// headings), written into the translation as its outline with their titles translated (spdf_pdf_add_outline).
// A chapter: @{@"title", @"page" (from 0), @"level" (from 0)} and, when it has a point on its page, @"x" and @"y" as
// spdf_load_outline gives them.

// The document's own outline as chapters; empty when it has none.
static inline NSArray<NSDictionary*>* SPDFMacTranslateChaptersFromOutline(spdf_document* doc) {
    NSMutableArray* chapters=[NSMutableArray array];
    spdf_outline outline={}; char detail[512]={};
    if (!doc || !spdf_load_outline(doc,&outline,detail,sizeof(detail))) return chapters;
    for (int i=0;i<outline.count;i++) {
        spdf_outline_item item=outline.items[i];
        NSMutableDictionary* chapter=[@{@"title":item.title ? @(item.title) ?: @"" : @"",@"page":@(item.page_index),
            @"level":@(MAX(0,item.level))} mutableCopy];
        if (item.has_dest) { chapter[@"x"]=@(item.dest_x); chapter[@"y"]=@(item.dest_y); }
        [chapters addObject:chapter];
    }
    spdf_free_outline(&outline);
    return chapters;
}
// The chapters the assistant generated for a document without an outline ({title, page from 1, level}).
static inline NSArray<NSDictionary*>* SPDFMacTranslateChaptersFromAnalysis(NSArray* generated) {
    NSMutableArray* chapters=[NSMutableArray array];
    for (NSDictionary* chapter in [generated isKindOfClass:NSArray.class] ? generated : @[]) {
        if (![chapter isKindOfClass:NSDictionary.class] || ![chapter[@"title"] isKindOfClass:NSString.class]) continue;
        NSInteger page=[chapter[@"page"] integerValue]-1;
        if (page<0) continue;
        [chapters addObject:@{@"title":chapter[@"title"],@"page":@(page),@"level":@(MAX(0,[chapter[@"level"] integerValue]))}];
    }
    return chapters;
}
// Writes `chapters` as the outline of the PDF at `path`, with `titles` (one per chapter, the translations) when given.
static inline BOOL SPDFMacTranslateWriteChapters(NSString* path, NSArray<NSDictionary*>* chapters, NSArray<NSString*>* titles,
                                                 NSString** failure) {
    if (!chapters.count) return YES;
    std::vector<spdf_outline_item> items(chapters.count);
    NSMutableArray* kept=[NSMutableArray array];  // keeps each title's UTF-8 alive until the core returns
    for (NSUInteger i=0;i<chapters.count;i++) {
        NSDictionary* chapter=chapters[i];
        NSString* title=i<titles.count && titles[i].length ? titles[i] : chapter[@"title"];
        title=[[title componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
        [kept addObject:title];
        items[i].title=(char*)title.UTF8String;
        items[i].page_index=[chapter[@"page"] intValue];
        items[i].level=[chapter[@"level"] intValue];
        items[i].has_dest=chapter[@"y"]!=nil;
        items[i].dest_x=[chapter[@"x"] floatValue];
        items[i].dest_y=[chapter[@"y"] floatValue];
    }
    char detail[1024]={};
    BOOL ok=spdf_pdf_add_outline(path.fileSystemRepresentation,items.data(),(int)items.size(),detail,sizeof(detail));
    if (!ok && failure) *failure=detail[0] ? @(detail) : @"The chapters could not be written.";
    return ok;
}
