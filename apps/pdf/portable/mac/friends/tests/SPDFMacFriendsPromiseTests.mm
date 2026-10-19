// Dropped file promises (portable/friends/mac/SZFriendsDrops.m, SZFriendsPromiseCopies.m), the parts a headless test
// can reach: an in-process promise is never fulfilled without a real drag, so the files a source would write are
// written here directly.
//
// The security review: a sandboxed drag source, which cannot read outside its container, could write report.pdf as a
// symlink to ~/Documents/tax.pdf into the folder it was given, and the unsandboxed reader would send tax.pdf. And the
// folder was never removed, so copies of every sent document stayed in the temporary folder. The wave-3 re-check: a
// file checked at the drop was still read by path later (up to an hour for a composer chip), so the source could swap
// it for that symlink after the check.

#import <AppKit/AppKit.h>
#import "mac/SZFriendsDrops.h"
#import "mac/SZFriendsPromiseCopies.h"
#import "SPDFMacFriendsTestSupport.h"
#include <sys/stat.h>

static NSURL* Write(NSURL* folder, NSString* name) {
    NSURL* url = [folder URLByAppendingPathComponent:name];
    [[@"bytes" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES];
    return url;
}

static NSString* Text(NSURL* url) {
    return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
}

static NSInteger Mode(NSURL* url) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil][NSFilePosixPermissions]
        integerValue];
}

static BOOL Exists(NSURL* url) { return [NSFileManager.defaultManager fileExistsAtPath:url.path]; }

// What the source can do after the check: put a symlink to a file it could never read where its file was.
static void SwapForLink(NSURL* file, NSString* target) {
    unlink(file.fileSystemRepresentation);
    symlink(target.fileSystemRepresentation, file.fileSystemRepresentation);
}

static void CheckChecks(NSString* base) {
    NSURL* folder = [SZFriendsDrops promiseFolderInDirectory:base];
    Expect(folder && [folder.path hasPrefix:[base stringByAppendingPathComponent:@"Shenzhen Friends drops/"]] &&
           Mode(folder) == 0700, @"promise folder %@ %ld", folder, (long)Mode(folder));

    NSURL* report = Write(folder, @"report.pdf");
    BOOL refusedFolder = YES;
    NSArray<SZFriendsAttachableItem*>* items = [SZFriendsDrops itemsForPromisedFiles:@[report] inFolder:folder
                                                                       refusedFolder:&refusedFolder];
    Expect(items.count == 1 && [items[0].title isEqual:@"report.pdf"] && !refusedFolder,
           @"a plain promised file must be sent: %@", items);

    // A symlink to a file the source could not read itself: refused, and with it the whole drop.
    NSString* secret = SPDFMacFriendsTestWriteFile(base, @"tax.pdf", [@"private" dataUsingEncoding:4]);
    NSURL* link = [folder URLByAppendingPathComponent:@"holiday.pdf"];
    symlink(secret.fileSystemRepresentation, link.fileSystemRepresentation);
    NSArray* withLink = @[report, link];
    Expect(![SZFriendsDrops itemsForPromisedFiles:withLink inFolder:folder refusedFolder:&refusedFolder] &&
           !refusedFolder, @"a promised symlink was accepted");
    Expect(![SZFriendsPromiseCopies copyPromisedFiles:withLink inFolder:folder refusedFolder:&refusedFolder] &&
           !refusedFolder && !Exists([folder URLByAppendingPathExtension:@"copies"]),
           @"a promised symlink was copied, or the refused drop left copies behind");
    NSURL* fifo = [folder URLByAppendingPathComponent:@"pipe.pdf"];
    mkfifo(fifo.fileSystemRepresentation, 0600);
    Expect(![SZFriendsDrops itemsForPromisedFiles:@[fifo] inFolder:folder refusedFolder:&refusedFolder] &&
           ![SZFriendsPromiseCopies copyPromisedFiles:@[fifo] inFolder:folder refusedFolder:&refusedFolder],
           @"a promised FIFO was accepted");
    NSURL* outside = [NSURL fileURLWithPath:secret];
    Expect(![SZFriendsDrops itemsForPromisedFiles:@[outside] inFolder:folder refusedFolder:&refusedFolder] &&
           ![SZFriendsPromiseCopies copyPromisedFiles:@[outside] inFolder:folder refusedFolder:&refusedFolder],
           @"a file outside the folder was accepted");
    NSURL* directory = [folder URLByAppendingPathComponent:@"Site photos"];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil
                                                 error:nil];
    NSArray* withFolder = @[report, directory];
    Expect(![SZFriendsDrops itemsForPromisedFiles:withFolder inFolder:folder refusedFolder:&refusedFolder] &&
           refusedFolder, @"a promised folder must be refused as a folder");
    refusedFolder = NO;
    Expect(![SZFriendsPromiseCopies copyPromisedFiles:withFolder inFolder:folder refusedFolder:&refusedFolder] &&
           refusedFolder, @"a promised folder must be refused as a folder when copying");

    // The folder goes once its time is up; a reader that quit first has it swept at the next drop.
    [SZFriendsDrops discardPromiseFolder:folder after:0.05];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return !Exists(folder); }), @"the promise folder was not removed");
    NSURL* stale = [SZFriendsDrops promiseFolderInDirectory:base];
    Write(stale, @"left behind.pdf");
    NSURL* staleCopies = [stale URLByAppendingPathExtension:@"copies"];
    [NSFileManager.defaultManager createDirectoryAtURL:staleCopies withIntermediateDirectories:NO attributes:nil
                                                 error:nil];
    NSDate* old = [NSDate dateWithTimeIntervalSinceNow:-(SZFriendsPromiseLifetime + 60)];
    for (NSURL* url in @[stale, staleCopies])
        [NSFileManager.defaultManager setAttributes:@{NSFileCreationDate : old} ofItemAtPath:url.path error:nil];
    NSURL* fresh = [SZFriendsDrops promiseFolderInDirectory:base];
    NSURL* recent = [SZFriendsDrops promiseFolderInDirectory:base];
    Expect(!Exists(stale) && !Exists(staleCopies) && Exists(fresh) && Exists(recent),
           @"stale promise folders and copies must be swept, recent ones kept");
}

// The re-check's scenario: the source swaps its checked file for a symlink after the drop. What is sent is a copy
// made from the checked descriptor, in a folder the source was never given.
static void CheckCopies(NSString* base) {
    NSString* secret = SPDFMacFriendsTestWriteFile(base, @"tax.pdf", [@"private" dataUsingEncoding:4]);
    NSURL* folder = [SZFriendsDrops promiseFolderInDirectory:base];
    NSURL* report = Write(folder, @"report.pdf");
    NSURL* notes = Write(folder, @"notes.txt");
    BOOL refusedFolder = YES;
    NSArray<SZFriendsAttachableItem*>* items = [SZFriendsPromiseCopies copyPromisedFiles:@[report, notes]
                                                                                inFolder:folder
                                                                           refusedFolder:&refusedFolder];
    Expect(items.count == 2 && !refusedFolder && [items[0].title isEqual:@"report.pdf"], @"copies %@", items);
    NSURL* copy = items[0].fileURL;
    NSURL* copies = copy.URLByDeletingLastPathComponent;
    Expect(![copy.path hasPrefix:[folder.path stringByAppendingString:@"/"]] && Mode(copies) == 0700 &&
           Mode(copy) == 0600 && [SZFriendsPromiseCopies isPromiseCopy:copy] &&
           ![SZFriendsPromiseCopies isPromiseCopy:report], @"the copy must sit outside the source's folder, private: "
           "%@ %ld %ld", copy, (long)Mode(copies), (long)Mode(copy));
    SwapForLink(report, secret);
    Expect([Text(copy) isEqual:@"bytes"], @"after the source swapped its file for a link, the item sends %@",
           Text(copy));

    // The drop path: the source's folder goes at once; the copies go once sent.
    NSURL* dropped = [SZFriendsDrops promiseFolderInDirectory:base];
    NSURL* file = Write(dropped, @"drawing.pdf");
    __block NSArray<SZFriendsAttachableItem*>* received = nil;
    __block BOOL onMain = NO;
    [SZFriendsPromiseCopies copyPromisedFiles:@[file] inFolder:dropped
                                   completion:^(NSArray<SZFriendsAttachableItem*>* result, BOOL refused) {
        (void)refused;
        onMain = NSThread.isMainThread;
        received = result;
    }];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return received != nil; }) && onMain && received.count == 1,
           @"the drop path did not deliver its copies on the main thread");
    Expect(!Exists(dropped) && [Text(received[0].fileURL) isEqual:@"bytes"],
           @"the source's folder must go at once, and the copy stay until sent");
    SZFriendsAttachableItem* elsewhere = [SZFriendsAttachableItem new];
    elsewhere.fileURL = [NSURL fileURLWithPath:secret];
    [SZFriendsPromiseCopies discardCopiesForItems:@[received[0], elsewhere] after:0];
    NSURL* droppedCopies = received[0].fileURL.URLByDeletingLastPathComponent;
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return !Exists(droppedCopies); }) && Exists(elsewhere.fileURL),
           @"discarding must remove the copies once sent, and nothing that is not a copy");
    [SZFriendsPromiseCopies discardCopiesForItems:items after:0];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return !Exists(copies); }), @"copies were not removed");
}

int main(void) {
    @autoreleasepool {
        NSString* base = SPDFMacFriendsTestTemporaryDirectory(@"promises");
        CheckChecks(base);
        CheckCopies(base);
        [NSFileManager.defaultManager removeItemAtPath:base error:nil];
    }
    puts("SPDFMacFriendsPromiseTests passed");
    return 0;
}
