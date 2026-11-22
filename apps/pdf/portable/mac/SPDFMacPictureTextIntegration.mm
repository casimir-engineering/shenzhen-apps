// Text in pictures and scanned PDFs, read on this Mac: see SPDFMacPictureTextIntegration.h.
#import "SPDFMacPictureTextIntegration.h"
#import "SPDFMacPictureText.h"
#import "SPDFMacPictureTextStore.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacModels.h"
#include "spdf_ocr_layer.h"
#include <sys/file.h>

@interface ShenzhenMacDelegate (PictureTextHost)
- (NSString*)activeWorkingPath;
- (void)invalidateCursorRegionCache;
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (SPDFDocumentTab*)selectedTab;
- (void)loadSelectedTab;
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab;
- (void)cancelCacheRenderOperations;
- (void)clearActiveMetadata;
- (void)closeActiveDocumentIfUnowned;
- (BOOL)ensureActivePDFCanBeModifiedForOperation:(NSString*)operationName;
- (BOOL)collectionProtectPath:(NSString*)path operation:(NSString*)operation;
- (void)collectionDidSavePath:(NSString*)path;
- (void)collectionRecordUserOpenForPath:(NSString*)path document:(NSDictionary*)document;
- (NSString*)tesseractToolPath;
- (NSDictionary<NSString*, NSString*>*)ocrTaskEnvironmentWithTool:(NSString*)tool tesseract:(NSString*)tesseract
                                                         language:(NSString*)language;
- (void)showOCRProgressWithDetail:(NSString*)detail;
- (void)updateOCRProgressDetail:(NSString*)detail;
- (void)finishOCRProgressWithDetail:(NSString*)detail;
- (void)prepareDocumentToolPDFWithSuffix:(NSString*)suffix completion:(void (^)(void))completion;
@end

// One picture at a time, behind everything else: reading text takes a second or two of the machine per picture.
static dispatch_queue_t Queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.intuition.shenzhenpdf.picture-text",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static const NSUInteger kPicturePages = 50;  // a multipage TIFF past this is read up to here

static NSString* FileHash(NSString* path) { return SPDFCollectionHashURL([NSURL fileURLWithPath:path], nil); }

@implementation ShenzhenMacDelegate (PictureText)

// The engine chosen for OCR, with what open source needs to run (macOS reads when Tesseract isn't installed).
- (NSDictionary*)pictureTextEngine {
    NSString* engine = SPDFMacOCREngine();
    if (![engine isEqualToString:SPDFMacOCREngineOpenSource]) return @{@"engine": engine};
    NSString* tesseract = [self tesseractToolPath];
    if (!tesseract.length) return @{@"engine": SPDFMacOCREngineMacOS};
    NSDictionary* environment = [self ocrTaskEnvironmentWithTool:nil tesseract:tesseract
                                                        language:SPDFMacOCROpenSourceLanguage()];
    return @{@"engine": engine, @"tesseract": tesseract, @"environment": environment ?: @{}};
}

static NSDictionary* Recognize(NSString* path, NSDictionary* engine, NSIndexSet* pages, NSUInteger maxPages,
                               NSError** error) {
    return SPDFMacRecognizeText(path, engine[@"engine"], engine[@"tesseract"], engine[@"environment"], pages, maxPages,
                                nil, error);
}

// Lays `recognized` over the picture at `source` in every tab showing it (a read-only original is shown from a copy).
- (void)pictureTextShow:(NSDictionary*)recognized forPath:(NSString*)source {
    SPDFMacPictureTextRemember(source, recognized);
    for (SPDFDocumentTab* tab in _tabs)
        if ([tab.path isEqualToString:source] && tab.workingPath.length && ![tab.workingPath isEqualToString:source])
            SPDFMacPictureTextRemember(tab.workingPath, recognized);
    // The I-beam over text comes from a per-page cache of where the text is.
    if ([_path isEqualToString:source]) [self invalidateCursorRegionCache];
}

- (BOOL)pictureTextOpenedPath:(NSString*)source capture:(void (^)(void (^)(NSDictionary*)))capture {
    if (!SPDFMacPictureTextCandidatePath(source)) return NO;
    NSDictionary* engine = [self pictureTextEngine];
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(Queue(), ^{
        NSString* hash = FileHash(source);
        if (!hash) return;
        NSDictionary* recognized = SPDFMacPictureTextKnown(source) ?: [store pictureTextForPath:source hash:hash];
        if (!recognized) {
            if ([store pictureHashHasNoText:hash]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf collectionRecordUserOpenForPath:source document:[store documentForPath:source]];
                });
                return;
            }
            recognized = Recognize(source, engine, nil, kPicturePages, nil);
            if (!recognized) return;  // couldn't be read: looked at again the next time it opens
        }
        if (!SPDFMacRecognizedHasText(recognized)) {
            [store setPictureHash:hash hasNoText:YES];
            // Kept before (by an older reader, or as an earlier open of these bytes): it leaves Collection now.
            NSDictionary* doc = [store documentForPath:source];
            if ([[doc[@"versions"] lastObject][@"hash"] isEqual:hash])
                [store removePictureWithoutTextDocumentID:doc[@"id"] error:nil];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf pictureTextShow:recognized forPath:source];
            capture(^(NSDictionary* doc) {
                NSString* documentID = doc[@"id"];
                if (!documentID.length) return;
                dispatch_async(Queue(), ^{
                    if (![store pictureTextForPath:source hash:hash])
                        [store attachPictureText:recognized documentID:documentID hash:hash error:nil];
                });
            });
        });
    });
    return YES;
}

#pragma mark Pictures Collection kept before

- (void)pictureTextScheduleCollectionCheck {
    static BOOL scheduled;
    if (scheduled) return;
    scheduled = YES;
    NSDictionary* engine = [self pictureTextEngine];
    // Well after launch, so the first minute belongs to what is being read.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), Queue(), ^{
        SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
        if (!store.isEnabled) return;
        // Every window is its own process: the one holding this lock does the work, the others leave it.
        NSString* lockPath = [store.rootURL URLByAppendingPathComponent:@"picture-text.lock"].path;
        int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
        if (fd < 0) return;
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return; }
        NSArray* waiting = [store picturesAwaitingText:^BOOL(NSString* name) {
            return SPDFMacPictureTextCandidatePath(name);
        }];
        for (NSDictionary* picture in waiting) {
            @autoreleasepool {
                if (!store.isEnabled) break;
                NSURL* copy = [store materializeVersionID:picture[@"versionID"] documentID:picture[@"documentID"]
                                                    error:nil];
                NSDictionary* recognized = copy ? Recognize(copy.path, engine, nil, kPicturePages, nil) : nil;
                if (!recognized) continue;
                if (SPDFMacRecognizedHasText(recognized)) {
                    [store attachPictureText:recognized documentID:picture[@"documentID"] hash:picture[@"hash"]
                                       error:nil];
                } else {
                    [store setPictureHash:picture[@"hash"] hasNoText:YES];
                    [store removePictureWithoutTextDocumentID:picture[@"documentID"] error:nil];
                }
            }
        }
        flock(fd, LOCK_UN);
        close(fd);
    });
}

#pragma mark OCR on this Mac

- (void)recognizeShownDocumentTextOnThisMac {
    if (!_doc || !_path.length) { NSBeep(); return; }
    if ([_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) { [self recognizePDFTextOnThisMac]; return; }
    if (!SPDFMacPictureTextCandidatePath(_path)) {
        // A drawing or a document of another kind: its PDF, made as open source makes it, gets the text layer.
        __weak ShenzhenMacDelegate* weakSelf = self;
        [self prepareDocumentToolPDFWithSuffix:@"ocr" completion:^{ [weakSelf recognizePDFTextOnThisMac]; }];
        return;
    }
    NSString* source = [_path copy];
    NSString* reading = [self activeWorkingPath].length ? [[self activeWorkingPath] copy] : source;
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    _statusLabel.stringValue = @"Looking for text in this picture…";
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(Queue(), ^{
        NSError* error = nil;
        NSDictionary* recognized = Recognize(reading, @{@"engine": SPDFMacOCREngineMacOS}, nil, kPicturePages, &error);
        NSString* hash = recognized ? FileHash(source) : nil;
        BOOL keep = store.isEnabled && hash && ![store isArchivePath:source];
        if (keep) [store setPictureHash:hash hasNoText:!SPDFMacRecognizedHasText(recognized)];
        dispatch_async(dispatch_get_main_queue(), ^{
            ShenzhenMacDelegate* owner = weakSelf;
            if (!owner) return;
            if (!recognized) {
                owner->_statusLabel.stringValue = @"";
                [owner showError:@"Couldn't read the text in this picture" detail:error.localizedDescription ?: @""];
                return;
            }
            if (!SPDFMacRecognizedHasText(recognized)) {
                owner->_statusLabel.stringValue = @"No text found in this picture.";
                NSAlert* alert = [NSAlert new];
                alert.messageText = @"No text found in this picture";
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
                return;
            }
            [owner pictureTextShow:recognized forPath:source];
            owner->_statusLabel.stringValue = @"Text found: it selects, copies and searches like any other text.";
            if (!keep) return;
            [store capturePath:source reason:@"Opened" completion:^(NSDictionary* doc, NSError* captureError) {
                (void)captureError;
                if (!doc[@"id"]) return;
                dispatch_async(Queue(), ^{ [store attachPictureText:recognized documentID:doc[@"id"] hash:hash error:nil]; });
            }];
        });
    });
}

// Pages that already have text keep it; the others get Apple's.
- (void)recognizePDFTextOnThisMac {
    if (!_doc || ![_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) { NSBeep(); return; }
    if (spdf_is_password_protected(_doc)) {
        [self showError:@"OCR is unavailable for password-protected PDFs"
                 detail:@"To OCR this document, intentionally create and open an unprotected copy first. Shenzhen PDF "
                        @"will not decrypt a protected PDF into a temporary file or silently replace it with an "
                        @"unprotected result."];
        return;
    }
    if (![self ensureActivePDFCanBeModifiedForOperation:@"OCR"]) return;
    NSString* original = [_path copy];
    NSInteger originalPage = _pageIndex;
    NSString* temporary = [original.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.ocr-%@.pdf", original.lastPathComponent, NSUUID.UUID.UUIDString]];
    _ocrButton.enabled = NO;
    _statusLabel.stringValue = @"Reading the pages…";
    [self showOCRProgressWithDetail:@"Reading the pages without text…"];
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(Queue(), ^{
        NSString* failure = nil;
        BOOL nothingToDo = NO;
        char message[1024] = {};
        spdf_document* document = spdf_open(original.fileSystemRepresentation, message, sizeof(message));
        NSMutableIndexSet* pages = [NSMutableIndexSet indexSet];
        NSMutableArray* sizes = [NSMutableArray array];
        if (!document) failure = message[0] ? @(message) : @"The PDF couldn't be opened.";
        int count = document ? spdf_page_count(document) : 0;
        for (int index = 0; index < count; ++index) {
            spdf_text_lines lines = {};
            float width = 0, height = 0;
            spdf_page_size(document, index, &width, &height, message, sizeof(message));
            [sizes addObject:[NSValue valueWithSize:NSMakeSize(width, height)]];
            if (spdf_extract_page_text_lines(document, index, &lines, message, sizeof(message)) && lines.count == 0)
                [pages addIndex:(NSUInteger)index];
            spdf_free_text_lines(&lines);
        }
        if (document) spdf_close(document);
        if (!failure && !pages.count) nothingToDo = YES;
        NSDictionary* recognized = nil;
        if (!failure && !nothingToDo) {
            NSError* error = nil;
            recognized = Recognize(original, @{@"engine": SPDFMacOCREngineMacOS}, pages, NSUIntegerMax, &error);
            if (!recognized) failure = error.localizedDescription ?: @"Text recognition failed.";
        }
        BOOL written = NO;
        if (recognized && SPDFMacRecognizedHasText(recognized)) {
            // Pixels of the page as it was read, to points of the page as the reader shows it.
            NSMutableArray* texts = [NSMutableArray array];
            NSMutableData* words = [NSMutableData data];
            for (NSDictionary* page in recognized[@"pages"]) {
                NSInteger index = [page[@"page"] integerValue] - 1;
                if (index < 0 || index >= (NSInteger)sizes.count) continue;
                NSSize size = [sizes[(NSUInteger)index] sizeValue];
                double sx = size.width / [page[@"width"] doubleValue], sy = size.height / [page[@"height"] doubleValue];
                for (NSDictionary* line in page[@"lines"]) {
                    NSArray* lineWords = line[@"words"];
                    for (NSUInteger w = 0; w < lineWords.count; ++w) {
                        NSDictionary* word = lineWords[w];
                        NSArray* box = word[@"box"];
                        if (box.count != 4 || ![word[@"text"] length]) continue;
                        [texts addObject:word[@"text"]];
                        double x = [box[0] doubleValue], y = [box[1] doubleValue];
                        spdf_ocr_word item = {(int)index, (float)(x * sx), (float)(y * sy),
                            (float)((x + [box[2] doubleValue]) * sx), (float)((y + [box[3] doubleValue]) * sy), NULL,
                            w + 1 < lineWords.count};
                        [words appendBytes:&item length:sizeof(item)];
                    }
                }
            }
            spdf_ocr_word* items = (spdf_ocr_word*)words.mutableBytes;
            for (NSUInteger i = 0; i < texts.count; ++i) items[i].text = [texts[i] UTF8String];
            written = spdf_save_pdf_with_ocr_words(original.fileSystemRepresentation, temporary.fileSystemRepresentation,
                                                   items, (int)texts.count, message, sizeof(message));
            if (!written) failure = message[0] ? @(message) : @"The text couldn't be written into the PDF.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ShenzhenMacDelegate* owner = weakSelf;
            if (!owner) return;
            owner->_ocrButton.enabled = owner->_doc != NULL;
            if (failure || !written) {
                [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
                NSString* outcome = failure ? @"OCR failed." : nothingToDo ? @"Every page already has text." :
                                                                             @"No text found on the pages.";
                owner->_statusLabel.stringValue = outcome;
                [owner finishOCRProgressWithDetail:outcome];
                if (failure) [owner showError:@"OCR failed" detail:failure];
                else {
                    NSAlert* alert = [NSAlert new];
                    alert.messageText = nothingToDo ? @"Every page of this PDF already has text"
                                                    : @"No text found on the pages without text";
                    alert.informativeText = nothingToDo ? @"Nothing was changed. To read it again, delete its text first "
                                                          @"(File > Delete All Text…)." : @"The PDF was left unchanged.";
                    [alert addButtonWithTitle:@"OK"];
                    [alert runModal];
                }
                return;
            }
            [owner installRecognizedPDF:temporary over:original page:originalPage];
        });
    });
}

// As OCRmyPDF's result is installed: Collection keeps the version being replaced, the file is swapped, the tab reopens.
- (void)installRecognizedPDF:(NSString*)temporary over:(NSString*)original page:(NSInteger)originalPage {
    if (![self collectionProtectPath:original operation:@"installing OCR output"]) {
        [self finishOCRProgressWithDetail:@"OCR output was not installed."];
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        return;
    }
    BOOL shown = [_path isEqualToString:original];
    if (shown) {
        [_renderQueue cancelAllOperations];
        [self cancelCacheRenderOperations];
        [_minimapQueue cancelAllOperations];
        [_queuedRenderPages removeAllObjects];
        [_queuedRenderOperations removeAllObjects];
        [_queuedMinimapThumbnailPages removeAllObjects];
        _renderGeneration++;
        [self discardCachedRuntimeForTab:[self selectedTab]];
        [self clearActiveMetadata];
        [self closeActiveDocumentIfUnowned];
    }
    NSError* error = nil;
    if (![NSFileManager.defaultManager replaceItemAtURL:[NSURL fileURLWithPath:original]
                                          withItemAtURL:[NSURL fileURLWithPath:temporary] backupItemName:nil options:0
                                       resultingItemURL:nil error:&error]) {
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
        [self finishOCRProgressWithDetail:@"Could not save OCR output."];
        [self showError:@"Could not save OCR output" detail:error.localizedDescription ?: @""];
        _statusLabel.stringValue = @"OCR output was not installed.";
        if (shown) [self loadSelectedTab];
        return;
    }
    if (shown) [self selectedTab].pageIndex = originalPage;
    [self collectionDidSavePath:original];
    if (shown) [self loadSelectedTab];
    _statusLabel.stringValue = @"OCR complete.";
    [self finishOCRProgressWithDetail:_statusLabel.stringValue];
}

#pragma mark Delete All Text

- (BOOL)shownPictureHasText {
    if (!_doc || !SPDFMacPictureTextCandidatePath(_path)) return NO;
    NSString* reading = [self activeWorkingPath].length ? [self activeWorkingPath] : _path;
    return SPDFMacPictureTextKnown(reading) != nil;
}

- (BOOL)deleteTextFromPicture:(id)sender {
    (void)sender;
    if (!_doc || !SPDFMacPictureTextCandidatePath(_path)) return NO;
    if (![self shownPictureHasText]) { NSBeep(); return YES; }
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"Delete the text found in this picture?";
    alert.informativeText = @"The picture stays as it is. Its text can no longer be selected or searched, and Collection "
                            @"stops keeping the picture. Run OCR to find it again.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Delete Text"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return YES;
    NSString* source = [_path copy];
    [self pictureTextShow:nil forPath:source];
    _statusLabel.stringValue = @"The text found in this picture was deleted.";
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    if (!store.isEnabled || [store isArchivePath:source]) return YES;
    dispatch_async(Queue(), ^{
        NSString* hash = FileHash(source);
        if (!hash) return;
        [store setPictureHash:hash hasNoText:YES];
        NSDictionary* doc = [store documentForPath:source];
        if ([[doc[@"versions"] lastObject][@"hash"] isEqual:hash])
            [store removePictureWithoutTextDocumentID:doc[@"id"] error:nil];
    });
    return YES;
}
@end
