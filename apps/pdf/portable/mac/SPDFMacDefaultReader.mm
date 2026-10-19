#import "SPDFMacDefaultReader.h"

#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSArray<NSString*>* spdf_pdf_content_type_identifiers(void) {
    NSMutableArray<NSString*>* identifiers = [NSMutableArray array];
    void (^addIdentifier)(NSString*) = ^(NSString* identifier) {
      if (identifier.length > 0 && ![identifiers containsObject:identifier]) [identifiers addObject:identifier];
    };
    if (@available(macOS 11.0, *)) { addIdentifier(UTTypePDF.identifier); }
    addIdentifier(@"com.adobe.pdf");
    return identifiers;
}

static NSString* spdf_app_bundle_identifier(void) {
    NSString* identifier = NSBundle.mainBundle.bundleIdentifier;
    return identifier.length > 0 ? identifier : @"com.intuition.shenzhenpdf";
}

static BOOL spdf_pdf_role_handler_is_bundle(NSString* contentType, LSRolesMask role, NSString* bundleIdentifier) {
    CFStringRef handler = LSCopyDefaultRoleHandlerForContentType((__bridge CFStringRef)contentType, role);
    NSString* currentHandler = CFBridgingRelease(handler);
    return [currentHandler isEqualToString:bundleIdentifier];
}

BOOL SPDFMacIsDefaultPDFReader(void) {
    NSString* bundleIdentifier = spdf_app_bundle_identifier();
    for (NSString* contentType in spdf_pdf_content_type_identifiers()) {
        if (!spdf_pdf_role_handler_is_bundle(contentType, kLSRolesViewer, bundleIdentifier) ||
            !spdf_pdf_role_handler_is_bundle(contentType, kLSRolesEditor, bundleIdentifier) ||
            !spdf_pdf_role_handler_is_bundle(contentType, kLSRolesAll, bundleIdentifier))
            return NO;
    }
    return YES;
}

static BOOL spdf_pdf_handler_preferences_are_bundle(NSString* bundleIdentifier) {
    NSString* domain = @"com.apple.LaunchServices/com.apple.launchservices.secure";
    NSString* key = @"LSHandlers";
    id handlersObject =
        CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain));
    if (![handlersObject isKindOfClass:NSArray.class]) return NO;
    for (NSString* contentType in spdf_pdf_content_type_identifiers()) {
        BOOL found = NO;
        for (NSDictionary* handler in (NSArray*)handlersObject) {
            if (![handler isKindOfClass:NSDictionary.class]) continue;
            if (![handler[@"LSHandlerContentType"] isEqualToString:contentType]) continue;
            found = YES;
            if (![handler[@"LSHandlerRoleAll"] isEqualToString:bundleIdentifier] ||
                ![handler[@"LSHandlerRoleViewer"] isEqualToString:bundleIdentifier] ||
                ![handler[@"LSHandlerRoleEditor"] isEqualToString:bundleIdentifier])
                return NO;
            break;
        }
        if (!found) return NO;
    }
    return YES;
}

static BOOL spdf_write_pdf_handler_preferences(NSString* bundleIdentifier) {
    NSString* domain = @"com.apple.LaunchServices/com.apple.launchservices.secure";
    NSString* key = @"LSHandlers";
    id handlersObject =
        CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain));
    NSMutableArray* handlers =
        [handlersObject isKindOfClass:NSArray.class] ? [handlersObject mutableCopy] : [NSMutableArray array];
    NSInteger now = (NSInteger)NSDate.date.timeIntervalSinceReferenceDate;
    for (NSString* contentType in spdf_pdf_content_type_identifiers()) {
        NSMutableDictionary* handler = nil;
        for (NSUInteger i = 0; i < handlers.count; ++i) {
            NSDictionary* existing = [handlers[i] isKindOfClass:NSDictionary.class] ? handlers[i] : nil;
            if (![existing[@"LSHandlerContentType"] isEqualToString:contentType]) continue;
            handler = [existing mutableCopy];
            handlers[i] = handler;
            break;
        }
        if (!handler) {
            handler = [@{@"LSHandlerContentType" : contentType} mutableCopy];
            [handlers addObject:handler];
        }

        handler[@"LSHandlerRoleAll"] = bundleIdentifier;
        handler[@"LSHandlerRoleViewer"] = bundleIdentifier;
        handler[@"LSHandlerRoleEditor"] = bundleIdentifier;
        handler[@"LSHandlerModificationDate"] = @(now);
        NSMutableDictionary* preferredVersions =
            [handler[@"LSHandlerPreferredVersions"] isKindOfClass:NSDictionary.class]
                ? [handler[@"LSHandlerPreferredVersions"] mutableCopy]
                : [NSMutableDictionary dictionary];
        preferredVersions[@"LSHandlerRoleAll"] = @"-";
        preferredVersions[@"LSHandlerRoleViewer"] = @"-";
        preferredVersions[@"LSHandlerRoleEditor"] = @"-";
        handler[@"LSHandlerPreferredVersions"] = preferredVersions;
    }

    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFArrayRef)handlers, (__bridge CFStringRef)domain);
    return CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
}

static void spdf_restart_launch_services_cache(void) {
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/killall"];
    task.arguments = @[ @"lsd" ];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException* exception) { (void)exception; }
}

BOOL SPDFMacMakeDefaultPDFReader(NSError** error) {
    NSString* bundleIdentifier = spdf_app_bundle_identifier();
    if (NSBundle.mainBundle.bundleURL) LSRegisterURL((__bridge CFURLRef)NSBundle.mainBundle.bundleURL, true);

    OSStatus status = noErr;
    for (NSString* contentType in spdf_pdf_content_type_identifiers()) {
        OSStatus viewerStatus = LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)contentType, kLSRolesViewer,
                                                                      (__bridge CFStringRef)bundleIdentifier);
        if (viewerStatus != noErr && status == noErr) status = viewerStatus;
        OSStatus editorStatus = LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)contentType, kLSRolesEditor,
                                                                      (__bridge CFStringRef)bundleIdentifier);
        if (editorStatus != noErr && status == noErr) status = editorStatus;
        OSStatus allStatus = LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)contentType, kLSRolesAll,
                                                                   (__bridge CFStringRef)bundleIdentifier);
        if (allStatus != noErr && status == noErr) status = allStatus;
    }
    if (status == noErr && SPDFMacIsDefaultPDFReader()) return YES;
    if (spdf_write_pdf_handler_preferences(bundleIdentifier)) {
        if (NSBundle.mainBundle.bundleURL) LSRegisterURL((__bridge CFURLRef)NSBundle.mainBundle.bundleURL, true);
        if (!SPDFMacIsDefaultPDFReader()) spdf_restart_launch_services_cache();
        for (int attempt = 0; attempt < 10; ++attempt) {
            if (SPDFMacIsDefaultPDFReader() || spdf_pdf_handler_preferences_are_bundle(bundleIdentifier)) return YES;
            [NSThread sleepForTimeInterval:0.1];
        }
    }
    if (status == noErr) status = paramErr;

    if (error) {
        *error = [NSError
            errorWithDomain:@"com.intuition.shenzhenpdf.default-reader"
                       code:status
                   userInfo:@{
                       NSLocalizedDescriptionKey : @"macOS did not accept Shenzhen PDF as the default PDF reader.",
                       NSLocalizedRecoverySuggestionErrorKey :
                           @"Open Finder, select a PDF, choose File > Get Info, then set Open With to "
                           @"Shenzhen PDF and click Change All."
                   }];
    }
    return NO;
}
