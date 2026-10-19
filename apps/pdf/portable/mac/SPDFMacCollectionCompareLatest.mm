#import "SPDFMacCollectionCompareLatest.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionAvailability.h"

NSDictionary* SPDFCollectionResolveLatestComparison(SPDFMacCollectionStore* store, NSString* documentID,
                                                    NSError** error) {
    NSDictionary* document = nil;
    // Do not reuse the History view's document dictionary: Locate can relink
    // its source, or another window can capture a newer version in the meantime.
    for (NSDictionary* candidate in store.documents) {
        if ([candidate[@"id"] isEqual:documentID]) { document = candidate; break; }
    }
    NSString* title = document[@"title"] ?: @"Document";
    if (SPDFCollectionOriginalAvailable(document) && ![store isArchivePath:document[@"path"]]) {
        return @{@"URL":[NSURL fileURLWithPath:document[@"path"]],@"document":document,@"archived":@NO,
                 @"label":[title stringByAppendingString:@" · Latest original"]};
    }
    NSArray* versions = document[@"versions"] ?: @[];
    NSDictionary* latest = nil;
    for (NSDictionary* version in versions) if ([version[@"id"] isEqual:document[@"latestVersionID"]]) {
        latest = version; break;
    }
    if (!latest) latest = versions.lastObject;
    if (latest[@"id"]) {
        NSURL* URL = [store materializeVersionID:latest[@"id"] documentID:documentID error:error];
        if (!URL) return nil;
        NSString* date = [NSDateFormatter localizedStringFromDate:
            [NSDate dateWithTimeIntervalSince1970:[latest[@"capturedAt"] doubleValue]]
            dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
        return @{@"URL":URL,@"document":document,@"version":latest,@"archived":@YES,
                 @"label":[NSString stringWithFormat:@"%@ · Latest saved version · %@",title,date]};
    }
    if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.CollectionComparison" code:2
        userInfo:@{NSLocalizedDescriptionKey:@"The linked original is unavailable and there is no saved version to compare."}];
    return nil;
}
