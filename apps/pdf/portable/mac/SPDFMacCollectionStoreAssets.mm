#import "SPDFMacCollectionStorePrivate.h"
#import "markdown/SPDFMarkdownParser.h"

NSString* const SPDFCollectionAssetsProfile = @"pictures-links-comments-1";

BOOL SPDFCollectionIsMarkdownPath(NSString* path) {
    return [@[@"md",@"markdown",@"mdown"] containsObject:path.pathExtension.lowercaseString];
}

NSString* SPDFCollectionCommentsFileName(NSString* documentPath) {
    NSString* title = documentPath.lastPathComponent.stringByDeletingPathExtension;
    return [NSString stringWithFormat:@"%@ - comments.md", title.length ? title : @"Document"];
}

// Pictures, and separately the local files the document links to (another document, a PDF), in reading order.
static void SPDFCollectionCollectReferences(NSArray<SPDFMarkdownBlock*>* blocks,
                                            NSMutableOrderedSet<NSString*>* images,
                                            NSMutableOrderedSet<NSString*>* links) {
    for (SPDFMarkdownBlock* block in blocks) {
        for (SPDFMarkdownInlineRun* run in block.runs) {
            if (!run.destination.length) continue;
            if (run.traits & SPDFMarkdownInlineTraitImage) [images addObject:run.destination];
            else if (run.traits & SPDFMarkdownInlineTraitLink) [links addObject:run.destination];
        }
        SPDFCollectionCollectReferences(block.children, images, links);
    }
}

NSDictionary* SPDFCollectionAssets(NSString* sourcePath, NSData* bytes) {
    if (!SPDFCollectionIsMarkdownPath(sourcePath)) return @{@"entries":@[],@"warnings":@[]};
    // Use the reader's model so syntax examples, comments, front matter and
    // suppressed HTML cannot archive unrelated neighboring files. A nil URL
    // keeps parsing pure: no resource store or document descriptor is opened.
    NSError* parseError = nil;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseData:bytes sourceURL:nil error:&parseError];
    if (!model) return @{@"entries":@[], @"warnings":@[[NSString stringWithFormat:
        @"Markdown assets could not be inspected: %@",parseError.localizedDescription ?: @"Parse failed"]]};
    NSMutableOrderedSet* references = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet* links = [NSMutableOrderedSet orderedSet];
    SPDFCollectionCollectReferences(model.blocks, references, links);
    // Its comments, as a file kept beside it, then the files it links to: kept with it when they are there and fit,
    // and never warned about otherwise (a link may name a page, a folder or something the person never had).
    NSString* comments = SPDFCollectionCommentsFileName(sourcePath);
    NSMutableSet* optional = [NSMutableSet setWithObject:comments];
    [references addObject:comments];
    for (NSString* link in links) if (![references containsObject:link]) { [references addObject:link]; [optional addObject:link]; }
    NSMutableArray* entries = [NSMutableArray array];
    NSMutableArray* warnings = [NSMutableArray array];
    NSMutableSet* kept = [NSMutableSet setWithObject:sourcePath.lastPathComponent.lowercaseString];
    NSString* base = sourcePath.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
    NSUInteger total = 0;
    for (NSString* reference in references) {
        BOOL quiet = [optional containsObject:reference];
        if ([reference hasPrefix:@"#"] || [reference hasPrefix:@"data:"]) continue;
        NSString* relative = reference;
        if (reference != comments) {
            NSURLComponents* components = [NSURLComponents componentsWithString:reference];
            if (components.scheme.length || [reference hasPrefix:@"//"]) {
                if (!quiet) [warnings addObject:[NSString stringWithFormat:@"Network asset is not archived: %@",reference]];
                continue;
            }
            relative = [[reference componentsSeparatedByString:@"#"].firstObject
                        componentsSeparatedByString:@"?"].firstObject.stringByRemovingPercentEncoding;
        }
        if (!relative.length || [kept containsObject:relative.lowercaseString]) continue;
        NSString* path = [[base stringByAppendingPathComponent:relative] stringByResolvingSymlinksInPath];
        // Recovered Markdown must not write beyond its private materialization tree.
        if ([relative hasPrefix:@"/"] || [relative.pathComponents containsObject:@".."] ||
            ![path hasPrefix:[base stringByAppendingString:@"/"]]) {
            if (!quiet) [warnings addObject:[NSString stringWithFormat:@"Asset outside document folder: %@",reference]];
            continue;
        }
        NSDictionary* info = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        NSUInteger size = [info[NSFileSize] unsignedIntegerValue];
        if (![info[NSFileType] isEqual:NSFileTypeRegular] || size > 16*1024*1024 ||
            total + size > 32*1024*1024 || entries.count >= 128) {
            if (!quiet) [warnings addObject:[NSString stringWithFormat:@"Missing or over-limit asset: %@",reference]];
            continue;
        }
        NSDictionary* capturedFingerprint=SPDFCollectionFingerprint(path);
        NSData* data = [NSData dataWithContentsOfFile:path];
        NSDictionary* after = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (!data || ![info isEqual:after] || ![capturedFingerprint isEqual:SPDFCollectionFingerprint(path)]) {
            [warnings addObject:[NSString stringWithFormat:@"Asset changed while archiving: %@",reference]]; continue;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
        NSMutableString* hash = [NSMutableString string];
        for (int i=0;i<CC_SHA256_DIGEST_LENGTH;++i) [hash appendFormat:@"%02x",digest[i]];
        [entries addObject:@{@"relativePath":relative,@"hash":hash,@"size":@(data.length),@"data":data,@"captureFingerprint":capturedFingerprint}]; total += data.length;
        [kept addObject:relative.lowercaseString];
    }
    return @{@"entries":entries,@"warnings":warnings};
}
