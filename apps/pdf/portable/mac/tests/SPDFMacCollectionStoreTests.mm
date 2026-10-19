#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import "SPDFMacCollectionStore.h"
static int failures;
static void Expect(NSString* name, BOOL success) {
    if (!success) { fprintf(stderr,"FAIL %s\n",name.UTF8String); ++failures; }
}
static void Write(NSString* path, NSString* contents) {
    NSError* error;
    BOOL ok=[contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    Expect([NSString stringWithFormat:@"write %@: %@",path,error ?: @""],ok);
}
static NSDictionary* Capture(SPDFMacCollectionStore* store,NSString* path,NSString* reason) {
    NSError* error; NSString* continuation=nil;
    if ([@[@"Saved annotation",@"Retry",@"External change",@"After relocation"] containsObject:reason])
        continuation=[store documentForPath:path][@"id"];
    NSDictionary* row=[store capturePath:path reason:reason continuingDocumentID:continuation error:&error];
    Expect([NSString stringWithFormat:@"capture %@: %@",path,error ?: @""],row!=nil); return row;
}
#include "SPDFMacCollectionRelinkChecks.h"
#include "SPDFMacCollectionHistoryDeletionChecks.h"
#include "SPDFMacCollectionEditableChecks.h"

int main(int argc,const char* argv[]) {
    @autoreleasepool {
        if(argc==4 && strcmp(argv[1],"--child")==0) {
            SPDFMacCollectionStore* s=[[SPDFMacCollectionStore alloc] initWithRootURL:[NSURL fileURLWithPath:@(argv[2])]];
            return [s capturePath:@(argv[3]) reason:@"Other window" error:nil] ? 0 : 1;
        }
        CheckAutomaticRelink();
        CheckHistoryDeletion();
        CheckEditableCollection();
        NSString* sandbox=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:sandbox withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL* root=[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Collection"]];
        SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
        NSString* path=[sandbox stringByAppendingPathComponent:@"Drawing.md"];
        Write(path,@"# Drawing\nOriginal supplier dimensions.");
        Expect(@"construction is lazy",![NSFileManager.defaultManager fileExistsAtPath:root.path]);
        Expect(@"unset has no consent",[[store settings][@"choice"] isEqual:@"unset"] && !store.isEnabled);
        [store documents]; [store search:@"drawing" titlesOnly:YES excludingPaths:NSSet.set limit:5];
        [store capturePath:path reason:@"Opened" completion:nil];
        Expect(@"reads and declined capture create no archive",![NSFileManager.defaultManager fileExistsAtPath:root.path]);
        Expect(@"off edit gate does no archive work",[store ensureProtectedPath:path reason:@"Edit" error:nil]);
        Expect(@"off gate remains lazy",![NSFileManager.defaultManager fileExistsAtPath:root.path]);
        Expect(@"enable persisted",[store updateSettings:@{@"choice":@"enabled"} error:nil]);
        NSDictionary* doc=Capture(store,path,@"First opened"); NSString* docID=doc[@"id"];
        NSDictionary* first=[store versionsForDocumentID:docID].firstObject;
        Expect(@"first capture complete",[first[@"size"] integerValue]>0 && [first[@"hash"] length]==64);
        NSString* manifestText=[NSString stringWithContentsOfURL:[root URLByAppendingPathComponent:@"manifest.json"]
                                           encoding:NSUTF8StringEncoding error:nil];
        Expect(@"document text is absent from the lightweight manifest",![manifestText containsString:@"Original supplier"] && first[@"indexFile"]);
        unsigned long long initialSize=store.storageUsedBytes;
        Capture(store,path,@"Opened again");
        Expect(@"unchanged source does not create versions",[store versionsForDocumentID:docID].count==1);
        NSArray* protectedVersionsBefore=[store versionsForDocumentID:docID];
        NSString* epochBefore=[store documentForPath:path][@"protectionEpoch"];
        for(NSUInteger pass=0;pass<10;++pass)
            Expect(@"same revision is durable before edit",[store ensureProtectedPath:path reason:@"Before annotation" error:nil]);
        Expect(@"unchanged edit gates only renew cross-window protection, without duplicate copies",
               [[store versionsForDocumentID:docID] isEqual:protectedVersionsBefore] && store.storageUsedBytes==initialSize &&
               [[store documentForPath:path][@"protectionEpoch"] length] && ![[store documentForPath:path][@"protectionEpoch"] isEqual:epochBefore]);
        Write(path,@"# Drawing\nChanged supplier dimensions. Added note.");
        Capture(store,path,@"Saved annotation");
        Expect(@"app edit preserves original and new revision",[store versionsForDocumentID:docID].count==2);
        NSURL* archived=[store materializeVersionID:first[@"id"] documentID:docID error:nil];
        Expect(@"original unchanged bytes in archive",[[NSString stringWithContentsOfURL:archived encoding:NSUTF8StringEncoding error:nil]
               containsString:@"Original supplier"]);
        struct stat st={}; lstat(archived.fileSystemRepresentation,&st);
        Expect(@"preview has no write permission",(st.st_mode & 0222)==0);
        Expect(@"archive guard denies writes even if collection disabled",![store ensureProtectedPath:archived.path reason:@"Edit" error:nil]);
        NSString* twin=[sandbox stringByAppendingPathComponent:@"Twin.md"];
        Write(twin,@"# Drawing\nOriginal supplier dimensions.");
        NSDictionary* twinDoc=Capture(store,twin,@"First opened");
        Expect(@"identical separate paths retain independent identity",![twinDoc[@"id"] isEqual:docID]);
        Expect(@"shared original bytes deduplicate",store.storageUsedBytes<initialSize*3);
        Expect(@"title matching case insensitive",[store search:@"DRAWING" titlesOnly:YES excludingPaths:NSSet.set limit:5].count==1);
        Expect(@"exclude open source from title results",[store search:@"Drawing" titlesOnly:YES excludingPaths:[NSSet setWithObject:path] limit:5].count==0);
        Expect(@"content finds latest revision",[store search:@"Added note" titlesOnly:NO excludingPaths:NSSet.set limit:5].count==1);
        Expect(@"content does not expose old deleted words",[store search:@"Original supplier" titlesOnly:NO excludingPaths:NSSet.set limit:5].count==1);
        [store setKeep:YES versionID:first[@"id"] documentID:docID error:nil];
        SPDFMacCollectionStore* relaunched=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
        Expect(@"choice and keep survive new process store",relaunched.isEnabled &&
               [[relaunched versionsForDocumentID:docID].firstObject[@"keep"] boolValue]);
        [store setExcluded:YES path:twin error:nil]; Write(twin,@"Do not archive this revision");
        Expect(@"excluded revision is never retained",![store capturePath:twin reason:@"Edit" error:nil] &&
               [store ensureProtectedPath:twin reason:@"Edit" error:nil]);
        [store deleteDocumentID:twinDoc[@"id"] versionID:nil error:nil];
        Expect(@"deletion preserves exclusion preference",[[store documentForPath:twin][@"excluded"] boolValue]);
        Expect(@"delete never deletes original",[NSFileManager.defaultManager fileExistsAtPath:twin]);
        Expect(@"shared object survives independent history deletion",[store materializeVersionID:first[@"id"] documentID:docID error:nil]!=nil);
        [store updateSettings:@{@"storageLimitBytes":@1} error:nil]; Write(path,@"Exceeds storage quota");
        NSError* quotaError; Expect(@"quota blocks edit without deleting history",![store ensureProtectedPath:path reason:@"Edit" continuingDocumentID:docID error:&quotaError] && quotaError);
        Expect(@"failure state is visible",[[store documentForPath:path][@"status"] isEqual:@"Capture failed"]);
        Expect(@"quota retains prior versions",[store versionsForDocumentID:docID].count==2);
        [store updateSettings:@{@"storageLimitBytes":@0} error:nil]; Capture(store,path,@"Retry");
        NSString* move=[sandbox stringByAppendingPathComponent:@"Moved.md"];
        [NSFileManager.defaultManager moveItemAtPath:path toPath:move error:nil];
        NSDictionary* moved=Capture(store,move,@"Moved original");
        Expect(@"verified inode move keeps history",[moved[@"id"] isEqual:docID]);
        Expect(@"old location remains searchable",[store documentForPath:path]!=nil);
        Write(path,@"An unrelated document now occupies the former location.");
        NSDictionary* reused=Capture(store,path,@"First opened");
        Expect(@"reused historical alias starts a separate history",![reused[@"id"] isEqual:docID]);
        Expect(@"exact current path wins over old alias",[[store documentForPath:path][@"id"] isEqual:reused[@"id"]]);
        // Two different copies of the exact newest revision are sorted by mtime, oldest first.
        NSString* match1=[sandbox stringByAppendingPathComponent:@"Older.md"];
        NSString* match2=[sandbox stringByAppendingPathComponent:@"Newer.md"];
        Write(match1,@"Exceeds storage quota"); Write(match2,@"Exceeds storage quota");
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:10]} ofItemAtPath:match1 error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:20]} ofItemAtPath:match2 error:nil];
        NSArray* located=[store locateCandidatesForDocumentID:docID roots:@[[NSURL fileURLWithPath:sandbox]] cancelled:^BOOL{return NO;} error:nil];
        Expect(@"locate hashes exact full bytes and sorts old to new",located.count==3 && [[located[0][@"path"] stringByResolvingSymlinksInPath] isEqual:match1.stringByResolvingSymlinksInPath] && [[located[1][@"path"] stringByResolvingSymlinksInPath] isEqual:match2.stringByResolvingSymlinksInPath]);
        Expect(@"manual mismatch requires confirmation",![store linkDocumentID:docID toPath:twin allowMismatch:NO error:nil]);
        Expect(@"exact relink succeeds",[store linkDocumentID:docID toPath:match1 allowMismatch:NO error:nil]);
        NSUInteger historyCount=[store versionsForDocumentID:docID].count;
        Expect(@"Save As rebases the existing history",[store rebaseDocumentID:docID toPath:match2 forgettingPath:match1 error:nil]);
        Expect(@"old read-only source is forgotten",[store documentForPath:match1]==nil);
        Expect(@"new source retains history identity and all backups",[[store documentForPath:match2][@"id"] isEqual:docID] && [store versionsForDocumentID:docID].count==historyCount);
        Expect(@"failed rebase keeps the live binding",![store rebaseDocumentID:docID toPath:[sandbox stringByAppendingPathComponent:@"absent.pdf"] forgettingPath:match2 error:nil] && [[store documentForPath:match2][@"id"] isEqual:docID]);
        // Linked asset-only edits create a version even when Markdown source hash is unchanged.
        NSString* image=[sandbox stringByAppendingPathComponent:@"figure.svg"];
        Write(image,@"<svg>old</svg>"); NSString* assetDoc=[sandbox stringByAppendingPathComponent:@"Assets.md"];
        Write(assetDoc,@"# Illustrated\n![Figure](figure.svg)\n![Remote](https://example.org/a.png)\n![Missing](absent.png)");
        NSDictionary* assetRow=Capture(store,assetDoc,@"Opened"); NSDictionary* assetVersion=[store versionsForDocumentID:assetRow[@"id"]].lastObject;
        Expect(@"bounded local assets archived, remote never fetched",[assetVersion[@"assets"] count]==1 && [assetVersion[@"assetWarnings"] count]==2);
        Write(image,@"<svg>new</svg>"); Capture(store,assetDoc,@"External change");
        Expect(@"asset-only changes make a revision",[store versionsForDocumentID:assetRow[@"id"]].count==2);
        NSURL* assetPreview=[store materializeVersionID:assetVersion[@"id"] documentID:assetRow[@"id"] error:nil];
        NSString* restoredAsset=[assetPreview.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:@"figure.svg"];
        Expect(@"preview reconstructs old relative asset",[[NSString stringWithContentsOfFile:restoredAsset encoding:NSUTF8StringEncoding error:nil] isEqual:@"<svg>old</svg>"]);
        NSDictionary* archiveInfo=[[[SPDFMacCollectionStore alloc] initWithRootURL:root] archiveInfoForPath:assetPreview.path];
        Expect(@"archived tab provenance resolves after relaunch",[archiveInfo[@"document"][@"id"] isEqual:assetRow[@"id"]] &&
               [archiveInfo[@"version"][@"id"] isEqual:assetVersion[@"id"]]);
        NSString* exportDir=[sandbox stringByAppendingPathComponent:@"Export"];
        [NSFileManager.defaultManager createDirectoryAtPath:exportDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* exportDoc=[exportDir stringByAppendingPathComponent:@"Saved.md"];
        NSString* exportAsset=[exportDir stringByAppendingPathComponent:@"figure.svg"];
        Write(exportDoc,@"existing document must survive failed export"); Write(exportAsset,@"existing different asset");
        Expect(@"asset conflict fails before document overwrite",![store exportVersionID:assetVersion[@"id"] documentID:assetRow[@"id"]
                  toURL:[NSURL fileURLWithPath:exportDoc] error:nil]);
        Expect(@"failed export keeps prior document intact",[[NSString stringWithContentsOfFile:exportDoc encoding:NSUTF8StringEncoding error:nil]
               isEqual:@"existing document must survive failed export"]);
        Expect(@"failed export keeps prior asset intact",[[NSString stringWithContentsOfFile:exportAsset encoding:NSUTF8StringEncoding error:nil]
               isEqual:@"existing different asset"]);
        // Concurrent independent processes are the actual macOS multi-window storage model.
        NSMutableArray* tasks=[NSMutableArray array];
        for(int i=0;i<4;++i) {
            NSString* child=[sandbox stringByAppendingPathComponent:[NSString stringWithFormat:@"Window%d.md",i]];
            Write(child,[NSString stringWithFormat:@"Concurrent document %d",i]);
            NSTask* task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:@(argv[0])];
            task.arguments=@[@"--child",root.path,child]; [task launchAndReturnError:nil]; [tasks addObject:task];
        }
        for(NSTask* task in tasks) { [task waitUntilExit]; Expect(@"independent window capture succeeds",task.terminationStatus==0); }
        Expect(@"concurrent commits lose no document",[store search:@"Window" titlesOnly:YES excludingPaths:NSSet.set limit:0].count==4);
        // Index corruption cannot reset history or pretend an edit is protected.
        NSURL* manifest=[root URLByAppendingPathComponent:@"manifest.json"];
        NSData* saved=[NSData dataWithContentsOfURL:manifest]; [@"broken" writeToURL:manifest atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Expect(@"corrupt manifest cannot bypass edit protection",![store ensureProtectedPath:match1 reason:@"Edit" error:nil]);
        Expect(@"corrupt manifest is not replaced",![store updateSettings:@{@"choice":@"enabled"} error:nil]);
        Expect(@"corrupt bytes stay intact",[[NSString stringWithContentsOfURL:manifest encoding:NSUTF8StringEncoding error:nil] isEqual:@"broken"]);
        [saved writeToURL:manifest atomically:YES];
        [store updateSettings:@{@"choice":@"disabled"} error:nil];
        NSUInteger count=store.documents.count; [store importRecentPaths:@[twin]];
        Expect(@"turn off retains search and history",!store.isEnabled && store.documents.count==count &&
               [store search:@"Window" titlesOnly:YES excludingPaths:NSSet.set limit:5].count==4);
        NSURL* relocated=[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"MovedCollection"]];
        // Repro: old builds left both indexes and thumbnails behind after moving.
        NSString* thumbnail=[root.path stringByAppendingPathComponent:@"thumbnails/fixture.png"];
        [NSFileManager.defaultManager createDirectoryAtPath:thumbnail.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        Write(thumbnail,@"thumbnail fixture bytes");
        NSArray* indexes=[NSFileManager.defaultManager contentsOfDirectoryAtPath:[root.path stringByAppendingPathComponent:@"indexes"] error:nil];
        NSString* stagedFailure=[root.path stringByAppendingPathComponent:@"cannot-copy.sock"];
        // An unsupported special file forces a copy failure before the switch.
        mkfifo(stagedFailure.fileSystemRepresentation,0600);
        NSError* failedMove=nil;
        Expect(@"failed staged move leaves original active",![store relocateToURL:relocated error:&failedMove] && [store.rootURL.path isEqual:root.path]);
        Expect(@"failed staged move rolls back destination",![NSFileManager.defaultManager fileExistsAtPath:relocated.path]);
        [NSFileManager.defaultManager removeItemAtPath:stagedFailure error:nil];
        NSError* moveError;
        BOOL didMove=[store relocateToURL:relocated error:&moveError];
        Expect([NSString stringWithFormat:@"relocation succeeds: %@",moveError ?: @""],didMove);
        NSSet* routing=[NSSet setWithArray:[NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:nil]];
        Expect(@"old location retains only tiny routing metadata and compatibility links",[routing isEqualToSet:
            [NSSet setWithArray:@[@"collection.lock",@"redirect.json",@"previews",@"editable"]]]);
        struct stat previewLink={},editableLink={};
        Expect(@"legacy paths are symlinks rather than duplicated document trees",lstat([root.path stringByAppendingPathComponent:@"previews"].fileSystemRepresentation,&previewLink)==0 && S_ISLNK(previewLink.st_mode) &&
            lstat([root.path stringByAppendingPathComponent:@"editable"].fileSystemRepresentation,&editableLink)==0 && S_ISLNK(editableLink.st_mode));
        Expect(@"thumbnail bytes move to new root only",[[NSString stringWithContentsOfFile:[relocated.path stringByAppendingPathComponent:@"thumbnails/fixture.png"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"thumbnail fixture bytes"] &&
            ![NSFileManager.defaultManager fileExistsAtPath:thumbnail]);
        Expect(@"text indexes move to new root only",indexes.count && ![NSFileManager.defaultManager fileExistsAtPath:[root.path stringByAppendingPathComponent:@"indexes"]] &&
            [[NSFileManager.defaultManager contentsOfDirectoryAtPath:[relocated.path stringByAppendingPathComponent:@"indexes"] error:nil] count]==indexes.count);
        NSString* staleIndex=[root.path stringByAppendingPathComponent:@"indexes/leftover.json"];
        [NSFileManager.defaultManager createDirectoryAtPath:staleIndex.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        Write(staleIndex,@"leftover from an older app build");
        Expect(@"selecting current destination finishes old payload cleanup",[store relocateToURL:relocated error:nil] &&
            ![NSFileManager.defaultManager fileExistsAtPath:staleIndex] && [store documents].count==count);
        NSURL* legacyEditable=[root URLByAppendingPathComponent:@"editable"];
        [NSFileManager.defaultManager removeItemAtURL:legacyEditable error:nil];
        [NSFileManager.defaultManager createDirectoryAtURL:legacyEditable withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* legacyEdit=[legacyEditable.path stringByAppendingPathComponent:@"late-edit.md"];
        Write(legacyEdit,@"Newer legacy edit must survive retry");
        NSError* legacyCleanupError=nil;
        Expect(@"redirect cleanup refuses to delete a real legacy editable tree",![store relocateToURL:relocated error:&legacyCleanupError] &&
            [legacyCleanupError.localizedDescription containsString:@"newer edits"] &&
            [[NSString stringWithContentsOfFile:legacyEdit encoding:NSUTF8StringEncoding error:nil] isEqual:@"Newer legacy edit must survive retry"]);
        [NSFileManager.defaultManager removeItemAtURL:legacyEditable error:nil];
        [NSFileManager.defaultManager createSymbolicLinkAtURL:legacyEditable withDestinationURL:[relocated URLByAppendingPathComponent:@"editable"] error:nil];
        Expect(@"other windows follow durable relocation",[relaunched.rootURL.path isEqual:relocated.path]);
        Expect(@"relocation retains history and choice",[relaunched versionsForDocumentID:docID].count==3 && !relaunched.isEnabled);
        Expect(@"old preview path survives relocation",[NSFileManager.defaultManager fileExistsAtPath:assetPreview.path]);
        Expect(@"archive provenance follows relocated legacy preview",[store archiveInfoForPath:assetPreview.path]!=nil);
        [relaunched updateSettings:@{@"choice":@"enabled"} error:nil];
        Capture(relaunched,assetDoc,@"After relocation");
        Expect(@"relocation captures into new root",[[store documentForPath:assetDoc][@"versions"] count]==2);
        Expect(@"relocation excludes occupied destination",![store relocateToURL:[NSURL fileURLWithPath:sandbox] error:nil]);
        [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
        if(!failures) printf("SPDFMacCollectionStoreTests passed\n"); return failures ? 1 : 0;
    }
}
