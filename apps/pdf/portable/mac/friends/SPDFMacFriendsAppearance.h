// The reader's chrome tokens for the Friends views (SPDFMacCollectionStyle.mm, SPDFMacChromeColors.h), so the dropdown
// matches the title bar it hangs from.
//
// The views' defaults copy these values (portable/friends/mac/SZFriendsHostValues.m), so the views' own renders show
// what ships. The reader still passes its own colours, so Friends follows the reader's palette if that changes,
// rather than whatever the views last copied. Hover gets its own token: the reader's "selected" marks the selected
// chapter or chat, and a hovered row tinted with it read as selected.

#import <AppKit/AppKit.h>
#import "mac/SZFriendsHost.h"

NS_ASSUME_NONNULL_BEGIN

SZFriendsAppearance* SPDFMacFriendsReaderAppearance(void);

NS_ASSUME_NONNULL_END
