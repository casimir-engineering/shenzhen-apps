// The Comments panel's rows for a PDF (cards: SPDFMacCommentCards.h; Markdown's rows:
// SPDFMacMarkdownCommentsIntegration.mm). Replies follow the comment they answer. The passage a highlight marks is
// read from the page only when its card first shows, one page at a time, and kept until the comments are reloaded:
// opening a document, or a panel of 200 comments, reads no page text.
#import "SPDFMacCommentPanel.h"
#import "SPDFMacCommentCards.h"
#import "SPDFMacDelegatePrivate.h"

#import <objc/runtime.h>
#include <vector>

@interface ShenzhenMacDelegate (SPDFMacCommentPanelHost)
- (BOOL)sidebarSearchText:(NSString*)text matchesFilter:(NSString*)filter;
@end

static NSString* UTF8(const char* text) { return text && *text ? [NSString stringWithUTF8String:text] ?: @"" : @""; }

static NSString* OneLineQuote(NSString* text) {
    NSArray* words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

static BOOL MarksText(NSString* type) {
    return [@[ @"Highlight", @"Underline", @"StrikeOut", @"Squiggly" ] containsObject:type];
}

@implementation ShenzhenMacDelegate (SPDFMacCommentPanel)
static char kQuotesKey, kQuotesStampKey;

// Passages read so far, by comment index, for the comments now loaded.
- (NSMutableDictionary<NSNumber*, NSString*>*)pdfCommentQuotes {
    NSString* stamp = [NSString stringWithFormat:@"%p/%d", (void*)_comments.items, _comments.count];
    NSMutableDictionary* quotes = objc_getAssociatedObject(self, &kQuotesKey);
    if (!quotes || ![objc_getAssociatedObject(self, &kQuotesStampKey) isEqual:stamp]) {
        quotes = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kQuotesKey, quotes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kQuotesStampKey, stamp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return quotes;
}

- (NSMutableDictionary*)pdfCommentCardItem:(const spdf_comment_item*)item level:(NSInteger)level {
    NSString* type = UTF8(item->type).length ? UTF8(item->type) : @"Comment";
    NSString* body = UTF8(item->text);
    NSString* author = UTF8(item->author);
    NSMutableDictionary* row = [@{
        @"kind" : @"comment",
        @"title" : author.length ? [NSString stringWithFormat:@"%@: %@", author, body.length ? body : type]
                                 : (body.length ? body : type),
        @"author" : author,
        @"body" : body.length || MarksText(type) ? body : type,
        @"page" : @(item->page_index),
        @"meta" : [NSString stringWithFormat:@"p. %d", item->page_index + 1],
        @"level" : @(level),
        @"commentIndex" : @(item->index)
    } mutableCopy];
    if (item->modified > 0) row[@"date"] = [NSDate dateWithTimeIntervalSince1970:item->modified];
    CGFloat width = item->bounds.x1 - item->bounds.x0, height = item->bounds.y1 - item->bounds.y0;
    if (width > 0 && height > 0)
        row[@"bounds"] = [NSValue valueWithRect:NSMakeRect(item->bounds.x0, item->bounds.y0, width, height)];
    if (MarksText(type) && row[@"bounds"]) {
        row[@"quoteReserved"] = @YES;
        row[@"quoteLines"] = @1;
        NSString* quote = self.pdfCommentQuotes[@(item->index)];
        if (quote) row[@"quote"] = quote;
    }
    return row;
}

// The comment, then its replies (and theirs) indented under it, each shown when it matches the filter.
- (void)appendPDFCommentThread:(const spdf_comment_item*)item
                         level:(NSInteger)level
                       replies:(NSDictionary<NSNumber*, NSArray<NSValue*>*>*)replies
                          seen:(NSMutableSet<NSNumber*>*)seen
                        filter:(NSString*)filter {
    if ([seen containsObject:@(item->index)]) return;
    [seen addObject:@(item->index)];
    NSMutableDictionary* row = [self pdfCommentCardItem:item level:MIN(level, 1)];
    NSString* haystack = [NSString stringWithFormat:@"%@ %@ %@ p.%d", row[@"title"], row[@"author"], row[@"quote"] ?: @"",
                                                    item->page_index + 1];
    if ([self sidebarSearchText:haystack matchesFilter:filter]) [_sidebarItems addObject:row];
    for (NSValue* reply in replies[@(item->index)])
        [self appendPDFCommentThread:(const spdf_comment_item*)reply.pointerValue level:level + 1 replies:replies
                                seen:seen filter:filter];
}

- (void)appendPDFCommentSidebarItemsMatchingFilter:(NSString*)filter {
    NSMutableSet<NSNumber*>* indexes = [NSMutableSet set];
    for (int i = 0; i < _comments.count; ++i) [indexes addObject:@(_comments.items[i].index)];
    NSMutableDictionary<NSNumber*, NSMutableArray<NSValue*>*>* replies = [NSMutableDictionary dictionary];
    for (int i = 0; i < _comments.count; ++i) {
        const spdf_comment_item* item = &_comments.items[i];
        if (item->in_reply_to < 0 || item->in_reply_to == item->index || ![indexes containsObject:@(item->in_reply_to)])
            continue;
        NSMutableArray* list = replies[@(item->in_reply_to)] ?: (replies[@(item->in_reply_to)] = [NSMutableArray array]);
        [list addObject:[NSValue valueWithPointer:item]];
    }
    NSUInteger before = _sidebarItems.count;
    NSMutableSet<NSNumber*>* seen = [NSMutableSet set];
    for (int i = 0; i < _comments.count; ++i) {
        const spdf_comment_item* item = &_comments.items[i];
        BOOL answers = item->in_reply_to >= 0 && item->in_reply_to != item->index &&
                       [indexes containsObject:@(item->in_reply_to)];
        if (!answers) [self appendPDFCommentThread:item level:0 replies:replies seen:seen filter:filter];
    }
    // Replies in a loop (each answering another) have no first comment: list them as they come.
    for (int i = 0; i < _comments.count; ++i)
        [self appendPDFCommentThread:&_comments.items[i] level:0 replies:replies seen:seen filter:filter];
    if (_sidebarItems.count == before) [_sidebarItems addObject:SPDFCommentsEmptyItem(filter)];
}

// The row's item with its passage read, when it marks one: every highlight on that page is read in one pass.
- (NSDictionary*)pdfCommentCardItemForRow:(NSInteger)row {
    NSDictionary* item = _sidebarItems[(NSUInteger)row];
    if (![item[@"quoteReserved"] boolValue] || item[@"quote"] || !_doc) return item;
    NSInteger page = [item[@"page"] integerValue];
    NSMutableArray<NSNumber*>* rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < _sidebarItems.count; ++i) {
        NSDictionary* other = _sidebarItems[i];
        if ([other[@"quoteReserved"] boolValue] && !other[@"quote"] && [other[@"page"] integerValue] == page)
            [rows addObject:@(i)];
    }
    std::vector<spdf_rect> rects;
    for (NSNumber* index in rows) {
        NSRect r = [_sidebarItems[index.unsignedIntegerValue][@"bounds"] rectValue];
        rects.push_back({(float)NSMinX(r), (float)NSMinY(r), (float)NSMaxX(r), (float)NSMaxY(r)});
    }
    std::vector<char*> texts(rects.size(), nullptr);
    char err[256];
    BOOL ok = spdf_page_text_in_rects(_doc, (int)page, rects.data(), (int)rects.size(), texts.data(), err, sizeof(err));
    NSMutableDictionary* quotes = self.pdfCommentQuotes;
    for (NSUInteger i = 0; i < rows.count; ++i) {
        NSString* quote = ok ? OneLineQuote(UTF8(texts[i])) : @"";
        if (!quote.length) quote = @"(no text)";
        spdf_free_string(texts[i]);
        NSUInteger at = rows[i].unsignedIntegerValue;
        NSMutableDictionary* updated = [_sidebarItems[at] mutableCopy];
        quotes[updated[@"commentIndex"]] = quote;
        updated[@"quote"] = quote;
        _sidebarItems[at] = updated;
    }
    return _sidebarItems[(NSUInteger)row];
}
@end
