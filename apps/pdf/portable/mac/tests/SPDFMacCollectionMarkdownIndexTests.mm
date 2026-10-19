#import <Foundation/Foundation.h>
#import "SPDFMacCollectionStorePrivate.h"
#import "SPDFMacCollectionCompare.h"
#import "SPDFMacPaletteTextSearch.h"
int main(void) {
    @autoreleasepool {
        if(!NSClassFromString(@"SPDFMarkdownDocument")) { fprintf(stderr,"FAIL Markdown engine must be linked\n"); return 1; }
        NSString* folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* path=[folder stringByAppendingPathComponent:@"Paged.md"];
        NSString* text=@"---\npaper-size: A5\n---\n# First\nFirst page text.\n\n<!-- pagebreak -->\n\n# Second\nCanonical target phrase.\n";
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:
            [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"Collection"]]];
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        NSError* error; NSDictionary* doc=[store capturePath:path reason:@"Opened" error:&error];
        NSArray* matches=[store search:@"Canonical target" titlesOnly:NO excludingPaths:NSSet.set limit:5];
        BOOL ok=doc && matches.count==1 && [matches.firstObject[@"page"] integerValue]==2;
        if(!ok)fprintf(stderr,"FAIL archived Markdown canonical page mapping: %s\n",(error ?: matches).description.UTF8String);
        // These inputs remain literal source in every retained and live search path.
        for (NSString* extension in @[@"html",@"py",@"txt",@"js",@"yaml"]) {
            NSString* source=[folder stringByAppendingPathComponent:[@"Source" stringByAppendingPathExtension:extension]];
            NSString* literal=@"<h1>Literal source</h1>\n![asset](missing.png)\nconst needle = true;\n";
            [literal writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary* captured=[store capturePath:source reason:@"Opened" error:nil];
            NSDictionary* version=[captured[@"versions"] lastObject];
            NSDictionary* index=[store textIndexForVersion:version];
            BOOL sourceOK=captured && [version[@"assets"] count]==0 && [version[@"assetWarnings"] count]==0 &&
                [index[@"textPages"] count]>0 && [index[@"textPages"][0][@"page"] integerValue]==1 &&
                [index[@"textPages"][0][@"text"] containsString:@"<h1>Literal source</h1>"];
            NSDictionary* candidate=@{@"path":source,@"title":source.lastPathComponent};
            NSProgress* progress=[NSProgress progressWithTotalUnitCount:1];
            NSArray* hits=SPDFPaletteOpenTextMatches(@[candidate],@"needle",progress);
            sourceOK &= hits.count==1 && [hits[0][@"page"] integerValue]==0 &&
                [hits[0][@"subtitle"] containsString:@"needle"];
            PDFDocument* preview=SPDFCollectionLoadPreviewDocument([NSURL fileURLWithPath:source],progress,nil);
            sourceOK &= preview.pageCount>0 && [preview.string containsString:@"<h1>Literal source</h1>"];
            if(!sourceOK)fprintf(stderr,"FAIL literal source Collection/palette/preview route: %s\n",extension.UTF8String);
            ok &= sourceOK;
            NSURL* indexURL=[[store.rootURL URLByAppendingPathComponent:@"indexes"] URLByAppendingPathComponent:version[@"indexFile"]];
            [store transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
                NSMutableDictionary* legacy=[manifest[@"documents"][captured[@"id"]][@"versions"] lastObject];
                if ([extension isEqual:@"html"]) [legacy removeObjectForKey:@"sourceIndexProfile"];
                else legacy[@"sourceIndexProfile"]=@"source-v1-raw";
                return SPDFCollectionAtomicData([NSJSONSerialization dataWithJSONObject:@{@"textPages":@[@{@"page":@0,@"text":literal}]}
                    options:0 error:failure],indexURL,0400,failure);
            } error:nil];
            NSDictionary* reopened=[store capturePath:source reason:@"Opened" error:nil];
            NSDictionary* upgraded=[reopened[@"versions"] lastObject];
            BOOL migrated=[reopened[@"versions"] count]==1 && [upgraded[@"id"] isEqual:version[@"id"]] &&
                [upgraded[@"hash"] isEqual:version[@"hash"]] &&
                [upgraded[@"sourceIndexProfile"] isEqual:@"source-v1-rendered"] &&
                [[store textIndexForVersion:upgraded][@"textPages"][0][@"page"] integerValue]==1;
            NSDictionary* stamp=SPDFCollectionFingerprint(indexURL.path);
            [store capturePath:source reason:@"Opened" error:nil];
            migrated &= [stamp isEqual:SPDFCollectionFingerprint(indexURL.path)];
            if(!migrated)fprintf(stderr,"FAIL lazy source index upgrade: %s\n",extension.UTF8String);
            ok &= migrated;
        }
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
        if(ok)printf("SPDFMacCollectionMarkdownIndexTests passed\n"); return ok?0:1;
    }
}
