/* Keeps the widget probes from becoming a foreground app (macOS only; linked by SZFriendsGtkProbes alone).
 *
 * WHY: opening GDK's macOS display calls TransformProcessType(kProcessTransformToForegroundApplication) and then
 * -[NSApp activateIgnoringOtherApps:] (gdk/macos/gdkmacosdisplay.c, _gdk_macos_display_open), so every run of the
 * suite would put an icon in the Dock and take focus from whatever the person is typing in. dyld interposing from
 * this dylib, which the probe executable links, replaces that one call for every image in the process: the probes
 * stay a background process, which cannot become active, and no window of theirs is ever shown anyway.
 *
 * The probe calls TransformProcessType(NULL, 0) itself before opening the display and checks the count rose. The real
 * function would refuse a NULL process with an error and do nothing, so a missing interposer is caught harmlessly. */

#include <ApplicationServices/ApplicationServices.h>

static int transform_calls;

int szfriends_gtk_quiet_transform_calls(void) {
    return transform_calls;
}

static OSStatus quiet_transform(const ProcessSerialNumber *process, ProcessApplicationTransformState state) {
    (void)process, (void)state;
    transform_calls++;
    return noErr;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} szfriends_gtk_quiet_interposers[] = {{(const void *)quiet_transform, (const void *)TransformProcessType}};
