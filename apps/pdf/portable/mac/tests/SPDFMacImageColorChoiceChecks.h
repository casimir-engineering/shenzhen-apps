#import "SPDFMacTabViewState.h"
static void CheckImageColorChoices(ShenzhenMacDelegate* reader) {
    BOOL dark=[[reader valueForKey:@"darkReadingTheme"] boolValue];
    [reader setValue:@NO forKey:@"darkReadingTheme"];
    SPDFDocumentTab* selected=[reader selectedTab];
    NSArray* tabs=[reader valueForKey:@"tabs"];
    NSArray* prior=[tabs valueForKey:@"preservesImageColors"];
    BOOL initial=selected.preservesImageColors;
    BOOL defaultValue=[[reader valueForKey:@"darkThemePreservesImagesDefault"] boolValue];
    [reader toggleDarkThemePreservesImages:nil];
    Check(selected.preservesImageColors!=initial && [[reader valueForKey:@"darkThemePreservesImagesDefault"] boolValue]==defaultValue,
        @"document shortcut changes only its own image-color choice");
    for(NSUInteger i=0;i<tabs.count;i++) if(tabs[i]!=selected)
        Check([tabs[i] preservesImageColors]==[prior[i] boolValue],@"other documents keep their image colors");
    NSDictionary* saved=spdf_dictionary_from_tab(selected,0);
    Check(spdf_tab_from_dictionary(saved).preservesImageColors==selected.preservesImageColors,@"image-color choice survives session codec");
    SPDFDocumentTab* reopened=[SPDFDocumentTab new]; reopened.path=selected.path;
    [reader seedNewTabFromDocumentMemory:reopened];
    Check(reopened.preservesImageColors==selected.preservesImageColors,@"closing and reopening remembers the file choice");
    [reader toggleDefaultImageColors:nil];
    SPDFDocumentTab* fresh=[SPDFDocumentTab new]; fresh.path=@"/new-document-image-test.pdf";
    [reader seedNewTabFromDocumentMemory:fresh];
    Check(fresh.preservesImageColors!=defaultValue,@"new documents inherit the changed default");
    Check(selected.preservesImageColors!=initial && [[reader valueForKey:@"darkThemePreservesImagesDefault"] boolValue]!=defaultValue,
        @"Settings changes only the default, not the active document");
    [reader toggleDefaultImageColors:nil]; [reader toggleDarkThemePreservesImages:nil];
    [reader setValue:@(dark) forKey:@"darkReadingTheme"];
}
