#import "SPDFMacAIPythonDocuments.h"

#import "SPDFMacAIChatGrants.h"
#import "SPDFMacAIRequestContext.h"
#import "spdf_page_images.h"

#include <sys/stat.h>

static const NSUInteger kSPDFMaxDocuments = 8;
static const NSUInteger kSPDFMaxPages = 10;     // pages per list, images and renders each
static const int kSPDFMaxImages = 32;           // images written per run
static const long long kSPDFMaxImagePixels = 400000000;  // about ten 8000 x 6000 images
static const long long kSPDFMaxRenderPixels = 60000000;  // one rendered page
static const NSInteger kSPDFDefaultDPI = 150;

BOOL SPDFMacAIPythonDocumentIdentifierValid(id identifier) {
    if (![identifier isKindOfClass:NSString.class] || [identifier length] > 200) return NO;
    for (NSString* prefix in @[ @"doc:", @"collection:", @"attachment:" ])
        if ([identifier hasPrefix:prefix] && [identifier length] > prefix.length) return YES;
    return NO;
}

static NSString* SPDFPageListProblem(id pages, NSString* key) {
    if (!pages) return nil;
    if (![pages isKindOfClass:NSArray.class] || ![pages count] || [pages count] > kSPDFMaxPages)
        return [NSString stringWithFormat:@"%@ must list 1 to %lu page numbers.", key, (unsigned long)kSPDFMaxPages];
    for (id page in pages)
        if (![page isKindOfClass:NSNumber.class] || [page integerValue] < 1 || [page doubleValue] != [page integerValue])
            return [NSString stringWithFormat:@"%@ takes page numbers counted from 1.", key];
    return nil;
}

NSString* SPDFMacAIPythonDocumentsProblem(id requests) {
    if (!requests) return nil;
    if (![requests isKindOfClass:NSArray.class] || [requests count] > kSPDFMaxDocuments)
        return @"documents must be a list of at most 8 entries.";
    NSMutableSet* seen = [NSMutableSet set];
    for (id entry in requests) {
        if (![entry isKindOfClass:NSDictionary.class] || !SPDFMacAIPythonDocumentIdentifierValid(entry[@"id"]))
            return @"Each documents entry needs id: a doc: id from list_workspace, a collection: id from "
                   @"list_collection or an attachment: id from the person's message.";
        for (NSString* key in entry)
            if (![@[ @"id", @"path", @"images_on_pages", @"render_pages", @"dpi" ] containsObject:key])
                return [NSString stringWithFormat:@"Unknown documents field %@. Use id, path, images_on_pages, "
                                                  @"render_pages and dpi.", key];
        id path = entry[@"path"];
        if (path && (![path isKindOfClass:NSString.class] || ![path length] || [path length] > 1000 ||
                     ![entry[@"id"] hasPrefix:@"attachment:"]))
            return @"path names a file inside an attached folder, relative to it.";
        NSString* key = [NSString stringWithFormat:@"%@/%@", entry[@"id"], path ?: @""];
        if ([seen containsObject:key]) return @"List each document once.";
        [seen addObject:key];
        NSString* problem = SPDFPageListProblem(entry[@"images_on_pages"], @"images_on_pages") ?:
            SPDFPageListProblem(entry[@"render_pages"], @"render_pages");
        if (problem) return problem;
        id dpi = entry[@"dpi"];
        if (dpi && (![dpi isKindOfClass:NSNumber.class] || [dpi integerValue] < 36 || [dpi integerValue] > 600))
            return @"dpi must be a whole number from 36 to 600.";
    }
    return nil;
}

@implementation SPDFMacAIPythonDocument
+ (instancetype)documentWithIdentifier:(NSString*)identifier title:(NSString*)title path:(NSString*)path {
    SPDFMacAIPythonDocument* document = [self new];
    document->_identifier = [identifier copy];
    document->_title = [title copy];
    document->_path = [path copy];
    return document;
}
@end

SPDFMacAIPythonDocument* SPDFMacAIPythonAttachmentDocument(NSDictionary* request,
                                                            NSArray<SPDFMacAIRequestChip*>* chips, NSString** problem) {
    SPDFMacAIRequestChip* chip = nil;
    for (SPDFMacAIRequestChip* candidate in chips)
        if ([candidate.kind isEqual:SPDFMacAIChipKindAttachment] && [candidate.identifier isEqual:request[@"id"]])
            chip = candidate;
    NSString* why = nil;
    SPDFMacAIPythonDocument* document = nil;
    NSString* relative = [request[@"path"] isKindOfClass:NSString.class] ? request[@"path"] : nil;
    if (!chip || !chip.fileURL.path.length) {
        why = [NSString stringWithFormat:@"%@ is not attached to this chat. Use an attachment: id from this chat.",
                                         request[@"id"]];
    } else if (relative.length && !SPDFMacAIChatChipIsFolder(chip)) {
        why = @"path works only for an attached folder.";
    } else {
        NSString* root = chip.fileURL.path;
        NSString* real = relative.length ? SPDFMacAIChatGrantPathInside(root, relative, &why) : root;
        if (real)
            document = [SPDFMacAIPythonDocument documentWithIdentifier:request[@"id"]
                title:relative.length ? [chip.displayName stringByAppendingPathComponent:relative] : chip.displayName
                path:real];
    }
    if (problem) *problem = why;
    return document;
}

@implementation SPDFMacAIPythonDocumentFolder
- (instancetype)initWithPath:(NSString*)path files:(NSArray*)files index:(NSDictionary*)index {
    if (!(self = [super init])) return nil;
    _path = [path copy];
    _files = [files copy];
    _index = [index copy];
    return self;
}
// The folder holds links to the documents and files the app wrote; removing it never follows a link.
- (void)remove { [NSFileManager.defaultManager removeItemAtPath:_path error:nil]; }
@end

// A plain name from a title: letters, digits, dot, dash and underscore, at most 60 characters.
static NSString* SPDFPlainName(NSString* title, NSSet* taken) {
    NSMutableString* name = [NSMutableString string];
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSUInteger i = 0; i < title.length && name.length < 60; i++) {
        unichar c = [title characterAtIndex:i];
        [name appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    while ([name hasPrefix:@"."] || [name hasPrefix:@"_"]) [name deleteCharactersInRange:NSMakeRange(0, 1)];
    if (!name.length || [name isEqual:@"index.json"]) [name setString:@"document"];
    NSString* unique = name;
    for (NSUInteger n = 2; [taken containsObject:unique.lowercaseString]; n++)
        unique = [NSString stringWithFormat:@"%@-%lu", name, (unsigned long)n];
    return unique;
}

static BOOL SPDFIsPDF(NSString* path) {
    NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData* head = [handle readDataUpToLength:1024 error:nil];
    [handle closeFile];
    return head && [head rangeOfData:[@"%PDF-" dataUsingEncoding:NSASCIIStringEncoding] options:0
                               range:NSMakeRange(0, head.length)].location != NSNotFound;
}

static NSArray<NSNumber*>* SPDFZeroBased(NSArray* pages) {
    NSMutableOrderedSet* set = [NSMutableOrderedSet orderedSet];
    for (NSNumber* page in pages) [set addObject:@(page.intValue - 1)];
    return set.array;
}

static NSString* SPDFPagesPhrase(NSArray* pages) {
    if (pages.count == 1) return [NSString stringWithFormat:@"page %@", pages[0]];
    NSArray* head = [pages subarrayWithRange:NSMakeRange(0, pages.count - 1)];
    return [NSString stringWithFormat:@"pages %@ and %@", [head componentsJoinedByString:@", "], pages.lastObject];
}

NSString* SPDFMacAIPythonDocumentsSummary(NSArray<NSDictionary*>* requests, NSArray<SPDFMacAIPythonDocument*>* documents) {
    NSMutableArray* parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < requests.count && i < documents.count; i++) {
        NSMutableOrderedSet* pages = [NSMutableOrderedSet orderedSetWithArray:requests[i][@"images_on_pages"] ?: @[]];
        [pages addObjectsFromArray:requests[i][@"render_pages"] ?: @[]];
        NSString* title = documents[i].title;
        [parts addObject:pages.count ? [NSString stringWithFormat:@"%@ of %@", SPDFPagesPhrase(pages.array), title]
                                     : title];
    }
    return [parts componentsJoinedByString:@"; "];
}

// One document into the folder. A problem for the model, or nil.
static NSString* SPDFPrepareOne(NSDictionary* request, SPDFMacAIPythonDocument* document, NSString* folder,
                                NSMutableSet* taken, NSMutableArray* files, NSMutableArray* index,
                                volatile int* stop) {
    char resolved[PATH_MAX];
    struct stat info;
    if (!realpath(document.path.fileSystemRepresentation, resolved) || stat(resolved, &info) != 0 ||
        !(S_ISREG(info.st_mode) || S_ISDIR(info.st_mode)))
        return [NSString stringWithFormat:@"%@ is no longer available on this Mac.", document.title];
    NSString* real = @(resolved);
    BOOL folderItem = S_ISDIR(info.st_mode);
    NSString* extension = folderItem ? @"" : real.pathExtension.lowercaseString;
    NSString* title = document.title;
    if (extension.length && [title.pathExtension.lowercaseString isEqual:extension])
        title = title.stringByDeletingPathExtension;
    NSString* base = SPDFPlainName(title, taken);
    [taken addObject:base.lowercaseString];
    NSString* linkName = extension.length ? [base stringByAppendingPathExtension:extension] : base;
    [taken addObject:linkName.lowercaseString];
    if (![NSFileManager.defaultManager createSymbolicLinkAtPath:[folder stringByAppendingPathComponent:linkName]
                                            withDestinationPath:real error:nil])
        return @"The documents could not be prepared.";
    [files addObject:real];
    NSMutableDictionary* entry = [@{@"id" : document.identifier, @"title" : document.title,
                                    @"file" : [@"documents/" stringByAppendingString:linkName],
                                    @"bytes" : @(info.st_size)} mutableCopy];
    NSArray* imagePages = request[@"images_on_pages"], *renderPages = request[@"render_pages"];
    if (folderItem) {
        [entry removeObjectForKey:@"bytes"];
        entry[@"kind"] = @"folder";
        if (imagePages.count || renderPages.count)
            return [NSString stringWithFormat:@"%@ is a folder: give images_on_pages and render_pages for a PDF in it, "
                                              @"or read its files directly.", document.title];
        [index addObject:entry];
        return nil;
    }
    BOOL pdf = SPDFIsPDF(real);
    if (pdf) {
        char err[512] = {0};
        int count = spdf_document_page_count(real.fileSystemRepresentation, err, sizeof err);
        if (count < 0) return [NSString stringWithFormat:@"%@ could not be opened: %s.", document.title, err];
        entry[@"pages"] = @(count);
        for (NSNumber* page in [imagePages ?: @[] arrayByAddingObjectsFromArray:renderPages ?: @[]])
            if (page.intValue > count)
                return [NSString stringWithFormat:@"%@ has %d pages; page %@ is not one of them.", document.title,
                                                  count, page];
    } else if (imagePages.count || renderPages.count) {
        return [NSString stringWithFormat:@"%@ is not a PDF: images_on_pages and render_pages work only on PDFs. Read "
                                          @"its file instead.", document.title];
    }
    if (!imagePages.count && !renderPages.count) { [index addObject:entry]; return nil; }
    NSString* assets = [folder stringByAppendingPathComponent:base];
    if (mkdir(assets.fileSystemRepresentation, 0700) != 0) return @"The documents could not be prepared.";
    NSString* relative = [@"documents/" stringByAppendingString:base];
    if (imagePages.count) {
        NSArray* pages = SPDFZeroBased(imagePages);
        int* numbers = (int*)calloc(pages.count, sizeof(int));
        for (NSUInteger i = 0; i < pages.count; i++) numbers[i] = [pages[i] intValue];
        spdf_page_images images;
        char err[512] = {0};
        int status = spdf_extract_page_images(real.fileSystemRepresentation, numbers, (int)pages.count,
                                              assets.fileSystemRepresentation, kSPDFMaxImages, kSPDFMaxImagePixels,
                                              stop, &images, err, sizeof err);
        free(numbers);
        if (status != 0)
            return *stop ? @"Stopped." : [NSString stringWithFormat:@"The images of %@ could not be extracted: %s.",
                                                                    document.title, err];
        NSMutableArray* list = [NSMutableArray array];
        for (int i = 0; i < images.count; i++) {
            spdf_page_image* image = &images.items[i];
            [list addObject:@{@"page" : @(image->page + 1), @"index" : @(image->index),
                @"file" : [relative stringByAppendingPathComponent:@(image->file)],
                @"width" : @(image->width), @"height" : @(image->height),
                @"channels" : @(image->components + image->alpha), @"bits_per_component" : @(image->bits_per_component),
                @"colorspace" : @(image->colorspace), @"encoding" : @(image->encoding),
                @"lossless" : @(image->lossless != 0), @"has_mask" : @(image->has_mask != 0)}];
        }
        entry[@"images"] = list;
        if (images.skipped) entry[@"images_not_extracted"] = @(images.skipped);
        spdf_free_page_images(&images);
    }
    if (renderPages.count) {
        NSArray* pages = SPDFZeroBased(renderPages);
        int dpi = request[@"dpi"] ? [request[@"dpi"] intValue] : (int)kSPDFDefaultDPI;
        int* numbers = (int*)calloc(pages.count, sizeof(int));
        spdf_page_render* renders = (spdf_page_render*)calloc(pages.count, sizeof(spdf_page_render));
        for (NSUInteger i = 0; i < pages.count; i++) numbers[i] = [pages[i] intValue];
        char err[512] = {0};
        int status = spdf_render_pages_png(real.fileSystemRepresentation, numbers, (int)pages.count, dpi,
                                           assets.fileSystemRepresentation, kSPDFMaxRenderPixels, stop, renders, err,
                                           sizeof err);
        NSMutableArray* list = [NSMutableArray array];
        for (NSUInteger i = 0; status == 0 && i < pages.count; i++)
            [list addObject:@{@"page" : @(renders[i].page + 1), @"dpi" : @(dpi),
                              @"file" : [relative stringByAppendingPathComponent:@(renders[i].file)],
                              @"width" : @(renders[i].width), @"height" : @(renders[i].height)}];
        free(numbers);
        free(renders);
        if (status != 0)
            return *stop ? @"Stopped." : [NSString stringWithFormat:@"%@ could not be rendered: %s.", document.title, err];
        entry[@"renders"] = list;
    }
    [index addObject:entry];
    return nil;
}

void SPDFMacAIPythonPrepareDocuments(NSArray<NSDictionary*>* requests, NSArray<SPDFMacAIPythonDocument*>* documents,
                                     BOOL (^cancelled)(void),
                                     void (^completion)(SPDFMacAIPythonDocumentFolder*, NSString*)) {
    NSArray* work = [requests copy], *docs = [documents copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The core polls this between images; a timer on the main thread sets it when the request is stopped.
        volatile int* stop = (volatile int*)calloc(1, sizeof(int));
        dispatch_source_t poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(poll, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(poll, ^{ if (cancelled && cancelled()) *stop = 1; });
        dispatch_resume(poll);
        NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"ShenzhenPDF-AI-Python-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString* problem = nil;
        NSMutableArray* files = [NSMutableArray array], *index = [NSMutableArray array];
        if (mkdir(path.fileSystemRepresentation, 0700) != 0) problem = @"The documents could not be prepared.";
        NSMutableSet* taken = [NSMutableSet setWithObject:@"index.json"];
        for (NSUInteger i = 0; !problem && i < work.count; i++)
            problem = SPDFPrepareOne(work[i], docs[i], path, taken, files, index, stop);
        NSDictionary* manifest = @{@"documents" : index};
        if (!problem) {
            NSData* json = [NSJSONSerialization dataWithJSONObject:manifest
                                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys |
                                                                   NSJSONWritingWithoutEscapingSlashes error:nil];
            if (![json writeToFile:[path stringByAppendingPathComponent:@"index.json"] atomically:NO])
                problem = @"The documents could not be prepared.";
        }
        SPDFMacAIPythonDocumentFolder* folder =
            [[SPDFMacAIPythonDocumentFolder alloc] initWithPath:path files:files index:manifest];
        if (problem) [folder remove];
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_source_cancel(poll);
            free((void*)stop);
            completion(problem ? nil : folder, problem);
        });
    });
}
