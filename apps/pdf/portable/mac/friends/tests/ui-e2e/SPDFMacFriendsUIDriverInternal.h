// friends-ui-e2e's driver: what its files share beyond SPDFMacFriendsUIE2E.h (internal).

#import "SPDFMacFriendsUIE2E.h"

NS_ASSUME_NONNULL_BEGIN

// While a press is on its way (UIClick), the app answers as active and the window it goes to as key, so a control
// tracks it; the replacements that say so are installed by UIKeepWindowsOffscreen.
extern BOOL UIClickMakesActive;
extern __weak NSWindow* _Nullable UIClickWindow;

// Any of this run's windows on a screen: off it at once, and the run fails (UIWait calls it on every turn).
void UICheckOffscreen(void);

NS_ASSUME_NONNULL_END
