#import "SPDFMacAIDocumentLinks.h"
#import "SPDFMacAICitations.h"
#import "SPDFMacAICollectionTools.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacDocumentOpening.h"
#import "SPDFMacTabGroupIntegration.h"

@interface ShenzhenMacDelegate (SPDFMacAIDocumentLinksHost)
- (void)finishTabGroupChange;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)selectTabAtIndex:(NSInteger)index;
@end

static NSString* (^const Identify)(NSString*) = ^NSString*(NSString* path) { return SPDFAIDocumentIdentifier(path); };

@implementation ShenzhenMacDelegate (SPDFMacAIDocumentLinks)

- (NSArray<NSString*>*)aiDocumentLinkOpenPaths {
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) if (tab.path.length) [paths addObject:tab.path];
    return paths;
}

- (NSString*)aiOpenTabPathForDocumentLink:(NSDictionary*)link {
    if (!link) return nil;
    NSDictionary* target = SPDFMacAIResolveDocumentLink(link, [self aiDocumentLinkOpenPaths], nil, nil, Identify);
    return target[@"path"];
}

// An open tab is revealed in its group before navigating, so a page that is
// still loading lands against the workspace the reader will actually see. A
// document not open yet goes through the ordinary open, which also brings its
// window forward or hands it, with the page, to the window that already shows it.
- (void)aiShowDocumentAtPath:(NSString*)path page:(NSNumber*)page {
    NSInteger index = [self indexOfTabForPath:path];
    if (index < 0) {
        [self showDocumentAtPath:path page:page];
        return;
    }
    if (spdf_tab_groups_reveal(_tabs, _tabs[(NSUInteger)index])) [self finishTabGroupChange];
    if (page) [self aiNavigateDocument:path page:page.integerValue];
    else [self selectTabAtIndex:index];
    [self activateWindowForExternalOpen];
}

- (BOOL)aiOpenDocumentLink:(NSDictionary*)link {
    if (!link) return NO;
    NSNumber* page = link[@"page"];
    NSString* open = [self aiOpenTabPathForDocumentLink:link];
    if (open) {
        [self aiShowDocumentAtPath:open page:page];
        return YES;
    }
    // Not open here: look in Collection and the recently opened files. Reading
    // the Collection, and preparing a saved copy when the original is gone, stays
    // off the main thread.
    NSArray<NSString*>* recent = [_recentlyOpenedPaths copy] ?: @[];
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSMutableArray<NSString*>* existing = [NSMutableArray array];
      for (NSString* path in recent)
          if ([NSFileManager.defaultManager fileExistsAtPath:path]) [existing addObject:path];
      NSDictionary* target = SPDFMacAIResolveDocumentLink(link, nil, existing,
                                                          [SPDFMacCollectionStore.defaultStore documents], Identify);
      NSDictionary* row = target[@"collection"];
      NSDictionary* opened = [row[@"id"] isKindOfClass:NSString.class]
          ? SPDFAICollectionOpenTarget([@"collection:" stringByAppendingString:row[@"id"]], NO, nil)
          : (target[@"path"] ? @{@"readPath" : target[@"path"], @"archived" : @NO} : nil);
      dispatch_async(dispatch_get_main_queue(), ^{
        ShenzhenMacDelegate* owner = weakSelf;
        NSString* path = opened[@"readPath"];
        if (!owner) return;
        BOOL found = [path isKindOfClass:NSString.class] && path.length;
        // A name that is also a site ("example.com") opens the site when no such document is known.
        if (!found && link[@"site"]) { [owner aiOpenWebLink:link[@"site"]]; return; }
        if (!found) { [owner aiShowMissingDocumentLinkOfferingSite:link[@"web"]]; return; }
        if ([opened[@"archived"] boolValue]) [owner collectionOpenPath:path archived:YES];
        [owner aiShowDocumentAtPath:path page:page];
      });
    });
    return YES;
}

- (void)aiOpenWebLink:(NSURL*)URL {
    if (URL) [NSWorkspace.sharedWorkspace openURL:URL];
}

- (void)aiShowMissingDocumentLink {
    [self aiShowMissingDocumentLinkOfferingSite:nil];
}

- (void)aiShowMissingDocumentLinkOfferingSite:(NSURL*)site {
    NSAlert* alert = SPDFMacAIMissingDocumentAlert(site);
    __weak ShenzhenMacDelegate* weakSelf = self;
    if (_window) {
        [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
          [weakSelf aiFinishMissingDocumentAlert:response site:site];
        }];
    } else {
        [self aiFinishMissingDocumentAlert:[alert runModal] site:site];
    }
}

- (void)aiShowMissingWebDocument:(NSURL*)source {
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"This PDF is no longer on this Mac";
    alert.informativeText = @"PDFs the assistant reads are kept for a week. You can open it from its website instead.";
    [alert addButtonWithTitle:@"OK"];
    if (source.host.length) [alert addButtonWithTitle:@"Open Website"];
    else alert.informativeText = @"PDFs the assistant reads are kept for a week.";
    __weak ShenzhenMacDelegate* weakSelf = self;
    if (_window) {
        [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
          [weakSelf aiFinishMissingDocumentAlert:response site:source];
        }];
    } else {
        [self aiFinishMissingDocumentAlert:[alert runModal] site:source];
    }
}

- (void)aiFinishMissingDocumentAlert:(NSModalResponse)response site:(NSURL*)site {
    if (site && response == NSAlertSecondButtonReturn) [self aiOpenWebLink:site];
}

@end

NSAlert* SPDFMacAIMissingDocumentAlert(NSURL* site) {
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"Can't find this document";
    alert.informativeText = @"It may have been moved, renamed or deleted. Ask the assistant to look for it again.";
    [alert addButtonWithTitle:@"OK"];
    if (site.host.length) {
        alert.informativeText = [NSString stringWithFormat:@"It may have been moved, renamed or deleted. "
                                 @"If the link meant the website %@, you can open it instead.", site.host];
        [alert addButtonWithTitle:@"Open Website"];
    }
    return alert;
}
