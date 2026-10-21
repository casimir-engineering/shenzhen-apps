#import "SPDFMacAIWebPDF.h"
#import "SPDFMacAIWebAddress.h"
#include "shenzhen_pdf_core.h"
#include <algorithm>
#include <vector>

// A download older than this is removed when the next PDF is stored: long enough for the chat's link to still open
// it the next days, short enough that datasheets do not pile up.
static const NSTimeInterval kKeptFor = 7 * 24 * 3600;
// Rows are found by comparing lines pairwise; a page with more lines than this (a dense drawing) keeps the engine's
// order rather than spend seconds on it.
static const NSUInteger kMaximumGroupedLines = 3000;

@implementation SPDFMacAIWebDocument
- (instancetype)initWithIdentifier:(NSString*)identifier file:(NSURL*)file source:(NSURL*)source pages:(NSUInteger)pages
                             title:(NSString*)title bytes:(NSUInteger)bytes {
    if (!(self = [super init])) return nil;
    _identifier = [identifier copy];
    _fileURL = file;
    _sourceURL = source;
    _pageCount = pages;
    _title = [title copy];
    _byteCount = bytes;
    return self;
}
@end

NSURL* SPDFMacAIWebDocumentDefaultFolder(void) {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ShenzhenPDF-AI-Web"]
                      isDirectory:YES];
}

static BOOL IsIdentifier(NSString* text) {
    return [text isKindOfClass:NSString.class] && text.length == 36 && [[NSUUID alloc] initWithUUIDString:text];
}

// "BM28B0-6-30DS-2-0-35V-51-643875.pdf" from the address, so the reader's tab is named like the datasheet.
static NSString* FileName(NSURL* source) {
    NSString* last = source.lastPathComponent ?: @"";
    NSMutableString* name = [NSMutableString string];
    NSCharacterSet* kept = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSUInteger index = 0; index < last.length && name.length < 100; index++) {
        unichar c = [last characterAtIndex:index];
        [name appendString:[kept characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"-"];
    }
    while ([name hasPrefix:@"."] || [name hasPrefix:@"-"]) [name deleteCharactersInRange:NSMakeRange(0, 1)];
    if ([name.pathExtension.lowercaseString isEqual:@"pdf"]) name = [[name stringByDeletingPathExtension] mutableCopy];
    return [(name.length ? name : @"document") stringByAppendingString:@".pdf"];
}

static void RemoveOldDownloads(NSURL* folder) {
    NSFileManager* files = NSFileManager.defaultManager;
    NSArray<NSURL*>* entries = [files contentsOfDirectoryAtURL:folder
                                    includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];
    for (NSURL* entry in entries) {
        if (!IsIdentifier(entry.lastPathComponent)) continue; // only folders this file made
        NSDate* changed = nil;
        [entry getResourceValue:&changed forKey:NSURLContentModificationDateKey error:nil];
        if (changed && -changed.timeIntervalSinceNow > kKeptFor) [files removeItemAtURL:entry error:nil];
    }
}

static NSError* DocumentError(SPDFMacAIWebError code, NSString* message) {
    return SPDFMacAIWebMakeError(code, message);
}

SPDFMacAIWebDocument* SPDFMacAIWebStoreDocument(NSData* data, NSURL* sourceURL, NSURL* folder, NSError** error) {
    if (error) *error = nil;
    NSFileManager* files = NSFileManager.defaultManager;
    RemoveOldDownloads(folder);
    NSString* identifier = NSUUID.UUID.UUIDString;
    NSURL* directory = [folder URLByAppendingPathComponent:identifier isDirectory:YES];
    NSURL* file = [directory URLByAppendingPathComponent:FileName(sourceURL)];
    NSError* failure = nil;
    if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions : @0700} error:&failure] ||
        ![data writeToURL:file options:NSDataWritingAtomic error:&failure]) {
        if (error) *error = DocumentError(SPDFMacAIWebErrorBadDocument, @"The PDF could not be saved on this Mac.");
        return nil;
    }
    char message[512] = {0};
    spdf_open_status status = SPDF_OPEN_ERROR;
    spdf_document* doc = spdf_open_with_password(file.fileSystemRepresentation, NULL, &status, NULL, message,
                                                 sizeof(message));
    if (!doc) {
        [files removeItemAtURL:directory error:nil];
        BOOL locked = status == SPDF_OPEN_PASSWORD_REQUIRED || status == SPDF_OPEN_BAD_PASSWORD;
        if (error) *error = locked ?
            DocumentError(SPDFMacAIWebErrorLockedDocument, @"The PDF is locked with a password, so it was not read.") :
            DocumentError(SPDFMacAIWebErrorBadDocument, @"The PDF is damaged or not a PDF the reader can open.");
        return nil;
    }
    NSUInteger pages = (NSUInteger)MAX(0, spdf_page_count(doc));
    char title[512] = {0};
    NSString* own = spdf_lookup_metadata(doc, "info:Title", title, sizeof(title)) ? @(title) : nil;
    spdf_close(doc);
    own = [own stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[SPDFMacAIWebDocument alloc] initWithIdentifier:identifier file:file source:sourceURL pages:pages
                                                      title:own.length ? own : file.lastPathComponent
                                                      bytes:data.length];
}

#pragma mark - Page text

NSString* SPDFMacAIWebPageLinesText(NSArray<NSDictionary*>* lines, double pageWidth) {
    struct Line { NSString* text; double x0, y0, x1, y1; };
    std::vector<Line> all;
    double right = 0;
    for (NSDictionary* line in lines) {
        Line item = {line[@"text"] ?: @"", [line[@"x0"] doubleValue], [line[@"y0"] doubleValue],
                     [line[@"x1"] doubleValue], [line[@"y1"] doubleValue]};
        right = MAX(right, item.x1);
        all.push_back(item);
    }
    double width = pageWidth > 0 ? pageWidth : right;
    // A table cell is a short line; prose in two columns is two wide lines on one baseline and must stay apart.
    auto narrow = [&](const Line& line) { return width > 0 && line.x1 - line.x0 < width * 0.3; };
    // Cells of one row are lines of about one height side by side. Text set sideways (a datasheet's copyright up the
    // margin) is one very tall line: it shared a centre with whatever row sat mid-page.
    auto sameRow = [](const Line& a, const Line& b) {
        double ha = MAX(1.0, a.y1 - a.y0), hb = MAX(1.0, b.y1 - b.y0);
        BOOL apart = a.x1 <= b.x0 || b.x1 <= a.x0;
        return apart && ha <= hb * 2 && hb <= ha * 2 &&
            fabs((a.y0 + a.y1) / 2 - (b.y0 + b.y1) / 2) <= MIN(ha, hb) * 0.4;
    };
    std::vector<bool> used(all.size(), false);
    BOOL group = all.size() <= kMaximumGroupedLines;
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (size_t i = 0; i < all.size(); i++) {
        if (used[i]) continue;
        used[i] = true;
        std::vector<size_t> row = {i};
        if (group && narrow(all[i]))
            for (size_t j = i + 1; j < all.size(); j++)
                if (!used[j] && narrow(all[j]) && sameRow(all[i], all[j])) { row.push_back(j); used[j] = true; }
        // Emitted where the row's first cell is in reading order: a table read column by column comes out by rows.
        std::sort(row.begin(), row.end(), [&](size_t a, size_t b) { return all[a].x0 < all[b].x0; });
        NSMutableArray* cells = [NSMutableArray array];
        for (size_t index : row) {
            NSString* cell = [all[index].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (cell.length) [cells addObject:cell];
        }
        if (cells.count) [out addObject:[cells componentsJoinedByString:@" | "]];
    }
    return [out componentsJoinedByString:@"\n"];
}

static NSString* Clipped(NSString* text, NSUInteger maxBytes, BOOL* cut) {
    *cut = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > maxBytes;
    if (!*cut) return text;
    NSUInteger end = 0, used = 0;
    while (end < text.length) {
        NSRange character = [text rangeOfComposedCharacterSequenceAtIndex:end];
        NSUInteger size = [[text substringWithRange:character] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (used + size > maxBytes) break;
        used += size;
        end = NSMaxRange(character);
    }
    return [text substringToIndex:end];
}

NSDictionary* SPDFMacAIWebDocumentPages(SPDFMacAIWebDocument* document, NSUInteger firstPage, NSUInteger count,
                                        NSUInteger maxBytes, NSError** error) {
    if (error) *error = nil;
    if (!firstPage || firstPage > document.pageCount) {
        if (error) *error = DocumentError(SPDFMacAIWebErrorInvalidAddress, [NSString stringWithFormat:
            @"The PDF has %lu pages; give a page from 1 to %lu.", (unsigned long)document.pageCount,
            (unsigned long)document.pageCount]);
        return nil;
    }
    char message[512] = {0};
    spdf_document* doc = spdf_open(document.fileURL.fileSystemRepresentation, message, sizeof(message));
    if (!doc) {
        if (error) *error = DocumentError(SPDFMacAIWebErrorBadDocument, @"The downloaded PDF could not be read again.");
        return nil;
    }
    NSMutableArray* pages = [NSMutableArray array];
    NSUInteger used = 0, index = firstPage - 1;
    BOOL truncated = NO;
    for (; index < document.pageCount && pages.count < MAX(count, (NSUInteger)1); index++) {
        spdf_text_lines lines = {};
        NSMutableArray* rows = [NSMutableArray array];
        BOOL read = spdf_extract_page_text_lines(doc, (int)index, &lines, message, sizeof(message));
        for (int k = 0; read && k < lines.count; k++) {
            spdf_text_line line = lines.items[k];
            NSString* text = line.text ? [NSString stringWithUTF8String:line.text] : nil;
            if (text.length) [rows addObject:@{@"text" : text, @"x0" : @(line.bounds.x0), @"y0" : @(line.bounds.y0),
                                              @"x1" : @(line.bounds.x1), @"y1" : @(line.bounds.y1)}];
        }
        BOOL scanned = read && lines.image_backed && !rows.count;
        spdf_free_text_lines(&lines);
        float width = 0, height = 0;
        spdf_page_size(doc, (int)index, &width, &height, message, sizeof(message));
        NSString* text = SPDFMacAIWebPageLinesText(rows, width);
        NSUInteger size = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        // The next page waits for the next call rather than be cut, unless it is the first: one page always comes.
        if (pages.count && used + size > maxBytes) break;
        BOOL cut = NO;
        text = Clipped(text, maxBytes > used ? maxBytes - used : 0, &cut);
        truncated |= cut;
        used += [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSMutableDictionary* page = [@{@"page" : @(index + 1), @"text" : text} mutableCopy];
        if (scanned) page[@"scanned"] = @YES;
        if (cut) page[@"truncated"] = @YES;
        [pages addObject:page];
    }
    spdf_close(doc);
    NSMutableDictionary* result = [@{@"pages" : pages} mutableCopy];
    if (index < document.pageCount) result[@"next_page"] = @(index + 1);
    if (truncated) result[@"truncated"] = @YES;
    return result;
}

#pragma mark - Links

NSURL* SPDFMacAIWebDocumentLink(SPDFMacAIWebDocument* document) {
    NSURLComponents* link = [NSURLComponents new];
    link.scheme = @"spdf-ai";
    link.host = @"web-document";
    link.queryItems = @[[NSURLQueryItem queryItemWithName:@"id" value:document.identifier],
                        [NSURLQueryItem queryItemWithName:@"web" value:document.sourceURL.absoluteString]];
    return link.URL;
}

static NSString* Query(NSURL* link, NSString* name) {
    for (NSURLQueryItem* item in [NSURLComponents componentsWithURL:link resolvingAgainstBaseURL:NO].queryItems)
        if ([item.name isEqual:name]) return item.value;
    return nil;
}

BOOL SPDFMacAIWebIsDocumentLink(NSURL* URL) {
    return [URL.scheme.lowercaseString isEqual:@"spdf-ai"] && [URL.host isEqual:@"web-document"] && !URL.user &&
        !URL.password && !URL.port && IsIdentifier(Query(URL, @"id"));
}

NSURL* SPDFMacAIWebDocumentFileForLink(NSURL* link, NSURL* folder) {
    if (!SPDFMacAIWebIsDocumentLink(link)) return nil;
    NSURL* directory = [folder URLByAppendingPathComponent:Query(link, @"id").uppercaseString isDirectory:YES];
    for (NSURL* file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil
                                                                       options:0 error:nil])
        if ([file.pathExtension.lowercaseString isEqual:@"pdf"]) return file;
    return nil;
}

NSURL* SPDFMacAIWebDocumentSourceForLink(NSURL* link) {
    NSURL* web = SPDFMacAIWebIsDocumentLink(link) ? [NSURL URLWithString:Query(link, @"web") ?: @""] : nil;
    return [web.scheme isEqual:@"https"] && web.host.length && !web.user && !web.password ? web : nil;
}
