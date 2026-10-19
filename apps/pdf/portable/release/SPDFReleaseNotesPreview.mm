#import <AppKit/AppKit.h>

#import "SPDFUpdater.h"

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <release-notes.md> <release-tag>\n", argv[0]);
            return 2;
        }
        NSString* path = [NSString stringWithUTF8String:argv[1]];
        NSString* tag = [NSString stringWithUTF8String:argv[2]];
        NSError* error = nil;
        NSString* body = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if (!body) {
            fprintf(stderr, "Could not read release notes: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert* alert = spdf_make_update_available_alert(tag, @"previous release", body);
        [alert runModal];
        return 0;
    }
}
