#import "SPDFMacAIReaderControls.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacWorkspacePanels.h"
#import "SPDFMacCollectionIntegration.h"
#import "SPDFMacAIToolsComments.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacAIFileTransaction.h"
@interface ShenzhenMacDelegate (AIControlsHost)
- (void)persistActiveState;
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve;
- (void)toggleReadingTheme:(id)sender;
- (void)toggleDarkThemePreservesImages:(id)sender;
- (void)changeMarkdownFontScaleByFactor:(CGFloat)factor;
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal;
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave;
- (void)reloadSelectedTabFromDiskChange;
@end
static NSDictionary* ControlError(NSString* message) { return @{@"error":message}; }
static BOOL Number(NSString* text, double lower, double upper, double* number) {
    NSScanner* scanner=[NSScanner scannerWithString:text]; double value=0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) || value<lower || value>upper) return NO;
    *number=value; return YES;
}
@implementation ShenzhenMacDelegate (SPDFMacAIReaderControls)
- (NSDictionary*)aiReaderControls {
    BOOL markdown=[self isMarkdownActive]; SPDFMacMarkdownSession* session=markdown ? [self activeMarkdownSession] : nil;
    NSInteger pages=session ? (NSInteger)session.pageCount : (_doc ? spdf_page_count(_doc) : 0);
    return @{@"path":_path ?: @"",@"revision":SPDFSearchFileStamp(_path) ?: @"",@"pageCount":@(pages),
        @"page":@(session ? session.currentPageIndex+1 : _pageIndex+1),
        @"zoomPercent":@((session ? session.zoom : _zoom)*100),@"fitMode":@(session ? session.fitMode : _fitMode),
        @"theme":_darkReadingTheme ? @"dark" : @"light",@"keepImageColors":@([self selectedTab].preservesImageColors),
        @"textSizePercent":@(_markdownFontScale*100),@"sidebarVisible":@(_sidebarPreferredVisible),
        @"sidebarMode":@(_sidebarModeControl.spdf_selectedSidebarMode),@"mapVisible":@(_minimapPreferredVisible),
        @"searchQuery":_searchField.stringValue ?: @"",@"textDocument":@(markdown),
        @"choices":@{@"page":@"1 through pageCount",@"zoom":@"fit-page, fit-width, fit-height, actual, or 10–1600 percent as a number",
            @"theme":@[@"light",@"dark"],@"keep-image-colors":@[@"on",@"off"],
            @"text-size":markdown ? @"50–300 percent as a number" : @"Unavailable for this format",
            @"sidebar":@[@"hidden",@"chapters",@"search",@"history",@"groups",@"comments (PDF only)"],
            @"map":@[@"shown",@"hidden"],@"find":@"Literal query; empty clears search",
            @"rotate":markdown ? @"clockwise or anticlockwise rotates text paper orientation" :
                ([_path.pathExtension.lowercaseString isEqual:@"pdf"] ? @"clockwise or anticlockwise rotates the current PDF page; revision required" : @"Unavailable for this format")}};
}
- (NSDictionary*)aiControlSnapshot:(NSString*)action {
    SPDFMacMarkdownSession* session=[self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if ([action isEqual:@"page"]) return @{@"page":@(session ? session.currentPageIndex+1 : _pageIndex+1)};
    if ([action isEqual:@"zoom"]) {
        NSInteger fit=session ? session.fitMode : _fitMode;
        return @{@"fit":@(fit),@"zoom":@(fit==SPDFFitModeCustom ? (session ? session.zoom : _zoom) : 0),@"custom":@(_rememberedCustomZoom)};
    }
    if ([action isEqual:@"theme"]) return @{@"dark":@(_darkReadingTheme)};
    if ([action isEqual:@"keep-image-colors"]) return @{@"keep":@([self selectedTab].preservesImageColors)};
    if ([action isEqual:@"text-size"]) return @{@"scale":@(_markdownFontScale)};
    if ([action isEqual:@"rotate"]) return @{@"landscape":@([self selectedTab].markdownLandscape)};
    if ([action isEqual:@"map"]) return @{@"visible":@(_minimapPreferredVisible)};
    NSMutableDictionary* state=[@{@"visible":@(_sidebarPreferredVisible),@"mode":@(_sidebarModeControl.spdf_selectedSidebarMode)} mutableCopy];
    if ([action isEqual:@"find"]) {
        state[@"query"]=_searchField.stringValue ?: @""; state[@"regex"]=@(_findRegexCheckbox.state==NSControlStateValueOn);
        state[@"multiline"]=@(_findRegexMultiline);
    }
    return state;
}
- (void)aiRestoreControlSnapshot:(NSDictionary*)state action:(NSString*)action {
    BOOL markdown=[self isMarkdownActive]; SPDFMacMarkdownSession* session=markdown ? [self activeMarkdownSession] : nil;
    if ([action isEqual:@"page"]) {
        if (session) [self markdownGoToPage:[state[@"page"] integerValue]-1];
        else [self goToPage:[state[@"page"] integerValue]-1 preserveSinglePagePosition:NO];
    } else if ([action isEqual:@"zoom"]) {
        _fitMode=(SPDFFitMode)[state[@"fit"] integerValue]; _rememberedCustomZoom=[state[@"custom"] doubleValue];
        if (_fitMode==SPDFFitModeCustom) _zoom=[state[@"zoom"] doubleValue];
        if (session) {
            if (_fitMode==SPDFFitModeCustom) [session setZoom:_zoom]; else [self markdownApplyFitMode:_fitMode];
        } else [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO];
    } else if ([action isEqual:@"theme"]) {
        if (_darkReadingTheme!=[state[@"dark"] boolValue]) [self toggleReadingTheme:nil];
    } else if ([action isEqual:@"keep-image-colors"]) {
        if ([self selectedTab].preservesImageColors!=[state[@"keep"] boolValue]) [self toggleDarkThemePreservesImages:nil];
    } else if ([action isEqual:@"text-size"]) {
        // Assign the exact saved scale: multiplying and rounding would drift.
        _markdownFontScale=[state[@"scale"] doubleValue]; [session applyFontScale:_markdownFontScale];
        [self updateControlsForActiveMarkdown];
    } else if ([action isEqual:@"rotate"]) {
        if ([self selectedTab].markdownLandscape!=[state[@"landscape"] boolValue]) [self rotateMarkdownPaperByDegrees:90];
    } else if ([action isEqual:@"map"]) {
        _minimapPreferredVisible=[state[@"visible"] boolValue];
        if (_minimapPreferredVisible) [self prioritizeWorkspaceMap];
        [self setMinimapActuallyVisible:_minimapPreferredVisible];
    } else {
        if ([action isEqual:@"find"]) {
            _searchField.stringValue=state[@"query"];
            _findRegexCheckbox.state=[state[@"regex"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            _findRegexMultiline=[state[@"multiline"] boolValue];
            [self startFindForCurrentQueryResetSavedIndex:NO revealMatch:NO];
        }
        _sidebarPreferredVisible=[state[@"visible"] boolValue];
        _sidebarModeControl.spdf_selectedSidebarMode=[state[@"mode"] integerValue];
        if (_sidebarPreferredVisible) [self prioritizeWorkspaceSidebar];
        [self rememberSidebarWorkspaceMode]; [self rebuildSidebar];
    }
    [self persistActiveState];
}
- (NSDictionary*)aiRotatePDF:(NSString*)direction revision:(NSString*)revision progress:(NSProgress*)progress {
    if (![revision isEqual:SPDFSearchFileStamp(_path)]) return ControlError(@"Read reader_state first; PDF rotation requires its current revision.");
    NSString* path=[_path copy]; NSInteger page=_pageIndex;
    struct stat info={};
    if (stat(path.fileSystemRepresentation,&info) || info.st_size>32LL*1024*1024)
        return ControlError(@"This PDF exceeds the 32 MiB reversible rotation budget.");
    if (![self ensureActivePDFCanBeModifiedForOperation:@"assistant page rotation"] || progress.cancelled)
        return ControlError(@"Rotation cancelled.");
    if (![_path isEqual:path] || ![revision isEqual:SPDFSearchFileStamp(path)] || page!=_pageIndex)
        return ControlError(@"The document changed during permission handling. Read reader_state again.");
    NSError* error=nil;
    NSDictionary* receipt=SPDFAIMutatePDF(path,revision,progress,^BOOL(spdf_document* document,char* message,size_t length) {
        return spdf_rotate_page(document,(int)page,[direction isEqual:@"clockwise"] ? 90 : -90,message,length);
    },&error);
    if (!receipt) return ControlError(error.localizedDescription ?: @"PDF rotation could not be saved.");

    [self collectionDidSavePath:path]; [self refreshActiveTabCachedFileAttributesAfterSelfSave];
    [self reloadSelectedTabFromDiskChange];
    return @{@"path":path,@"changed":@YES,@"fileReceipt":receipt};
}
- (NSDictionary*)aiApplyReaderControl:(NSDictionary*)arguments progress:(NSProgress*)progress {
    if (progress.cancelled) return ControlError(@"Cancelled.");
    if (![arguments[@"path"] isEqual:_path]) return ControlError(@"This control belongs to a different document. Show it or read reader_state again.");
    if (!_path.length || (!_doc && ![self activeMarkdownSession].isNavigationReady)) return ControlError(@"Wait for the document to finish opening.");
    NSString* action=arguments[@"control"],*value=arguments[@"value"];
    NSArray* supported=@[@"page",@"zoom",@"theme",@"keep-image-colors",@"text-size",@"sidebar",@"map",@"find",@"rotate"];
    if (![supported containsObject:action]) return ControlError(@"Unknown reader control. Read reader_state for choices.");
    NSDictionary* before=[self aiControlSnapshot:action]; NSMutableDictionary* next=[before mutableCopy]; double number=0;
    BOOL markdown=[self isMarkdownActive];
    if ([action isEqual:@"page"]) {
        NSInteger count=markdown ? [self activeMarkdownSession].pageCount : spdf_page_count(_doc);
        if (!Number(value,1,count,&number) || floor(number)!=number) return ControlError(@"Page must be a whole number inside this document.");
        next[@"page"]=@(number);
    } else if ([action isEqual:@"zoom"]) {
        NSDictionary* fits=@{@"fit-page":@(SPDFFitModePage),@"fit-width":@(SPDFFitModeWidth),@"fit-height":@(SPDFFitModeHeight),@"actual":@(SPDFFitModeActual)};
        if (fits[value]) { next[@"fit"]=fits[value]; next[@"zoom"]=@0; }
        else {
            if (!Number(value,10,1600,&number)) return ControlError(@"Use fit-page, fit-width, fit-height, actual, or 10–1600 percent.");
            next[@"fit"]=@(SPDFFitModeCustom); next[@"zoom"]=@(number/100); next[@"custom"]=@(number/100);
        }
    } else if ([action isEqual:@"theme"]) {
        if (![@[@"light",@"dark"] containsObject:value]) return ControlError(@"Theme is light or dark.");
        next[@"dark"]=@([value isEqual:@"dark"]);
    } else if ([action isEqual:@"keep-image-colors"]) {
        if (![@[@"on",@"off"] containsObject:value]) return ControlError(@"Keep image colors is on or off.");
        next[@"keep"]=@([value isEqual:@"on"]);
    } else if ([action isEqual:@"text-size"]) {
        if (!markdown || !Number(value,50,300,&number)) return ControlError(@"Text size requires a text document and 50–300 percent.");
        next[@"scale"]=@(number/100);
    } else if ([action isEqual:@"map"]) {
        if (![@[@"shown",@"hidden"] containsObject:value]) return ControlError(@"Map is shown or hidden.");
        next[@"visible"]=@([value isEqual:@"shown"]);
    } else if ([action isEqual:@"sidebar"]) {
        NSDictionary* modes=@{@"chapters":@(SPDFSidebarModeChapters),@"comments":@(SPDFSidebarModeComments),@"search":@(SPDFSidebarModeSearch),@"history":@(SPDFSidebarModeHistory),@"groups":@(SPDFSidebarModeGroups)};
        if (![value isEqual:@"hidden"] && !modes[value]) return ControlError(@"Unknown sidebar mode.");
        if (markdown && [value isEqual:@"comments"]) return ControlError(@"Text documents do not support comments.");
        if (modes[value]) next[@"mode"]=modes[value]; next[@"visible"]=@(![value isEqual:@"hidden"]);
    } else if ([action isEqual:@"find"]) {
        next[@"query"]=value; next[@"regex"]=@NO; next[@"multiline"]=@NO;
        next[@"visible"]=@YES; next[@"mode"]=@(SPDFSidebarModeSearch);
    } else if ([action isEqual:@"rotate"]) {
        if (![@[@"clockwise",@"anticlockwise"] containsObject:value]) return ControlError(@"Rotation is clockwise or anticlockwise.");
        if (!markdown) {
            if (![_path.pathExtension.lowercaseString isEqual:@"pdf"]) return ControlError(@"Reversible assistant rotation currently supports PDF pages and text paper orientation.");
            return [self aiRotatePDF:value revision:arguments[@"revision"] progress:progress];
        }
        next[@"landscape"]=@(![self selectedTab].markdownLandscape);
    }
    if (progress.cancelled) return ControlError(@"Cancelled.");
    [self aiRestoreControlSnapshot:next action:action];
    return @{@"path":_path,@"changed":@YES,@"control":action,
        @"controlReceipt":@{@"path":_path,@"action":action,@"before":before,@"after":[self aiControlSnapshot:action]}};
}
- (BOOL)aiUndoReaderControl:(NSDictionary*)receipt progress:(NSProgress*)progress {
    if (progress.cancelled || ![_path isEqual:receipt[@"path"]] ||
        ![[self aiControlSnapshot:receipt[@"action"]] isEqual:receipt[@"after"]]) return NO;
    [self aiRestoreControlSnapshot:receipt[@"before"] action:receipt[@"action"]]; return YES;
}
@end
