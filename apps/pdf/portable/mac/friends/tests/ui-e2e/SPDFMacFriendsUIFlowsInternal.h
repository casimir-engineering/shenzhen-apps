// friends-ui-e2e's flows: what the files of one person's flows share beyond SPDFMacFriendsUIE2E.h (internal).

#import "SPDFMacFriendsUIE2E.h"

@class SZFriendsSettingsSection;

NS_ASSUME_NONNULL_BEGIN

// The list's footer as the observer last saw it, and the name saved in it (nil when none).
NSDictionary* _Nullable UIFooter(UIRig* rig);
NSString* _Nullable UISavedName(UIRig* rig);

// Clicks `view` (nil: not found) and records a failure with `what` when no click reaches it. CLICK returns NO from
// the enclosing flow then.
BOOL UIClickOrFail(UIRig* rig, NSView* _Nullable view, NSString* what, const char* file, int line);
#define CLICK(rig, view, what)                                                                                     \
    do {                                                                                                           \
        if (!UIClickOrFail(rig, view, what, __FILE__, __LINE__)) return NO;                                       \
    } while (0)

// Settings in a window of its own, as the reader's Settings shows the section; the caller closes it
// (SPDFMacFriendsUISettingsFlows.mm, with the permission flow beside it).
NSWindow* _Nullable UISettingsWindow(UIRig* rig, SZFriendsSettingsSection* section);

// Steps of the solo run, in SPDFMacFriendsUISettingsFlows.mm.
BOOL UISettingsAndReset(UIRig* rig);
BOOL UINameSavedElsewhere(UIRig* rig);

NS_ASSUME_NONNULL_END
