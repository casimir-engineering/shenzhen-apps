// Stand-ins for the Friends views' value classes (portable/friends/mac/SZFriendsHost.h), so the host adapter's
// tests link without the views area's sources, which are built and tested by their own suite.

#import "mac/SZFriendsHost.h"

@implementation SZFriendsAppearance
@end

@implementation SZFriendsAttachableItem
@end

@implementation SZFriendsSearchResult
@end

@implementation SZFriendsAssistantResult
@end

// The views' link menu, recorded instead of shown: each call as @[view, URL, words, point] in
// SPDFMacFriendsFakeLinkMenus, so a test sees which links reach Friends' own menu.
NSMutableArray<NSArray*>* SPDFMacFriendsFakeLinkMenus;

void SZFriendsShowLinkMenuInView(NSView* view, NSURL* url, NSString* words, NSPoint point) {
    if (!SPDFMacFriendsFakeLinkMenus) SPDFMacFriendsFakeLinkMenus = [NSMutableArray array];
    [SPDFMacFriendsFakeLinkMenus addObject:@[view, url, words, [NSValue valueWithPoint:point]]];
}
