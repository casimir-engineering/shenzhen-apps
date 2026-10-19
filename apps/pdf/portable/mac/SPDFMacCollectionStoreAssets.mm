#import "SPDFMacCollectionStorePrivate.h"
#import "markdown/SPDFMarkdownParser.h"

static void SPDFCollectionCollectImageReferences(NSArray<SPDFMarkdownBlock*>* blocks,
                                                NSMutableOrderedSet<NSString*>* references) {
    for (SPDFMarkdownBlock* block in blocks) {
        for (SPDFMarkdownInlineRun* run in block.runs) {
            if ((run.traits & SPDFMarkdownInlineTraitImage) && run.destination.length)
                [references addObject:run.destination];
        }
        SPDFCollectionCollectImageReferences(block.children, references);
    }
}

NSDictionary* SPDFCollectionAssets(NSString* sourcePath, NSData* bytes) {
    NSString* ext = sourcePath.pathExtension.lowercaseString;
    if (![@[@"md",@"markdown",@"mdown"] containsObject:ext]) return @{@"entries":@[],@"warnings":@[]};
    // Use the reader's model so syntax examples, comments, front matter and
    // suppressed HTML cannot archive unrelated neighboring files. A nil URL
    // keeps parsing pure: no resource store or document descriptor is opened.
    NSError* parseError = nil;
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] parseData:bytes sourceURL:nil error:&parseError];
    if (!model) return @{@"entries":@[], @"warnings":@[[NSString stringWithFormat:
        @"Markdown assets could not be inspected: %@",parseError.localizedDescription ?: @"Parse failed"]]};
    NSMutableOrderedSet* references = [NSMutableOrderedSet orderedSet];
    SPDFCollectionCollectImageReferences(model.blocks, references);
    NSMutableArray* entries = [NSMutableArray array];
    NSMutableArray* warnings = [NSMutableArray array];
    NSString* base = sourcePath.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
    NSUInteger total = 0;
    for (NSString* reference in references) {
        if ([reference hasPrefix:@"#"] || [reference hasPrefix:@"data:"]) continue;
        NSURLComponents* components = [NSURLComponents componentsWithString:reference];
        if (components.scheme.length || [reference hasPrefix:@"//"]) {
            [warnings addObject:[NSString stringWithFormat:@"Network asset is not archived: %@",reference]]; continue;
        }
        NSString* relative = [[reference componentsSeparatedByString:@"#"].firstObject
                              componentsSeparatedByString:@"?"].firstObject.stringByRemovingPercentEncoding;
        if (!relative.length) continue;
        NSString* path = [[base stringByAppendingPathComponent:relative] stringByResolvingSymlinksInPath];
        // Recovered Markdown must not write beyond its private materialization tree.
        if ([relative hasPrefix:@"/"] || [relative.pathComponents containsObject:@".."] ||
            ![path hasPrefix:[base stringByAppendingString:@"/"]]) {
            [warnings addObject:[NSString stringWithFormat:@"Asset outside document folder: %@",reference]]; continue;
        }
        NSDictionary* info = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        NSUInteger size = [info[NSFileSize] unsignedIntegerValue];
        if (![info[NSFileType] isEqual:NSFileTypeRegular] || size > 16*1024*1024 ||
            total + size > 32*1024*1024 || entries.count >= 128) {
            [warnings addObject:[NSString stringWithFormat:@"Missing or over-limit asset: %@",reference]]; continue;
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
    }
    return @{@"entries":entries,@"warnings":warnings};
}
