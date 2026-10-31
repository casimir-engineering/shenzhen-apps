#import "SPDFMacCollectionPermanentDelete.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionThumbnail.h"
#import "SPDFMacMarkdownCache.h"
#import "SPDFMacStateDirectory.h"
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

NSString* SPDFPermanentDeleteBlockReason(NSString* path) {
    struct stat info = {};
    if (!path.length || lstat(path.fileSystemRepresentation, &info) != 0) return nil; // already gone
    if (!S_ISREG(info.st_mode)) return @"isn’t a single file";
    if (info.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE)) return @"is locked";
    struct statfs volume = {};
    if (statfs(path.fileSystemRepresentation, &volume) == 0 && (volume.f_flags & MNT_RDONLY)) return @"is on a read-only disk";
    // The owner asked for read-only files to be left alone, although the folder alone decides whether unlink works.
    if (access(path.fileSystemRepresentation, W_OK) != 0) return @"is read-only";
    NSString* folder = path.stringByDeletingLastPathComponent;
    struct stat parent = {};
    if (access(folder.fileSystemRepresentation, W_OK) != 0 || lstat(folder.fileSystemRepresentation, &parent) != 0 ||
        (parent.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE)) ||
        ((parent.st_mode & S_ISVTX) && info.st_uid != getuid() && parent.st_uid != getuid()))
        return @"is in a folder that can’t be changed";
    return nil;
}

NSString* SPDFPermanentDeleteTitle(NSArray<NSString*>* names) {
    if (names.count == 1) return [NSString stringWithFormat:@"Delete “%@” permanently?", names.firstObject];
    return [NSString stringWithFormat:@"Delete %lu documents permanently?", (unsigned long)names.count];
}

NSString* SPDFPermanentDeleteMessage(NSUInteger count) {
    return count == 1 ? @"This will delete permanently the file from your Mac and remove it from your Collection, with "
                        @"its history and comments. You can’t undo this."
                      : @"This will delete permanently the files from your Mac and remove them from your Collection, "
                        @"with their history and comments. You can’t undo this.";
}

NSAlert* SPDFPermanentDeleteConfirmation(NSArray<NSString*>* names) {
    NSAlert* alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = SPDFPermanentDeleteTitle(names);
    alert.informativeText = SPDFPermanentDeleteMessage(names.count);
    // NSAlert puts its first button on the right and makes it the default: here the right one deletes, and Return
    // (the default) and Escape both cancel.
    NSButton* remove = [alert addButtonWithTitle:@"Delete Permanently"];
    NSButton* cancel = [alert addButtonWithTitle:@"Cancel"];
    remove.hasDestructiveAction = YES;
    remove.keyEquivalent = @"";
    cancel.keyEquivalent = @"\r";
    return alert;
}

NSAlert* SPDFPermanentDeleteRefusal(NSArray<NSString*>* files) {
    NSMutableArray* lines = [NSMutableArray array];
    NSString* only = nil, *reasonOnly = nil;
    for (NSString* file in files) {
        NSString* reason = SPDFPermanentDeleteBlockReason(file);
        if (!reason) continue;
        only = file.lastPathComponent; reasonOnly = reason;
        [lines addObject:[NSString stringWithFormat:@"“%@” %@", only, reason]];
    }
    if (!lines.count) return nil;
    NSAlert* alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = lines.count == 1 ? [NSString stringWithFormat:@"“%@” can’t be deleted", only]
                                         : @"Some documents can’t be deleted";
    // One file: the title names it, so the text only says why.
    NSString* list = lines.count == 1 ? [@"The file " stringByAppendingString:reasonOnly] : [NSString stringWithFormat:@"%@ and %@",
        [[lines subarrayWithRange:NSMakeRange(0, lines.count - 1)] componentsJoinedByString:@", "], lines.lastObject];
    alert.informativeText = [list stringByAppendingString:@", so nothing was deleted."];
    [alert addButtonWithTitle:@"OK"];
    return alert;
}

NSAlert* SPDFPermanentDeleteFailure(NSArray<NSString*>* failures) {
    NSAlert* alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    BOOL one = failures.count == 1;
    alert.messageText = one ? @"A document wasn’t deleted" : @"Some documents weren’t deleted";
    BOOL files = NO;
    for (NSString* failure in failures) files = files || [failure hasPrefix:@"“"];
    alert.informativeText = [NSString stringWithFormat:@"%@.%@", [failures componentsJoinedByString:@"; "], !files ? @"" :
        one ? @" It’s still on your Mac and in your Collection." : @" They’re still on your Mac and in your Collection."];
    [alert addButtonWithTitle:@"OK"];
    return alert;
}

void SPDFPermanentDeleteAsk(NSWindow* window, NSArray<NSString*>* names, NSArray<NSString*>* files,
                            void (^confirmed)(void)) {
    if (!names.count) return;
    NSAlert* refusal = SPDFPermanentDeleteRefusal(files);
    if (refusal) { [refusal beginSheetModalForWindow:window completionHandler:^(NSModalResponse r) { (void)r; }]; return; }
    [SPDFPermanentDeleteConfirmation(names) beginSheetModalForWindow:window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) confirmed();
    }];
}

static BOOL Inside(NSString* path, NSString* folder) {
    return folder.length && [path hasPrefix:[folder stringByAppendingString:@"/"]];
}

NSDictionary* SPDFPermanentDeleteTargets(SPDFMacCollectionStore* store, NSArray<NSString*>* paths,
                                         NSArray<NSString*>* documentIDs) {
    NSString* root = store.rootURL.path, *resolvedRoot = root.stringByResolvingSymlinksInPath;
    NSMutableDictionary<NSString*, NSDictionary*>* documents = [NSMutableDictionary dictionary];
    NSMutableOrderedSet* files = [NSMutableOrderedSet orderedSet], *chosen = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary* names = [NSMutableDictionary dictionary];
    NSMutableSet* standard = [NSMutableSet set];
    // Once per file: Collection's "/tmp/x" and a tab's "/private/tmp/x" are the same file.
    void (^addFile)(NSString*) = ^(NSString* file) {
        if ([standard containsObject:file.stringByStandardizingPath]) return;
        [standard addObject:file.stringByStandardizingPath]; [files addObject:file];
    };
    void (^addDocument)(NSDictionary*) = ^(NSDictionary* doc) {
        documents[doc[@"id"]] = doc;
        if (SPDFCollectionOriginalAvailable(doc)) addFile(doc[@"path"]);
    };
    for (NSString* path in paths) {
        NSDictionary* doc = [store documentForPath:path] ?: [store archiveInfoForPath:path][@"document"];
        BOOL collection = Inside(path, root) || Inside(path.stringByResolvingSymlinksInPath, resolvedRoot);
        // A History copy or saved version stands for its document; its own file goes with the Collection entry.
        if (!collection) addFile(path);
        NSString* key = [doc[@"id"] length] ? doc[@"id"] : path;
        if (doc[@"id"]) addDocument(doc);
        if (!names[key]) [chosen addObject:key];
        if (!names[key]) names[key] = collection && [doc[@"path"] length] ? [doc[@"path"] lastPathComponent] : path.lastPathComponent;
    }
    NSArray* rows = documentIDs.count ? [store documents] : @[];
    for (NSString* identifier in documentIDs)
        for (NSDictionary* doc in rows) {
            if (![doc[@"id"] isEqual:identifier]) continue;
            addDocument(doc);
            if (!names[identifier]) [chosen addObject:identifier];
            if (!names[identifier]) names[identifier] = [doc[@"path"] lastPathComponent] ?: SPDFCollectionDocumentTitle(doc) ?: @"Document";
        }
    NSMutableOrderedSet* match = [NSMutableOrderedSet orderedSetWithArray:paths];
    [match unionOrderedSet:files];
    // Collection keeps standardized paths ("/tmp/x" for a tab's "/private/tmp/x"): a tab matches either form.
    for (NSString* path in match.array) [match addObject:path.stringByStandardizingPath];
    NSMutableArray* prefixes = [NSMutableArray array];
    for (NSString* identifier in documents) {
        [match addObjectsFromArray:[store editablePathsForDocument:documents[identifier]]];
        for (NSString* base in [NSOrderedSet orderedSetWithArray:@[root ?: @"", resolvedRoot ?: @""]])
            for (NSString* folder in @[@"editable", @"previews"])
                if (base.length) [prefixes addObject:[[base stringByAppendingPathComponent:folder]
                                                       stringByAppendingPathComponent:identifier]];
    }
    NSMutableArray* shown = [NSMutableArray array];
    for (NSString* key in chosen) [shown addObject:names[key]];
    return @{@"documents" : documents.allValues, @"documentIDs" : documents.allKeys, @"files" : files.array,
             @"names" : shown, @"matchPaths" : match.array, @"matchPrefixes" : prefixes};
}

BOOL SPDFPermanentDeleteMatchesTab(NSDictionary* targets, NSString* path, NSString* collectionDocumentID) {
    if (collectionDocumentID.length && [targets[@"documentIDs"] containsObject:collectionDocumentID]) return YES;
    if (!path.length) return NO;
    if ([targets[@"matchPaths"] containsObject:path] ||
        [targets[@"matchPaths"] containsObject:path.stringByStandardizingPath]) return YES;
    for (NSString* prefix in targets[@"matchPrefixes"]) if (Inside(path, prefix)) return YES;
    return NO;
}

NSSet<NSString*>* SPDFPermanentDeleteThumbnailNames(NSDictionary* document, NSInteger pages) {
    NSMutableArray* rows = [NSMutableArray array];
    for (NSDictionary* version in document[@"versions"])
        if ([version[@"id"] length]) [rows addObject:@{@"document" : document, @"version" : version}];
    // The original's pictures are named by its size and modification time: a key only while it is still there.
    if (SPDFCollectionOriginalAvailable(document)) [rows addObject:@{@"document" : document, @"version" : @{}}];
    NSMutableSet* names = [NSMutableSet set];
    for (NSDictionary* row in rows)
        for (NSInteger page = 0; page <= pages; page++)
            for (CGFloat scale = 1; scale <= 3; scale++) {
                NSString* key = SPDFCollectionThumbnailDiskKey(row, page, scale);
                if (key) [names addObject:spdf_mac_markdown_image_cache_file_name(key)];
            }
    return names;
}

static NSInteger PageCount(NSString* path) {
    NSString* extension = path.pathExtension.lowercaseString;
    if ([extension isEqual:@"pdf"]) {
        CGPDFDocumentRef pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
        size_t count = pdf ? CGPDFDocumentGetNumberOfPages(pdf) : 0;
        if (pdf) CGPDFDocumentRelease(pdf);
        if (count) return (NSInteger)MIN(count, (size_t)5000);
    }
    // A Markdown or text page count needs a layout; search results rarely point past this.
    return 400;
}

NSDictionary* SPDFPermanentDeletePerform(NSDictionary* targets, SPDFMacCollectionStore* store, NSURL* thumbnails) {
    NSArray<NSDictionary*>* documents = targets[@"documents"];
    // Named before the files go: an original's pictures are named by its size and modification time.
    NSArray* present = thumbnails ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:thumbnails.path error:nil] : nil;
    NSMutableDictionary* pictures = [NSMutableDictionary dictionary];
    for (NSDictionary* doc in documents) {
        if (!present.count) break;
        NSMutableSet* names = [SPDFPermanentDeleteThumbnailNames(doc, PageCount(doc[@"path"] ?: @"")) mutableCopy];
        [names intersectSet:[NSSet setWithArray:present]];
        pictures[doc[@"id"]] = names;
    }
    NSMutableArray* failures = [NSMutableArray array];
    NSMutableSet* kept = [NSMutableSet set], *keptFiles = [NSMutableSet set];
    NSString* editedCopies = [SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"Edited Copies"];
    for (NSString* file in targets[@"files"]) {
        struct stat info = {};
        if (lstat(file.fileSystemRepresentation, &info) != 0) continue;
        NSString* reason = SPDFPermanentDeleteBlockReason(file);
        // unlink, never a recursive removal: only the regular file chosen goes. Another app that has it open keeps
        // reading its open copy until it closes it; nothing here waits for that.
        if (reason || unlink(file.fileSystemRepresentation) != 0) {
            [failures addObject:[NSString stringWithFormat:@"“%@” %@", file.lastPathComponent,
                                 reason ?: [NSString stringWithFormat:@"couldn’t be deleted (%s)", strerror(errno)]]];
            [keptFiles addObject:file];
            for (NSDictionary* doc in documents) if ([doc[@"path"] isEqual:file]) [kept addObject:doc[@"id"]];
            continue;
        }
        // An Edited Copy lives alone in a folder of its own: that folder goes too once empty (rmdir refuses otherwise).
        NSString* folder = file.stringByDeletingLastPathComponent;
        if ([folder.stringByDeletingLastPathComponent isEqual:editedCopies]) rmdir(folder.fileSystemRepresentation);
    }
    NSMutableArray* purge = [NSMutableArray array];
    for (NSDictionary* doc in documents) if (![kept containsObject:doc[@"id"]]) [purge addObject:doc[@"id"]];
    NSError* error = nil;
    if (purge.count && ![store purgeDocumentIDs:purge error:&error]) {
        // The files are gone already; their entries stay in the list, where Collection shows them as missing.
        [failures addObject:[NSString stringWithFormat:@"Collection couldn’t forget %@ (%@)",
            purge.count == 1 ? @"it" : @"them", error.localizedDescription ?: @"unknown error"]];
        [kept addObjectsFromArray:purge];
    }
    else
        for (NSString* identifier in purge)
            for (NSString* name in pictures[identifier])
                unlink([thumbnails.path stringByAppendingPathComponent:name].fileSystemRepresentation);
    // What went, for closing tabs: a kept document's tabs, History copies and saved versions stay.
    NSMutableArray* prefixes = [NSMutableArray array], *paths = [NSMutableArray array];
    for (NSString* prefix in targets[@"matchPrefixes"])
        if (![kept containsObject:prefix.lastPathComponent]) [prefixes addObject:prefix];
    for (NSString* path in targets[@"matchPaths"]) {
        BOOL keptCopy = NO;
        for (NSString* prefix in targets[@"matchPrefixes"])
            keptCopy = keptCopy || ([kept containsObject:prefix.lastPathComponent] && Inside(path, prefix));
        if (![keptFiles containsObject:path] && !keptCopy) [paths addObject:path];
    }
    NSMutableArray* removedIDs = [NSMutableArray array];
    for (NSString* identifier in targets[@"documentIDs"]) if (![kept containsObject:identifier]) [removedIDs addObject:identifier];
    return @{@"removed" : @{@"documentIDs" : removedIDs, @"matchPaths" : paths, @"matchPrefixes" : prefixes},
             @"failures" : failures};
}
