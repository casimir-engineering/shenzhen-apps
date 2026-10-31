#import "SPDFMacCollectionRetention.h"
#import "SPDFMacCollectionSavePanel.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacCollectionPermanentDelete.h"
@implementation SPDFMacCollectionWindow (Actions)
- (void)openOriginal:(id)sender {
    (void)sender; NSString* path = [self selectedDocument][@"path"];
    if (SPDFCollectionOriginalAvailable([self selectedDocument])) self.openHandler(path, NO);
}
- (void)preview:(id)sender {
    (void)sender; NSDictionary* doc = [self selectedDocument], *version = [self selectedVersion];
    if (!doc || !version[@"id"]) return;
    self.details.stringValue = @"Opening Collection document…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError* error = nil;
        NSURL* URL = [self.store editableVersionID:version[@"id"] documentID:doc[@"id"] error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (URL) self.openHandler(URL.path, YES); else [self showError:error];
            [self updateDetails];
        });
    });
}
- (void)history:(id)sender {
    (void)sender; NSDictionary* doc = [self selectedDocument];
    if (doc) [self showHistoryForDocument:doc version:[self selectedVersion]];
}
- (void)comparePrevious:(id)sender {
    (void)sender;
    NSDictionary* doc = [self selectedDocument], *version = [self selectedVersion];
    if (!doc || !version[@"id"]) return;
    NSArray* versions = doc[@"versions"] ?: @[];
    NSUInteger index = [versions indexOfObjectPassingTest:^BOOL(NSDictionary* v, NSUInteger i, BOOL* stop) {
        (void)i; (void)stop; return [v[@"id"] isEqual:version[@"id"]];
    }];
    if (index == NSNotFound || index == 0) {
        self.details.stringValue = @"This is the first protected version; there is no previous version."; return;
    }
    NSDictionary* older = versions[index - 1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError* error = nil;
        NSURL* oldURL = [self.store materializeVersionID:older[@"id"] documentID:doc[@"id"] error:&error];
        NSURL* newURL = [self.store materializeVersionID:version[@"id"] documentID:doc[@"id"] error:&error];
        NSString* (^date)(NSDictionary*) = ^NSString*(NSDictionary* row) {
            return [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"capturedAt"] doubleValue]]
                dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!oldURL || !newURL) { [self showError:error]; return; }
            SPDFMacShowCollectionComparison(oldURL, newURL, [NSString stringWithFormat:@"%@ · %@",doc[@"title"],date(older)],
                [NSString stringWithFormat:@"%@ · %@",doc[@"title"],date(version)],self.window);
        });
    });
}
- (void)locate:(id)sender {
    (void)sender; NSDictionary* doc = [self selectedDocument]; if (!doc) return;
    SPDFMacLocateCollectionOriginal(self.store, doc[@"id"], self.window, ^(NSString* path) {
        self.openHandler(path, NO);
    }, ^(NSString* path) {
        self.openHandler(path, NO); [self reload:nil];
    });
}
- (void)exportCopy:(id)sender {
    (void)sender; NSDictionary* doc = [self selectedDocument], *version = [self selectedVersion];
    if (!version[@"id"]) return;
    NSSavePanel* panel = [NSSavePanel savePanel]; SPDFCollectionConfigureSavePanel(panel, doc[@"path"]);
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError* error = nil;
            BOOL ok = [self.store exportVersionID:version[@"id"] documentID:doc[@"id"] toURL:panel.URL error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{ if (ok) self.openHandler(panel.URL.path, NO); else [self showError:error]; });
        });
    }];
}
- (NSArray<NSDictionary*>*)selectedRowsSnapshot {
    if ([self.destination isEqual:@"History"]) {
        NSDictionary* doc = [self selectedDocument], *version = [self selectedVersion];
        return doc && version ? @[@{@"document":doc,@"version":version}] : @[];
    }
    NSMutableArray* selected = [NSMutableArray array];
    [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
        (void)stop; if (index < self.rows.count) [selected addObject:self.rows[index]];
    }];
    return selected;
}
- (void)performMutation:(void (^)(NSError**))operation {
    if (self.mutationPending) return;
    self.mutationPending = YES; [self updateDetails];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error = nil; operation(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.mutationPending = NO; [self showError:error]; [self reload:nil];
        });
    });
}
- (void)keep:(id)sender {
    (void)sender;
    if (![self.store isStorageLimited]) return;
    NSArray* rows = [self selectedRowsSnapshot];
    BOOL keep = !SPDFCollectionSelectionIsKept(rows);
    [self performMutation:^(NSError** error) {
        for (NSDictionary* row in rows) {
            NSDictionary* doc = row[@"document"], *version = row[@"version"];
            if (version[@"id"] && ![self.store setKeep:keep
                versionID:version[@"id"] documentID:doc[@"id"] error:error]) break;
        }
    }];
}
- (void)deleteSelected:(id)sender {
    (void)sender;
    NSArray* rows = [self selectedRowsSnapshot]; if (!rows.count) return;
    BOOL versionsOnly = [self.destination isEqual:@"History"];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = versionsOnly ? @"Delete selected versions permanently?" : @"Delete all previous backups for selected documents?";
    alert.informativeText = [NSString stringWithFormat:versionsOnly ?
        @"%lu selected versions, including kept versions, will be permanently deleted. Originals are kept." :
        @"Older backups for %lu selected documents, including kept versions, will be permanently deleted. Originals and latest saved copies are kept.",rows.count];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:versionsOnly ? @"Delete Versions" : @"Delete Previous Backups"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSAlertSecondButtonReturn) return;
        // Snapshot identities before showing the sheet; a background refresh or
        // a changed selection must never change what the confirmation deletes.
        [self performMutation:^(NSError** error) {
            for (NSDictionary* row in rows) {
                BOOL deleted=versionsOnly ? [self.store deleteDocumentID:row[@"document"][@"id"]
                    versionID:row[@"version"][@"id"] error:error] :
                    [self.store deletePreviousBackupsForDocumentID:row[@"document"][@"id"] error:error];
                if(!deleted) break;
            }
        }];
    }];
}
- (void)removeFromDiskAndCollection:(id)sender {
    (void)sender;
    NSMutableOrderedSet* identifiers = [NSMutableOrderedSet orderedSet];
    NSMutableArray* names = [NSMutableArray array], *files = [NSMutableArray array];
    for (NSDictionary* row in [self selectedRowsSnapshot]) {
        NSDictionary* doc = row[@"document"];
        if (![doc[@"id"] length] || [identifiers containsObject:doc[@"id"]]) continue;
        [identifiers addObject:doc[@"id"]];
        [names addObject:[doc[@"path"] lastPathComponent] ?: SPDFCollectionDocumentTitle(doc) ?: @"Document"];
        if (SPDFCollectionOriginalAvailable(doc)) [files addObject:doc[@"path"]];
    }
    if (!identifiers.count || !self.deleteHandler || self.mutationPending) return;
    SPDFPermanentDeleteAsk(self.window, names, files, ^{
        self.mutationPending = YES; [self updateDetails];
        self.deleteHandler(identifiers.array, ^(NSArray<NSString*>* failures) {
            self.mutationPending = NO;
            if (failures.count) [SPDFPermanentDeleteFailure(failures) beginSheetModalForWindow:self.window completionHandler:nil];
            [self reload:nil];
        });
    });
}
- (void)changeEnabled:(id)sender {
    (void)sender; NSError* error = nil;
    BOOL updated = [self.store updateSettings:@{@"choice":self.enabled.state == NSControlStateValueOn ? @"enabled" : @"disabled"} error:&error];
    if (updated) [NSNotificationCenter.defaultCenter postNotificationName:@"SPDFCollectionSettingsChanged" object:self.store];
    [self showError:error]; [self reload:nil];
}
- (void)changeLimit:(id)sender {
    (void)sender;
    double amount = 0;
    NSScanner* scanner = [NSScanner scannerWithString:self.limitPicker.indexOfSelectedItem != 1 ? @"0" : self.limitField.stringValue];
    if (![scanner scanDouble:&amount] || !scanner.isAtEnd || !isfinite(amount) || amount < 0 || amount > 1e8) {
        [self showError:[NSError errorWithDomain:@"ShenzhenPDF.Collection" code:1 userInfo:@{
            NSLocalizedDescriptionKey:@"Enter a nonnegative storage limit in GB. Zero keeps all versions."}]];
        return;
    }
    unsigned long long bytes = (unsigned long long)(amount * 1e9);
    NSDictionary* policy=@{@"storageMode":self.limitPicker.indexOfSelectedItem == 2 ? @"dynamic" : bytes ? @"static" : @"unlimited",@"storageLimitBytes":@(bytes),@"storageDynamicPercent":@(self.dynamicPercent.integerValue)};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSDictionary* plan = [self.store previewStoragePolicy:policy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![plan[@"canApply"] boolValue]) {
                [self showError:[NSError errorWithDomain:@"ShenzhenPDF.Collection" code:1 userInfo:@{
                    NSLocalizedDescriptionKey:plan[@"error"] ?: @"Kept histories prevent this limit. Increase it or review Keep selections."}]];
                return;
            }
            void (^apply)(void) = ^{
                [self performMutation:^(NSError** error) {
                    if ([self.store applyStoragePolicy:policy reviewedPlan:plan error:error])
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [NSNotificationCenter.defaultCenter postNotificationName:@"SPDFCollectionSettingsChanged" object:self.store
                                userInfo:@{@"storageLimitOnly":@YES}];
                        });
                }];
            };
            if (![plan[@"removedVersionCount"] unsignedIntegerValue] && ![plan[@"removedDocumentCount"] unsignedIntegerValue]) {
                apply(); return;
            }
            NSAlert* alert = [NSAlert new]; alert.messageText = @"Apply storage limit and clean up copies?";
            alert.informativeText = [NSString stringWithFormat:
                @"This removes %@ saved versions, including the final copies of %@ document histories, recovering %@. Least-opened documents are considered first; older versions go before final copies. Kept histories and originals remain untouched. This cannot be undone.",
                plan[@"removedVersionCount"],plan[@"removedDocumentCount"],
                [NSByteCountFormatter stringFromByteCount:[plan[@"reclaimedBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
            [alert addButtonWithTitle:@"Cancel"]; [alert addButtonWithTitle:@"Apply and Clean Up"];
            [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
                if (response == NSAlertSecondButtonReturn) apply();
            }];
        });
    });
}
- (void)changeLocation:(id)sender {
    (void)sender; NSOpenPanel* panel = [NSOpenPanel openPanel]; panel.title = @"Move Collection to Folder";
    panel.canChooseFiles = NO; panel.canChooseDirectories = YES; panel.canCreateDirectories = YES;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSURL* destination = [panel.URL URLByAppendingPathComponent:@"ShenzhenPDF Collection" isDirectory:YES];
        self.storage.stringValue = @"Moving protected copies…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError* error = nil; [self.store relocateToURL:destination error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{ [self showError:error]; [self reload:nil]; });
        });
    }];
}
@end
