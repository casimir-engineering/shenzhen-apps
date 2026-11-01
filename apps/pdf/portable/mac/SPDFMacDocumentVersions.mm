// Versions of a document as frozen copies beside it (SPDFMacDocumentVersions.h).

#import "SPDFMacDocumentVersions.h"
#import "SPDFMacMarkdownComments.h"

#include "shenzhen_pdf_core.h"

static NSString* const kErrorDomain = @"ShenzhenPDF.Versions";

static NSError* VersionError(NSString* message) {
    return [NSError errorWithDomain:kErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

static BOOL IsMarkdown(NSString* path) {
    NSString* extension = path.pathExtension.lowercaseString;
    return [@[ @"md", @"markdown", @"mdown" ] containsObject:extension];
}

static NSDate* ModificationDate(NSString* path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

// "Report v12" -> ("Report", 12); anything else -> (nil, 0).
static NSString* SplitVersionStem(NSString* stem, NSInteger* number) {
    static NSRegularExpression* pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      pattern = [NSRegularExpression regularExpressionWithPattern:@"^(.+) v([1-9][0-9]{0,5})$" options:0 error:nil];
    });
    NSTextCheckingResult* match = [pattern firstMatchInString:stem options:0 range:NSMakeRange(0, stem.length)];
    if (!match) return nil;
    if (number) *number = [[stem substringWithRange:[match rangeAtIndex:2]] integerValue];
    return [stem substringWithRange:[match rangeAtIndex:1]];
}

static NSString* VersionPath(NSString* current, NSInteger number) {
    NSString* stem = current.lastPathComponent.stringByDeletingPathExtension;
    NSString* name = [NSString stringWithFormat:@"%@ v%ld", stem, (long)number];
    if (current.pathExtension.length) name = [name stringByAppendingPathExtension:current.pathExtension];
    return [current.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
}

@implementation SPDFDocumentVersion
- (instancetype)initWithNumber:(NSInteger)number path:(NSString*)path current:(BOOL)current {
    if (!(self = [super init])) return nil;
    _number = number;
    _path = [path copy];
    _current = current;
    _date = [ModificationDate(path) copy] ?: NSDate.distantPast;
    NSString* comments = IsMarkdown(path) ? SPDFMarkdownCommentsFilePath(path) : nil;
    _commentsPath = comments && [NSFileManager.defaultManager fileExistsAtPath:comments] ? [comments copy] : nil;
    return self;
}
- (NSString*)name {
    return [NSString stringWithFormat:@"v%ld", (long)_number];
}
- (NSDictionary<NSString*, id>*)dictionaryRepresentation {
    NSMutableDictionary* out = [@{@"number" : @(_number), @"name" : self.name, @"path" : _path,
                                  @"date" : [[NSISO8601DateFormatter new] stringFromDate:_date],
                                  @"current" : @(_current)} mutableCopy];
    if (_commentsPath) out[@"commentsPath"] = _commentsPath;
    return out;
}
@end

BOOL SPDFDocumentVersionsSupportsPath(NSString* path) {
    return path.length && (IsMarkdown(path) || [path.pathExtension.lowercaseString isEqualToString:@"pdf"]) &&
           !SPDFMarkdownIsCommentsFilePath(path);
}

NSString* SPDFDocumentVersionsCurrentPath(NSString* path) {
    NSString* standard = path.stringByStandardizingPath;
    NSString* base = SplitVersionStem(standard.lastPathComponent.stringByDeletingPathExtension, NULL);
    if (!base.length) return standard;
    NSString* name = standard.pathExtension.length ? [base stringByAppendingPathExtension:standard.pathExtension] : base;
    NSString* current = [standard.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
    return [NSFileManager.defaultManager fileExistsAtPath:current] ? current : standard;
}

BOOL SPDFDocumentVersionsIsFrozenPath(NSString* path) {
    return ![SPDFDocumentVersionsCurrentPath(path) isEqualToString:path.stringByStandardizingPath];
}

// The frozen versions' numbers -> paths.
static NSDictionary<NSNumber*, NSString*>* FrozenVersions(NSString* current) {
    NSString* directory = current.stringByDeletingLastPathComponent;
    NSString* stem = current.lastPathComponent.stringByDeletingPathExtension;
    NSString* extension = current.pathExtension;
    NSMutableDictionary* found = [NSMutableDictionary dictionary];
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
        if ([name.pathExtension caseInsensitiveCompare:extension] != NSOrderedSame) continue;
        NSInteger number = 0;
        NSString* base = SplitVersionStem(name.stringByDeletingPathExtension, &number);
        if (!base || [base caseInsensitiveCompare:stem] != NSOrderedSame) continue;
        found[@(number)] = [directory stringByAppendingPathComponent:name];
    }
    return found;
}

NSArray<SPDFDocumentVersion*>* SPDFDocumentVersionsList(NSString* path) {
    NSString* current = SPDFDocumentVersionsCurrentPath(path);
    NSDictionary<NSNumber*, NSString*>* frozen = FrozenVersions(current);
    NSMutableArray* versions = [NSMutableArray array];
    for (NSNumber* number in [frozen.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [versions addObject:[[SPDFDocumentVersion alloc] initWithNumber:number.integerValue path:frozen[number] current:NO]];
    NSInteger next = [[frozen.allKeys valueForKeyPath:@"@max.integerValue"] integerValue] + 1;
    if ([NSFileManager.defaultManager fileExistsAtPath:current])
        [versions addObject:[[SPDFDocumentVersion alloc] initWithNumber:next path:current current:YES]];
    return versions;
}

// The comments file's text with its first line naming `documentName` (a copy for a version names that version).
static NSString* CommentsTextNaming(NSString* text, NSString* documentName) {
    NSRange firstLine = [text lineRangeForRange:NSMakeRange(0, 0)];
    if (![[text substringWithRange:firstLine] hasPrefix:@"# Comments on "]) return text;
    return [text stringByReplacingCharactersInRange:firstLine
                                         withString:[SPDFMarkdownCommentsHeader(documentName) stringByAppendingString:@"\n"]];
}

// Parses a comments file keeping which comments were listed under "Unplaced": parsed comments are not placed yet, so
// the ones above that heading get a stand-in position in file order, and are written back above it.
static NSArray<SPDFMarkdownComment*>* ParseKeepingPlacement(NSString* text) {
    NSRange unplaced = [text rangeOfString:@"\n## Unplaced\n"];
    NSString* placedText = unplaced.location == NSNotFound ? text : [text substringToIndex:unplaced.location];
    NSMutableArray* comments = [NSMutableArray array];
    NSUInteger position = 0;
    for (SPDFMarkdownComment* comment in SPDFMarkdownCommentsParseFile(placedText)) {
        comment.renderedRange = NSMakeRange(position++, 0);
        [comments addObject:comment];
    }
    if (unplaced.location != NSNotFound)
        [comments addObjectsFromArray:SPDFMarkdownCommentsParseFile([text substringFromIndex:unplaced.location])];
    return comments;
}

// Leaves the current document's comments file holding what `carry` keeps of `text` (the comments made on the version
// just frozen); removes it when nothing is kept.
static BOOL WriteCarriedComments(NSString* current, NSString* text, SPDFDocumentVersionCarry carry, NSError** error) {
    NSString* file = SPDFMarkdownCommentsFilePath(current);
    NSMutableArray* kept = [NSMutableArray array];
    if (carry != SPDFDocumentVersionCarryNone)
        for (SPDFMarkdownComment* comment in ParseKeepingPlacement(text))
            if (carry == SPDFDocumentVersionCarryAll || !comment.resolved) [kept addObject:comment];
    if (!kept.count) {
        NSError* removeError = nil;
        if ([NSFileManager.defaultManager removeItemAtPath:file error:&removeError] ||
            ![NSFileManager.defaultManager fileExistsAtPath:file]) return YES;
        if (error) *error = removeError;
        return NO;
    }
    if (carry == SPDFDocumentVersionCarryAll) return YES;  // the file already says exactly this
    return [SPDFMarkdownCommentsFileText(current.lastPathComponent, kept) writeToFile:file atomically:YES
                                                                              encoding:NSUTF8StringEncoding
                                                                                 error:error];
}

// Removes from the current PDF the comments `carry` does not keep, with their replies. Written to a copy that then
// replaces the file, so a failure leaves the document as it was.
static BOOL StripPDFComments(NSString* current, SPDFDocumentVersionCarry carry, NSError** error) {
    if (carry == SPDFDocumentVersionCarryAll) return YES;
    NSString* directory = current.stringByDeletingLastPathComponent;
    NSString* temp = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.tmp",
                                                                   current.lastPathComponent, NSUUID.UUID.UUIDString]];
    NSFileManager* files = NSFileManager.defaultManager;
    if (![files copyItemAtPath:current toPath:temp error:error]) return NO;
    char err[512] = {0};
    BOOL ok = NO, changed = NO;
    spdf_document* doc = spdf_open(temp.fileSystemRepresentation, err, sizeof(err));
    spdf_comments comments = {NULL, 0};
    if (doc && spdf_load_comments(doc, &comments, err, sizeof(err))) {
        ok = YES;
        // Highest index first, so the indexes still to delete do not move.
        for (int i = comments.count - 1; i >= 0 && ok; i--) {
            const spdf_comment_item* item = &comments.items[i];
            int top = item->in_reply_to;
            while (top >= 0 && top < comments.count && comments.items[top].in_reply_to >= 0) top = comments.items[top].in_reply_to;
            const spdf_comment_item* thread = top >= 0 && top < comments.count ? &comments.items[top] : item;
            BOOL keep = carry == SPDFDocumentVersionCarryOpen && !thread->resolved;
            if (keep) continue;
            ok = spdf_delete_comment(doc, item->index, err, sizeof(err));
            changed = YES;
        }
        if (ok && changed) ok = spdf_save_document(doc, temp.fileSystemRepresentation, err, sizeof(err));
    }
    spdf_free_comments(&comments);
    if (doc) spdf_close(doc);
    if (ok && changed) ok = [files replaceItemAtURL:[NSURL fileURLWithPath:current] withItemAtURL:[NSURL fileURLWithPath:temp]
                                     backupItemName:nil options:0 resultingItemURL:nil error:error];
    else if (!ok && error) *error = VersionError([NSString stringWithFormat:@"The comments could not be removed from %@. %s",
                                                                            current.lastPathComponent, err]);
    [files removeItemAtPath:temp error:nil];
    return ok;
}

// Copies `content` to the next version's path, dated `date`, and gives it the comments in `commentsText`.
static SPDFDocumentVersion* Freeze(NSString* current, NSString* content, NSDate* date, NSString* commentsText,
                                   NSError** error) {
    NSFileManager* files = NSFileManager.defaultManager;
    NSInteger number = [[FrozenVersions(current).allKeys valueForKeyPath:@"@max.integerValue"] integerValue] + 1;
    while ([files fileExistsAtPath:VersionPath(current, number)]) number++;
    NSString* destination = VersionPath(current, number);
    if (![files copyItemAtPath:content toPath:destination error:error]) return nil;
    if (date) [files setAttributes:@{NSFileModificationDate : date} ofItemAtPath:destination error:nil];
    if (commentsText.length) {
        NSString* text = CommentsTextNaming(commentsText, destination.lastPathComponent);
        if (![text writeToFile:SPDFMarkdownCommentsFilePath(destination) atomically:YES encoding:NSUTF8StringEncoding
                         error:error]) {
            [files removeItemAtPath:destination error:nil];
            return nil;
        }
    }
    return [[SPDFDocumentVersion alloc] initWithNumber:number path:destination current:NO];
}

static SPDFDocumentVersion* FreezeAndCarry(NSString* path, NSString* content, NSDate* date,
                                           SPDFDocumentVersionCarry carry, BOOL fromCurrentFile, NSError** error) {
    NSString* current = SPDFDocumentVersionsCurrentPath(path);
    if (!SPDFDocumentVersionsSupportsPath(current)) {
        if (error) *error = VersionError(@"Only Markdown documents and PDFs can have versions.");
        return nil;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:current] || !content) {
        if (error) *error = VersionError([NSString stringWithFormat:@"%@ is no longer there.", current.lastPathComponent]);
        return nil;
    }
    NSString* commentsFile = IsMarkdown(current) ? SPDFMarkdownCommentsFilePath(current) : nil;
    NSString* commentsText = commentsFile ? [NSString stringWithContentsOfFile:commentsFile encoding:NSUTF8StringEncoding
                                                                         error:nil] : nil;
    SPDFDocumentVersion* version = Freeze(current, fromCurrentFile ? current : content, date, commentsText, error);
    if (!version) return nil;
    BOOL ok = YES;
    if (commentsText.length) ok = WriteCarriedComments(current, commentsText, carry, error);
    else if (!IsMarkdown(current) && fromCurrentFile) ok = StripPDFComments(current, carry, error);
    return ok ? version : nil;
}

SPDFDocumentVersion* SPDFDocumentVersionsCreate(NSString* path, SPDFDocumentVersionCarry carry, NSError** error) {
    NSString* current = SPDFDocumentVersionsCurrentPath(path);
    return FreezeAndCarry(current, current, ModificationDate(current), carry, YES, error);
}

SPDFDocumentVersion* SPDFDocumentVersionsKeepPrevious(NSString* path, NSString* previousContent, NSDate* previousDate,
                                                      SPDFDocumentVersionCarry carry, NSError** error) {
    return FreezeAndCarry(path, previousContent, previousDate, carry, NO, error);
}

NSUInteger SPDFDocumentVersionsCommentCount(NSString* path, NSUInteger* openCount) {
    NSUInteger total = 0, open = 0;
    if (IsMarkdown(path)) {
        NSString* text = [NSString stringWithContentsOfFile:SPDFMarkdownCommentsFilePath(path)
                                                   encoding:NSUTF8StringEncoding error:nil];
        for (SPDFMarkdownComment* comment in text ? SPDFMarkdownCommentsParseFile(text) : @[]) {
            total++;
            if (!comment.resolved) open++;
        }
    } else {
        char err[256] = {0};
        spdf_document* doc = spdf_open(path.fileSystemRepresentation, err, sizeof(err));
        spdf_comments comments = {NULL, 0};
        if (doc && spdf_load_comments(doc, &comments, err, sizeof(err)))
            for (int i = 0; i < comments.count; i++) {
                if (comments.items[i].in_reply_to >= 0) continue;
                total++;
                if (!comments.items[i].resolved) open++;
            }
        spdf_free_comments(&comments);
        if (doc) spdf_close(doc);
    }
    if (openCount) *openCount = open;
    return total;
}
