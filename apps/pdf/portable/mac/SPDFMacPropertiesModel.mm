#import "SPDFMacPropertiesModel.h"
#import "SPDFMacPropertiesFormat.h"
#import "SPDFMacAILanguage.h"
#import "SPDFMacImageProperties.h"

static NSString* spdf_properties_metadata(spdf_document* doc, const char* key) {
    if (!doc) return @"";
    char buffer[4096];
    if (!spdf_lookup_metadata(doc, key, buffer, sizeof(buffer))) return @"";
    NSString* value = [NSString stringWithUTF8String:buffer] ?: @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString* spdf_properties_display_date(NSDate* date) {
    if (!date) return @"";
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date] ?: @"";
}

static NSString* spdf_properties_grouped(NSUInteger value) {
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    return [formatter stringFromNumber:@(value)] ?: [NSString stringWithFormat:@"%lu", (unsigned long)value];
}

static NSMutableDictionary* spdf_properties_row(NSString* label, NSString* value) {
    return [NSMutableDictionary dictionaryWithDictionary:@{@"label" : label, @"value" : value}];
}

static void spdf_properties_append_ai(NSMutableArray* sections, NSDictionary* analysis) {
    if([analysis[@"summary"] isKindOfClass:NSString.class]) {
        NSArray* tags=[analysis[@"tags"] isKindOfClass:NSArray.class] ? analysis[@"tags"] : @[];
        [sections addObject:@{@"title":@"AI metadata",@"rows":@[
            spdf_properties_row(@"Tags",tags.count ? [tags componentsJoinedByString:@" · "] : @"None"),
            spdf_properties_row(@"AI language",SPDFMacAILanguageName(analysis[@"language"])),
            spdf_properties_row(@"Summary",analysis[@"summary"]) ]}];
    }
}

NSArray<NSDictionary*>* SPDFPropertiesSections(spdf_document* doc, NSString* sourcePath,
    NSString* inspectionPath, NSInteger pageIndex, NSInteger outlineCount, NSInteger annotationCount,
    NSDictionary* textInfo) {
    NSMutableArray<NSDictionary*>* sections = [NSMutableArray array];
    BOOL raster = SPDFPathIsRasterImage(sourcePath), vector = [@[@"svg",@"svgz"] containsObject:sourcePath.pathExtension.lowercaseString];
    BOOL pdf = [sourcePath.pathExtension.lowercaseString isEqual:@"pdf"];
    BOOL text = textInfo[@"pageCount"] != nil;

    // Document metadata (rows with empty values are omitted).
    NSMutableArray* documentRows = [NSMutableArray array];
    NSDictionary<NSString*, NSString*>* metadataRows = @{
        @"Title" : @"info:Title",
        @"Author" : @"info:Author",
        @"Subject" : @"info:Subject",
        @"Keywords" : @"info:Keywords",
        @"Creator" : @"info:Creator",
        @"Producer" : @"info:Producer",
    };
    for (NSString* label in @[ @"Title", @"Author", @"Subject", @"Keywords", @"Creator", @"Producer" ]) {
        NSString* value = spdf_properties_metadata(doc, metadataRows[label].UTF8String);
        if (value.length) [documentRows addObject:spdf_properties_row(label, value)];
    }
    if (doc && pdf) {
    NSString* encryption = spdf_properties_metadata(doc, "encryption");
    if ([encryption isEqualToString:@"None"]) encryption = @"";
    if (encryption.length && spdf_is_password_protected(doc))
        encryption = [encryption stringByAppendingString:@" (password protected)"];
    NSString* security =
        spdf_properties_security_summary(encryption, spdf_has_permission(doc, 'p'), spdf_has_permission(doc, 'c'),
                                         spdf_has_permission(doc, 'e'), spdf_has_permission(doc, 'n'));
    [documentRows addObject:spdf_properties_row(@"Security", security)];
    }
    if (documentRows.count) [sections addObject:@{@"title" : @"Document", @"rows" : documentRows}];

    // Dates: PDF metadata dates first; on-disk dates appear when there is no
    // PDF counterpart or when they differ meaningfully (> 60 s).
    NSDictionary* fileAttributes = sourcePath.length
                                       ? [NSFileManager.defaultManager attributesOfItemAtPath:sourcePath error:nil]
                                       : nil;
    NSMutableArray* dateRows = [NSMutableArray array];
    NSString* rawCreated = spdf_properties_metadata(doc, "info:CreationDate");
    NSString* rawModified = spdf_properties_metadata(doc, "info:ModDate");
    NSDate* pdfCreated = spdf_properties_parse_pdf_date(rawCreated);
    NSDate* pdfModified = spdf_properties_parse_pdf_date(rawModified);
    if (pdfCreated) {
        NSMutableDictionary* row = spdf_properties_row(@"Created", spdf_properties_display_date(pdfCreated));
        row[@"tooltip"] = rawCreated;
        [dateRows addObject:row];
    } else if (rawCreated.length) {
        [dateRows addObject:spdf_properties_row(@"Created", rawCreated)];  // unparseable: show verbatim
    }
    if (pdfModified) {
        NSMutableDictionary* row = spdf_properties_row(@"Modified", spdf_properties_display_date(pdfModified));
        row[@"tooltip"] = rawModified;
        [dateRows addObject:row];
    } else if (rawModified.length) {
        [dateRows addObject:spdf_properties_row(@"Modified", rawModified)];
    }
    NSDate* fileCreated = fileAttributes[NSFileCreationDate];
    NSDate* fileModified = fileAttributes[NSFileModificationDate];
    if (fileCreated && (!pdfCreated || fabs([fileCreated timeIntervalSinceDate:pdfCreated]) > 60.0))
        [dateRows addObject:spdf_properties_row(@"Created (on disk)", spdf_properties_display_date(fileCreated))];
    if (fileModified && (!pdfModified || fabs([fileModified timeIntervalSinceDate:pdfModified]) > 60.0))
        [dateRows addObject:spdf_properties_row(@"Modified (on disk)", spdf_properties_display_date(fileModified))];
    if (dateRows.count) [sections addObject:@{@"title" : @"Dates", @"rows" : dateRows}];

    // File.
    NSMutableArray* fileRows = [NSMutableArray array];
    if (sourcePath.length) {
        NSMutableDictionary* pathRow = spdf_properties_row(@"Location", sourcePath);
        pathRow[@"tooltip"] = sourcePath;
        pathRow[@"fullPath"] = @YES;
        [fileRows addObject:pathRow];
    }
    unsigned long long fileSize = [fileAttributes[NSFileSize] unsignedLongLongValue];
    if (fileAttributes) [fileRows addObject:spdf_properties_row(@"Size", spdf_properties_format_file_size(fileSize))];
    NSString* format = textInfo[@"format"] ?: spdf_properties_metadata(doc, "format");
    if (!format.length) format = sourcePath.pathExtension.uppercaseString;
    if (format.length) [fileRows addObject:spdf_properties_row(@"Format", format)];
    if (!fileAttributes) [fileRows addObject:spdf_properties_row(@"Availability", @"Original file unavailable")];
    if (fileRows.count) [sections addObject:@{@"title" : @"File", @"rows" : fileRows}];

    if (raster) {
        NSArray* rows = SPDFImagePropertyRows(inspectionPath.length ? inspectionPath : sourcePath);
        if (rows.count) [sections addObject:@{@"title":@"Image", @"rows":rows}];
        spdf_properties_append_ai(sections,textInfo[@"aiAnalysis"]);
        return sections; // No PDF permissions, annotations or full-document text scan for pictures.
    }
    NSMutableArray* statsRows = [NSMutableArray array];
    NSInteger pageCount = doc ? spdf_page_count(doc) : [textInfo[@"pageCount"] integerValue];
    if (doc || textInfo[@"pageCount"])
        [statsRows addObject:spdf_properties_row(@"Pages", spdf_properties_grouped(MAX(0,pageCount)))];
    float width = 0, height = 0; char error[256];
    if (doc && pageIndex >= 0 && pageIndex < pageCount)
        spdf_page_size(doc,(int)pageIndex,&width,&height,error,sizeof(error));
    else if (textInfo[@"pageSize"]) {
        NSSize size = [textInfo[@"pageSize"] sizeValue]; width = size.width; height = size.height;
    }
    if (width > 0 && height > 0) [statsRows addObject:spdf_properties_row(vector ? @"Vector page size" : @"Page size",
        spdf_properties_format_page_size_pt(width,height))];
    if (vector) [statsRows addObject:spdf_properties_row(@"Content",@"Vector artwork (resolution-independent)")];
    else {
        if (textInfo[@"language"]) [statsRows addObject:spdf_properties_row(@"Language",textInfo[@"language"])];
        if (doc || text) [statsRows addObject:spdf_properties_row(text ? @"Headings" : @"Table of contents",
            outlineCount > 0 ? spdf_properties_grouped(outlineCount) : @"None")];
        if (doc && pdf) [statsRows addObject:spdf_properties_row(@"Annotations",
            annotationCount > 0 ? spdf_properties_grouped(annotationCount) : @"None")];
        if (doc || textInfo[@"text"]) [statsRows addObject:spdf_properties_row(@"Text",@"Counting…")];
    }
    if (statsRows.count) [sections addObject:@{@"title":@"Statistics",@"rows":statsRows}];
    spdf_properties_append_ai(sections,textInfo[@"aiAnalysis"]);
    return sections;
}
