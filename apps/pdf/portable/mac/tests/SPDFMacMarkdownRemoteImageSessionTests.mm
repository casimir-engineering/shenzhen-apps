// Session-level remote-image behavior: lazy active-tab fetching through the
// injectable fetcher seam (NO real network anywhere in this file), coalesced
// viewport-preserving rerenders, the shared LRU disk cache, and failure
// placeholders.

#import <AppKit/AppKit.h>

#import "../SPDFMacMarkdownCache.h"
#import "../SPDFMacMarkdownRemoteImagePolicy.h"
#import "../SPDFMacMarkdownSessionImageLoader.h"
#import "../SPDFMacMarkdownSessionPrivate.h"

#include <assert.h>
#include <stdio.h>
#include <sys/xattr.h>

static BOOL SpinUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

static NSString* WriteMarkdown(NSString* text) {
    NSString* path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"md"]];
    assert([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    return path;
}

static NSData* MakePNG(NSUInteger width, NSUInteger height) {
    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                       pixelsWide:(NSInteger)width
                                                                       pixelsHigh:(NSInteger)height
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSCalibratedRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
    memset(bitmap.bitmapData, 0x3c, bitmap.bytesPerRow * bitmap.pixelsHigh);
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSUInteger AttachedImageCount(NSAttributedString* string) {
    __block NSUInteger count = 0;
    [string enumerateAttribute:NSAttachmentAttributeName
                       inRange:NSMakeRange(0, string.length)
                       options:0
                    usingBlock:^(id value, NSRange range, BOOL* stop) {
                      (void)range;
                      (void)stop;
                      NSTextAttachment* attachment = value;
                      if (attachment.image) ++count;
                    }];
    return count;
}

static void ActivateAndAwait(SPDFMacMarkdownSession* session, NSView* host, dispatch_queue_t queue) {
    __block BOOL loaded = NO;
    [session activateInHostView:host
                      workQueue:queue
                   scrollOrigin:NSZeroPoint
                  selectedRange:NSMakeRange(0, 0)
                      pageIndex:0
                           zoom:1.0
                        fitMode:SPDFMacMarkdownPageFitPage
                         anchor:nil
                     completion:^(BOOL success, NSError* error) {
                       assert(success && !error);
                       loaded = YES;
                     }];
    assert(SpinUntil(
        ^BOOL {
          return loaded;
        },
        5.0));
}

int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        NSURL* cacheDirectory = [NSURL
            fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                isDirectory:YES];
        NSString* alphaURL = @"https://images.test/alpha.png";
        NSString* betaURL = @"https://images.test/beta.png";
        NSString* brokenURL = @"https://images.test/broken.png";
        NSData* alphaPNG = MakePNG(6, 4);
        NSData* betaPNG = MakePNG(3, 3);
        NSDictionary<NSString*, NSData*>* responses = @{alphaURL: alphaPNG, betaURL: betaPNG};

        // --- Disk cache primitives -------------------------------------------------
        assert(spdf_mac_markdown_image_cache_read(cacheDirectory, alphaURL) == nil);
        assert(spdf_mac_markdown_image_cache_write(cacheDirectory, alphaURL, alphaPNG));
        assert([spdf_mac_markdown_image_cache_read(cacheDirectory, alphaURL) isEqualToData:alphaPNG]);
        assert(![spdf_mac_markdown_image_cache_file_name(alphaURL)
            isEqualToString:spdf_mac_markdown_image_cache_file_name(betaURL)]);
        // LRU trim: refresh alpha, add beta, trim to one file's budget — the
        // stale entry goes first.
        assert(spdf_mac_markdown_image_cache_write(cacheDirectory, betaURL, betaPNG));
        [NSFileManager.defaultManager
            setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-3600]}
             ofItemAtPath:[cacheDirectory
                              URLByAppendingPathComponent:spdf_mac_markdown_image_cache_file_name(betaURL)]
                              .path
                    error:nil];
        spdf_mac_markdown_image_cache_trim(cacheDirectory, alphaPNG.length);
        assert([spdf_mac_markdown_image_cache_read(cacheDirectory, alphaURL) isEqualToData:alphaPNG]);
        assert(spdf_mac_markdown_image_cache_read(cacheDirectory, betaURL) == nil);
        [NSFileManager.defaultManager removeItemAtURL:cacheDirectory error:nil];

        // --- Loader: fetch, coalesce, dedupe, fail ---------------------------------
        SPDFMacMarkdownSessionImageLoader* loader =
            [[SPDFMacMarkdownSessionImageLoader alloc] initWithCacheDirectory:cacheDirectory];
        __block NSUInteger fetches = 0;
        __block NSUInteger updates = 0;
        loader.fetcher = ^(NSURL* URL, SPDFMacMarkdownImageFetchCompletion completion) {
          ++fetches;
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(responses[URL.absoluteString]);
          });
        };
        loader.imagesUpdatedHandler = ^{
          ++updates;
        };
        [loader requestTargets:@[ alphaURL, betaURL, brokenURL, alphaURL ]];
        assert(SpinUntil(
            ^BOOL {
              return loader.outstandingRequestCount == 0 && updates > 0;
            },
            5.0));
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        assert(fetches == 3);  // the duplicate alpha request never re-fetches
        assert(updates == 1);  // one coalesced notification for the whole batch
        assert([loader.loadedImageData[alphaURL] isEqualToData:alphaPNG]);
        assert([loader.loadedImageData[betaURL] isEqualToData:betaPNG]);
        assert([loader.failedTargets containsObject:brokenURL]);
        assert(loader.networkFetchCount == 3);
        // Requesting settled targets again is a no-op — no fetch, no update.
        [loader requestTargets:@[ alphaURL, betaURL, brokenURL ]];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        assert(fetches == 3 && updates == 1);

        // A fresh loader sharing the cache directory serves both images from
        // disk without ever touching the fetcher seam.
        assert(SpinUntil(
            ^BOOL {
              return spdf_mac_markdown_image_cache_read(cacheDirectory, alphaURL) != nil &&
                     spdf_mac_markdown_image_cache_read(cacheDirectory, betaURL) != nil;
            },
            5.0));
        SPDFMacMarkdownSessionImageLoader* diskLoader =
            [[SPDFMacMarkdownSessionImageLoader alloc] initWithCacheDirectory:cacheDirectory];
        __block NSUInteger diskUpdates = 0;
        diskLoader.fetcher = ^(NSURL* URL, SPDFMacMarkdownImageFetchCompletion completion) {
          (void)URL;
          assert(false && "disk-cache hits must never invoke the fetcher");
          completion(nil);
        };
        diskLoader.imagesUpdatedHandler = ^{
          ++diskUpdates;
        };
        [diskLoader requestTargets:@[ alphaURL, betaURL ]];
        assert(SpinUntil(
            ^BOOL {
              return diskLoader.loadedImageData.count == 2 && diskUpdates >= 1;
            },
            5.0));
        assert(diskLoader.networkFetchCount == 0);

        // --- Session integration ----------------------------------------------------
        NSString* path = WriteMarkdown([NSString
            stringWithFormat:@"# Remote\n\nIntro paragraph.\n\n![Alpha](%@)\n\n![Beta][ref]\n\n![Broken](%@)\n\n"
                              "[ref]: %@ \"Beta title\"\n",
                             alphaURL, brokenURL, betaURL]);
        NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        dispatch_queue_t queue = dispatch_queue_create("markdown.remote.test", DISPATCH_QUEUE_CONCURRENT);

        // Downloads must not start for a session that was never activated.
        NSURL* inactiveCache = [NSURL
            fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                isDirectory:YES];
        SPDFMacMarkdownSession* inactive =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        SPDFMacMarkdownSessionImageLoader* inactiveLoader =
            [[SPDFMacMarkdownSessionImageLoader alloc] initWithCacheDirectory:inactiveCache];
        __block NSUInteger inactiveFetches = 0;
        inactiveLoader.fetcher = ^(NSURL* URL, SPDFMacMarkdownImageFetchCompletion completion) {
          (void)URL;
          ++inactiveFetches;
          completion(nil);
        };
        [inactive installRemoteImageLoader:inactiveLoader];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        assert(inactiveFetches == 0 && inactiveLoader.networkFetchCount == 0);

        // Activating fetches lazily, then exactly one coalesced rerender
        // installs the arrived images while preserving the viewport.
        NSURL* sessionCache = [NSURL
            fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                isDirectory:YES];
        SPDFMacMarkdownSession* session =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        SPDFMacMarkdownSessionImageLoader* sessionLoader =
            [[SPDFMacMarkdownSessionImageLoader alloc] initWithCacheDirectory:sessionCache];
        __block NSUInteger sessionFetches = 0;
        sessionLoader.fetcher = ^(NSURL* URL, SPDFMacMarkdownImageFetchCompletion completion) {
          ++sessionFetches;
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(responses[URL.absoluteString]);
          });
        };
        [session installRemoteImageLoader:sessionLoader];
        __block NSUInteger imageRerenders = 0;
        session.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Markdown images updated."]) ++imageRerenders;
        };
        ActivateAndAwait(session, host, queue);
        // The first render shows pending boxes (attachments) for all three
        // https targets and no decoded bitmaps yet is not guaranteed at this
        // point (fetches race the assertion), but the placeholders must exist
        // in the install that triggered the fetches.
        assert(session.renderedDocument != nil);
        assert(SpinUntil(
            ^BOOL {
              return imageRerenders == 1;
            },
            5.0));
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        assert(imageRerenders == 1);  // the three arrivals coalesced into one rerender
        assert(sessionFetches == 3 && sessionLoader.networkFetchCount == 3);
        NSAttributedString* rendered = session.renderedDocument.attributedString;
        assert(AttachedImageCount(rendered) >= 2);  // alpha + beta decoded
        assert([rendered.string containsString:@"[Image: Broken]"]);  // failed fetch degrades
        assert(![rendered.string containsString:@"[Image: Alpha]"]);
        // The reference-style image resolved and rendered at natural size.
        __block BOOL betaRendered = NO;
        [rendered enumerateAttribute:SPDFMarkdownImageTargetAttribute
                             inRange:NSMakeRange(0, rendered.length)
                             options:0
                          usingBlock:^(id value, NSRange range, BOOL* stop) {
                            (void)range;
                            if ([value isEqual:betaURL]) {
                                betaRendered = YES;
                                *stop = YES;
                            }
                          }];
        assert(betaRendered);
        // Re-activation and rerenders must not re-request settled targets.
        [session applyFontScale:1.2];
        assert(SpinUntil(
            ^BOOL {
              return session.fontScale == 1.2 && sessionLoader.outstandingRequestCount == 0;
            },
            5.0));
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        assert(sessionFetches == 3 && imageRerenders == 1);
        [session deactivate];

        // A second session over the same cache directory renders both images
        // from disk without one fetcher call (never re-download).
        SPDFMacMarkdownSession* cachedSession =
            [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        SPDFMacMarkdownSessionImageLoader* cachedLoader =
            [[SPDFMacMarkdownSessionImageLoader alloc] initWithCacheDirectory:sessionCache];
        __block NSUInteger cachedFetches = 0;
        cachedLoader.fetcher = ^(NSURL* URL, SPDFMacMarkdownImageFetchCompletion completion) {
          ++cachedFetches;
          completion(URL ? responses[URL.absoluteString] : nil);
        };
        [cachedSession installRemoteImageLoader:cachedLoader];
        __block NSUInteger cachedRerenders = 0;
        cachedSession.statusHandler = ^(NSString* status) {
          if ([status isEqualToString:@"Markdown images updated."]) ++cachedRerenders;
        };
        ActivateAndAwait(cachedSession, host, queue);
        assert(SpinUntil(
            ^BOOL {
              return cachedRerenders >= 1 && AttachedImageCount(cachedSession.renderedDocument.attributedString) >= 2;
            },
            5.0));
        assert(cachedLoader.loadedImageData.count == 2);
        assert(cachedFetches == 1 && cachedLoader.networkFetchCount == 1);  // only the broken URL re-tries
        [cachedSession deactivate];

        // --- Documents someone else sent ------------------------------------------------
        // A quarantined file (Shenzhen Friends marks everything it receives) and a file in Friends' received
        // folder show remote images as their alt text and never fetch them: fetching would tell the sender's
        // server when and where the document was opened. The ordinary file above still fetches.
        NSString* friendsState = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString* received = [friendsState stringByAppendingPathComponent:@"received"];
        assert([NSFileManager.defaultManager createDirectoryAtPath:received withIntermediateDirectories:YES
                                                        attributes:nil error:nil]);
        setenv("SZFRIENDS_STATE_DIR", friendsState.fileSystemRepresentation, 1);
        NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSString* quarantined = WriteMarkdown(text);
        const char* flag = "0083;6720a0b0;Shenzhen Friends;";
        assert(setxattr(quarantined.fileSystemRepresentation, "com.apple.quarantine", flag, strlen(flag), 0, 0) == 0);
        NSString* inReceived = [received stringByAppendingPathComponent:@"notes.md"];
        assert([text writeToFile:inReceived atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        assert(!SPDFMacMarkdownRemoteImagesWithheld([NSURL fileURLWithPath:path],
                                                    SPDFMacMarkdownFriendsReceivedDirectory()));
        assert(SPDFMacMarkdownRemoteImagesWithheld([NSURL fileURLWithPath:quarantined], nil));
        assert(SPDFMacMarkdownRemoteImagesWithheld([NSURL fileURLWithPath:inReceived],
                                                   SPDFMacMarkdownFriendsReceivedDirectory()));
        for (NSString* sentPath in @[ quarantined, inReceived ]) {
            NSURL* sentCache = [NSURL
                fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                    isDirectory:YES];
            SPDFMacMarkdownSession* sent =
                [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:sentPath]];
            SPDFMacMarkdownSessionImageLoader* sentLoader =
                [[SPDFMacMarkdownSessionImageLoader alloc] initWithCacheDirectory:sentCache];
            __block NSUInteger sentFetches = 0;
            sentLoader.fetcher = ^(NSURL* URL, SPDFMacMarkdownImageFetchCompletion completion) {
              ++sentFetches;
              completion(responses[URL.absoluteString]);
            };
            [sent installRemoteImageLoader:sentLoader];
            ActivateAndAwait(sent, host, queue);
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            assert(sentFetches == 0 && sentLoader.networkFetchCount == 0 && sentLoader.outstandingRequestCount == 0);
            NSAttributedString* shown = sent.renderedDocument.attributedString;
            assert([shown.string containsString:@"[Image: Alpha]"] && [shown.string containsString:@"[Image: Beta]"]);
            assert(AttachedImageCount(shown) == 0);  // no pending boxes waiting for a download that will not come
            [sent deactivate];
            [NSFileManager.defaultManager removeItemAtURL:sentCache error:nil];
        }
        unsetenv("SZFRIENDS_STATE_DIR");
        [NSFileManager.defaultManager removeItemAtPath:friendsState error:nil];
        [NSFileManager.defaultManager removeItemAtPath:quarantined error:nil];

        [NSFileManager.defaultManager removeItemAtURL:cacheDirectory error:nil];
        [NSFileManager.defaultManager removeItemAtURL:sessionCache error:nil];
        [NSFileManager.defaultManager removeItemAtURL:inactiveCache error:nil];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        puts("SPDFMacMarkdownRemoteImageSessionTests passed");
    }
    return 0;
}
