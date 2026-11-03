// Prints the frontmost app as NSWorkspace reports it: "<bundle id> <pid>" (szpdf_e2e.py).
#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSRunningApplication* app = NSWorkspace.sharedWorkspace.frontmostApplication;
        printf("%s %d\n", app.bundleIdentifier.UTF8String ?: "?", app.processIdentifier);
    }
    return 0;
}
