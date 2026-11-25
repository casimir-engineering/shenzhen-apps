// Saving a picture or canvas (docs/plans/annotate.md § 5 Files): the flattened picture into its file in its own format
// (encoded and written off the main thread, Collection told before and after), Save As, the layers kept beside a
// picture in <state>/Annotate (written 2 s after the last change), the flush before a tab closes or the app quits,
// and the tool settings file.
#import "SPDFMacAnnotateSessionPrivate.h"

#import <CommonCrypto/CommonDigest.h>

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacSupport.h"

static NSError* SaveError(NSString* message) {
    return [NSError errorWithDomain:@"ShenzhenPDF.Annotate" code:3 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString* AnnotateFolder(void) {
    return [SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Annotate"];
}

static void EnsureFolder(NSString* folder) {
    spdf_mac_support_directory();  // creates the state folder itself
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
}

static NSString* PathHash(NSString* path) {
    const char* bytes = path.stringByStandardizingPath.UTF8String ?: "";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)strlen(bytes), digest);
    NSMutableString* hex = [NSMutableString string];
    for (int i = 0; i < 16; ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// The file's size and modification time, which say whether kept layers still belong to it.
static NSDictionary* FileStamp(NSString* path) {
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attributes) return nil;
    return @{@"path": path.stringByStandardizingPath, @"size": attributes[NSFileSize] ?: @0,
             @"mtime": @([attributes[NSFileModificationDate] timeIntervalSince1970])};
}

static dispatch_queue_t WriteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.intuition.shenzhenpdf.annotate-save",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                              QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

static NSString* UTIForFormat(NSString* format) {
    for (NSDictionary* row in SPDFAnnotateSaveFormats())
        if ([row[@"format"] isEqual:format] || [row[@"uti"] isEqual:format]) return row[@"uti"];
    return format;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation SPDFMacAnnotateSession (Saving)

#pragma mark - Kept layers

+ (NSString*)sidecarPathForPath:(NSString*)path {
    return [AnnotateFolder() stringByAppendingPathComponent:[PathHash(path) stringByAppendingPathExtension:@"szpaint"]];
}

+ (spdf_paint_doc*)openSidecarForPath:(NSString*)path {
    NSString* sidecar = [self sidecarPathForPath:path];
    NSData* data = [NSData dataWithContentsOfFile:[sidecar.stringByDeletingPathExtension stringByAppendingPathExtension:@"json"]];
    NSDictionary* kept = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary* now = FileStamp(path);
    if (![kept isKindOfClass:NSDictionary.class] || !now || ![kept[@"path"] isEqual:now[@"path"]] ||
        [kept[@"size"] unsignedLongLongValue] != [now[@"size"] unsignedLongLongValue] ||
        fabs([kept[@"mtime"] doubleValue] - [now[@"mtime"] doubleValue]) > 0.001)
        return NULL;
    char err[256];
    return spdf_paint_read_project(sidecar.fileSystemRepresentation, err, sizeof(err));
}

// Layers are worth keeping when there is more than the Background: an object, another layer.
- (BOOL)hasLayersToKeep {
    NSArray* layers = [self stateForPage:-1][@"layers"];
    return [layers isKindOfClass:NSArray.class] && layers.count > 1;
}

- (void)writeSidecarNow:(BOOL)synchronously {
    if (!_canvas || self.kind == SPDFAnnotateDocumentPDF || self.projectPath) return;
    NSString* path = [self.path copy];
    NSString* sidecar = [SPDFMacAnnotateSession sidecarPathForPath:path];
    NSString* record = [sidecar.stringByDeletingPathExtension stringByAppendingPathExtension:@"json"];
    unsigned char* bytes = NULL;
    size_t length = 0;
    char err[256];
    // A WebP or RAW drawn on keeps its pixels here too until they are saved as a PNG: nothing is lost on quit.
    BOOL copyChanges = self.kind == SPDFAnnotateDocumentPicture && !self.writesInPlace && self.dirty;
    BOOL keep = ([self hasLayersToKeep] || copyChanges) &&
                spdf_paint_project_bytes(_canvas, &bytes, &length, err, sizeof(err)) == SPDF_PAINT_OK;
    NSData* project = keep ? [NSData dataWithBytes:bytes length:length] : nil;
    spdf_paint_free(bytes);
    void (^write)(void) = ^{
        if (!project) {  // nothing beyond the picture itself: what was kept before no longer applies
            [NSFileManager.defaultManager removeItemAtPath:sidecar error:nil];
            [NSFileManager.defaultManager removeItemAtPath:record error:nil];
            return;
        }
        // Stamped on the write queue, after any picture write queued before it, so the record names the file as it
        // is once both are done.
        NSDictionary* stamp = FileStamp(path);
        if (!stamp) return;
        EnsureFolder(AnnotateFolder());
        NSData* json = [NSJSONSerialization dataWithJSONObject:stamp options:0 error:NULL];
        if (SPDFAnnotateWriteFileAtomically(project, sidecar, NULL)) SPDFAnnotateWriteFileAtomically(json, record, NULL);
    };
    if (synchronously) dispatch_sync(WriteQueue(), write);
    else dispatch_async(WriteQueue(), write);
}

- (void)scheduleProjectAutosave {
    if (!_canvas || self.kind == SPDFAnnotateDocumentPDF) return;
    [self.autosaveTimer invalidate];
    __weak SPDFMacAnnotateSession* weakSelf = self;
    self.autosaveTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer* timer) {
        (void)timer;
        SPDFMacAnnotateSession* session = weakSelf;
        session.autosaveTimer = nil;
        if (session.projectPath) return;  // a project is its own file, written by Cmd-S, Done, close or quit
        [session writeSidecarNow:NO];
    }];
}

- (void)rememberFileStamp {
    self.fileStamp = self.path ? FileStamp(self.path) : nil;
}

- (BOOL)fileChangedElsewhere {
    if (!self.loaded || !self.fileStamp || self.kind == SPDFAnnotateDocumentPDF) return NO;
    return ![FileStamp(self.path) isEqual:self.fileStamp];
}

#pragma mark - Writing the picture

// The flattened canvas into `path` as `uti` (or the .szpaint project), on the write queue unless synchronously.
// The core is marked saved at the moment its pixels are taken, so a change made while the encode runs stays unsaved.
- (void)writeTo:(NSString*)path uti:(NSString*)uti quality:(CGFloat)quality protect:(BOOL)protect
    synchronously:(BOOL)synchronously completion:(void (^)(NSError* error))completion {
    if (!_canvas) {
        if (completion) completion(SaveError(@"There is nothing to save."));
        return;
    }
    if (protect && [NSFileManager.defaultManager fileExistsAtPath:path] &&
        ![self.host annotateSessionProtectPath:path]) {
        // The person chose Cancel Edit in Collection's own question: nothing more to say.
        if (completion) completion([NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
        return;
    }
    char err[512] = {0};
    NSData* project = nil;
    __block spdf_bitmap bitmap = {0, 0, 0, NULL};
    BOOL isProject = [uti isEqual:@"com.intuition.shenzhenpdf.szpaint"];
    if (isProject) {
        unsigned char* bytes = NULL;
        size_t length = 0;
        if (spdf_paint_project_bytes(_canvas, &bytes, &length, err, sizeof(err)) == SPDF_PAINT_OK)
            project = [NSData dataWithBytes:bytes length:length];
        spdf_paint_free(bytes);
    } else {
        BOOL opaque = [uti isEqual:@"public.jpeg"] || [uti isEqual:@"com.microsoft.bmp"];
        if (spdf_paint_flatten(_canvas, opaque ? 0xFFFFFFFFu : 0, &bitmap, err, sizeof(err)) != SPDF_PAINT_OK)
            bitmap.rgba = NULL;
    }
    if (!project && !bitmap.rgba) {
        if (completion) completion(SaveError(err[0] ? @(err) : @"The picture couldn't be prepared for saving."));
        return;
    }
    NSDictionary* properties = isProject ? nil : [self.pictureProperties copy];
    self.pendingWrites++;
    __weak SPDFMacAnnotateSession* weakSelf = self;
    __block NSError* failure = nil;
    void (^work)(void) = ^{
        @autoreleasepool {
            NSError* error = nil;
            NSData* data = project ?: SPDFAnnotateEncodePicture(&bitmap, uti, properties, quality, &error);
            if (!project) spdf_free_bitmap(&bitmap);
            if (!data || !SPDFAnnotateWriteFileAtomically(data, path, &error))
                failure = error ?: SaveError(@"The picture couldn't be saved.");
        }
    };
    void (^finish)(void) = ^{
        SPDFMacAnnotateSession* session = weakSelf;
        if (session) {
            session.pendingWrites--;
            session.lastWriteFailed = failure != nil;
            if (!failure && [path isEqual:session.path]) [session rememberFileStamp];
            if (!failure) [session.host annotateSession:session didWritePath:path];
        }
        if (completion) completion(failure);
    };
    if (synchronously) {
        dispatch_sync(WriteQueue(), work);
        if (!failure && [path isEqual:self.path]) spdf_paint_mark_saved(_canvas);
        finish();
        return;
    }
    if ([path isEqual:self.path] || isProject) spdf_paint_mark_saved(_canvas);
    dispatch_async(WriteQueue(), ^{
        work();
        dispatch_async(dispatch_get_main_queue(), finish);
    });
}

- (void)saveWithCompletion:(void (^)(NSError*))completion {
    [self saveSynchronously:NO completion:completion];
}

- (void)saveSynchronously:(BOOL)synchronously completion:(void (^)(NSError*))completion {
    // PDF pages are written by Fill & Sign's commit cycle (the PDF bridge), not here.
    if (self.kind == SPDFAnnotateDocumentPDF || !self.loaded || !self.dirty) {
        if (completion) completion(nil);
        return;
    }
    if (self.neverSaved || !self.writesInPlace) {
        if (completion) completion(SaveError(@"Choose where to save this picture (doc.save_as)."));
        return;
    }
    if (self.projectPath) {
        // The project file, then the flattened copy its tab shows.
        NSString* backing = [self.path copy];
        __weak SPDFMacAnnotateSession* weakSelf = self;
        [self writeTo:self.projectPath uti:@"com.intuition.shenzhenpdf.szpaint" quality:0 protect:YES
            synchronously:synchronously completion:^(NSError* error) {
              if (error) {
                  if (completion) completion(error);
                  return;
              }
              [weakSelf writeTo:backing uti:@"public.png" quality:0 protect:NO synchronously:synchronously
                     completion:completion];
            }];
        return;
    }
    BOOL backing = SPDFAnnotateIsBackingPath(self.path);
    __weak SPDFMacAnnotateSession* weakSelf = self;
    [self writeTo:self.path uti:self.format quality:0.92 protect:!backing synchronously:synchronously
       completion:^(NSError* error) {
         if (!error) [weakSelf writeSidecarNow:synchronously];
         if (completion) completion(error);
       }];
}

- (void)saveAsPath:(NSString*)path format:(NSString*)format quality:(CGFloat)quality
        completion:(void (^)(NSError*))completion {
    if (!self.loaded || !_canvas || self.kind == SPDFAnnotateDocumentPDF) {
        if (completion) completion(SaveError(@"Only pictures and canvases are saved this way."));
        return;
    }
    NSString* uti = UTIForFormat(format.length ? format : (SPDFAnnotateFormatForPath(path) ?: @"png"));
    NSString* previous = [self.path copy];
    BOOL wasNeverSaved = self.neverSaved;
    BOOL wasCopy = self.kind == SPDFAnnotateDocumentPicture && !self.writesInPlace && !self.projectPath;
    BOOL project = [uti isEqual:@"com.intuition.shenzhenpdf.szpaint"];
    __weak SPDFMacAnnotateSession* weakSelf = self;
    [self writeTo:path uti:uti quality:quality > 0 ? quality : 0.92 protect:YES synchronously:NO
       completion:^(NSError* error) {
         SPDFMacAnnotateSession* session = weakSelf;
         if (error || !session) {
             if (completion) completion(error);
             return;
         }
         NSString* shown = path;
         if (project) {
             // A project's tab shows its flattened picture, kept in <state>/Annotate/Tabs.
             shown = [SPDFAnnotateTabsFolder() stringByAppendingPathComponent:
                                                   [PathHash(path) stringByAppendingPathExtension:@"png"]];
             EnsureFolder(SPDFAnnotateTabsFolder());
             NSData* json = [NSJSONSerialization dataWithJSONObject:@{@"project": path} options:0 error:NULL];
             SPDFAnnotateWriteFileAtomically(json, [shown.stringByDeletingPathExtension
                                                       stringByAppendingPathExtension:@"json"], NULL);
             session.projectPath = path;
             session.path = shown;
             [session writeTo:shown uti:@"public.png" quality:0 protect:NO synchronously:YES completion:nil];
         } else {
             session.projectPath = nil;
             session.path = path;
             session.format = uti;
             session.writesInPlace = YES;
             session.keptCopyChanges = NO;
             spdf_paint_mark_saved(session->_canvas);
             [session writeSidecarNow:NO];
         }
         if (wasNeverSaved && ![previous isEqual:shown]) [session removeBackingFiles:previous];
         // The WebP's or RAW's changes now live in the PNG: the original opens as it is again.
         if (wasCopy && ![previous isEqual:shown]) [session discardKeptChangesForPath:previous];
         [session.host annotateSession:session didSaveAsPath:shown];
         if (completion) completion(nil);
       }];
}

- (void)removeBackingFiles:(NSString*)backing {
    if (!SPDFAnnotateIsBackingPath(backing)) return;
    NSFileManager* files = NSFileManager.defaultManager;
    [files removeItemAtPath:backing error:nil];
    [files removeItemAtPath:[backing.stringByDeletingPathExtension stringByAppendingPathExtension:@"json"] error:nil];
    NSString* sidecar = [SPDFMacAnnotateSession sidecarPathForPath:backing];
    [files removeItemAtPath:sidecar error:nil];
    [files removeItemAtPath:[sidecar.stringByDeletingPathExtension stringByAppendingPathExtension:@"json"] error:nil];
}

- (void)discardKeptChanges {
    [self.autosaveTimer invalidate];
    self.autosaveTimer = nil;
    self.keptCopyChanges = NO;
    [self discardKeptChangesForPath:self.path];
}

- (void)discardKeptChangesForPath:(NSString*)path {
    NSString* sidecar = [SPDFMacAnnotateSession sidecarPathForPath:path];
    dispatch_sync(WriteQueue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:sidecar error:nil];
        [NSFileManager.defaultManager removeItemAtPath:[sidecar.stringByDeletingPathExtension
                                                           stringByAppendingPathExtension:@"json"] error:nil];
    });
}

- (void)discardNeverSavedCanvas {
    if (!self.neverSaved) return;
    [self.autosaveTimer invalidate];
    self.autosaveTimer = nil;
    [self removeBackingFiles:self.path];
}

- (BOOL)flushForClose:(BOOL)quitting error:(NSError**)error {
    if (error) *error = nil;
    [self.autosaveTimer invalidate];
    self.autosaveTimer = nil;
    // Saves already on their way finish first: the main queue blocks they end with run in the default mode.
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (self.pendingWrites > 0 && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!self.loaded || self.kind == SPDFAnnotateDocumentPDF) return YES;
    if (self.neverSaved) {
        // Kept for next launch (quit), or the person was already asked (close).
        if (!quitting || !self.dirty) return YES;
        __block NSError* failure = nil;
        [self writeTo:self.path uti:@"public.png" quality:0 protect:NO synchronously:YES
           completion:^(NSError* e) { failure = e; }];
        [self writeSidecarNow:YES];
        if (error) *error = failure;
        return failure == nil;
    }
    if (!self.writesInPlace) {  // a WebP, RAW or animation: its layers are kept; the picture itself can't take them
        [self writeSidecarNow:YES];
        return YES;
    }
    __block NSError* failure = nil;
    [self saveSynchronously:YES completion:^(NSError* e) { failure = e; }];
    if (error) *error = failure;
    return failure == nil;
}

@end
#pragma clang diagnostic pop

// SPDFAnnotateSettings (every tool's settings) is in SPDFMacAnnotateSettings.mm.
