#import "SPDFMacOpenRouting.h"

NSString* const SPDFMacShowDocumentNotification = @"com.intuition.shenzhenpdf.ShowDocument";
NSString* const SPDFMacShowDocumentConfirmedNotification = @"com.intuition.shenzhenpdf.ShowDocumentConfirmed";

pid_t SPDFMacOtherWindowShowingPath(id session, NSString* path, pid_t selfPID, BOOL (^isRunningReader)(pid_t pid)) {
    if (![session isKindOfClass:NSDictionary.class] || !path.length) return 0;
    id windows = ((NSDictionary*)session)[@"windows"];
    if (![windows isKindOfClass:NSArray.class]) return 0;
    NSString* wanted = path.stringByStandardizingPath;
    pid_t owner = 0;
    double ownerFocusedAt = -1;
    for (NSDictionary* window in windows) {
        if (![window isKindOfClass:NSDictionary.class]) continue;
        if (![window[@"pid"] respondsToSelector:@selector(intValue)]) continue;
        pid_t pid = (pid_t)[window[@"pid"] intValue];
        if (pid <= 0 || pid == selfPID) continue;
        NSArray* tabs = [window[@"tabs"] isKindOfClass:NSArray.class] ? window[@"tabs"] : @[];
        BOOL shows = NO;
        for (NSDictionary* tab in tabs) {
            NSString* tabPath = [tab isKindOfClass:NSDictionary.class] ? tab[@"path"] : nil;
            if ([tabPath isKindOfClass:NSString.class] && [tabPath.stringByStandardizingPath isEqualToString:wanted]) {
                shows = YES;
                break;
            }
        }
        if (!shows) continue;
        double focusedAt = [window[@"focusedAt"] respondsToSelector:@selector(doubleValue)]
            ? [window[@"focusedAt"] doubleValue] : 0;
        if (focusedAt <= ownerFocusedAt) continue;
        // Checked last and only for a window that shows the document: it asks the system about a process.
        if (isRunningReader && !isRunningReader(pid)) continue;
        owner = pid;
        ownerFocusedAt = focusedAt;
    }
    return owner;
}

NSString* SPDFMacShowDocumentRequestPath(NSDictionary* userInfo, pid_t selfPID) {
    if (![userInfo isKindOfClass:NSDictionary.class]) return nil;
    id pid = userInfo[@"pid"], path = userInfo[@"path"];
    if (![pid respondsToSelector:@selector(intValue)] || (pid_t)[pid intValue] != selfPID) return nil;
    if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) return nil;
    // Only documents travel this way. Agent command files keep their own explicit route.
    if ([[path pathExtension].lowercaseString isEqualToString:@"spdf-command"]) return nil;
    return path;
}

NSNumber* SPDFMacShowDocumentRequestPage(NSDictionary* userInfo) {
    id page = [userInfo isKindOfClass:NSDictionary.class] ? userInfo[@"page"] : nil;
    if (![page isKindOfClass:NSNumber.class]) return nil;
    NSInteger value = [page integerValue];
    return value >= 1 && value <= 1000000 && [page doubleValue] == (double)value ? @(value) : nil;
}

NSString* SPDFMacShowDocumentConfirmedRequest(NSDictionary* userInfo, pid_t selfPID) {
    if (![userInfo isKindOfClass:NSDictionary.class]) return nil;
    id pid = userInfo[@"pid"], request = userInfo[@"request"];
    if (![pid respondsToSelector:@selector(intValue)] || (pid_t)[pid intValue] != selfPID) return nil;
    return [request isKindOfClass:NSString.class] && [request length] ? request : nil;
}
