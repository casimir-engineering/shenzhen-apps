// friends-ui-e2e's flows for three people: what the files of the pair run share (internal).

#import "SPDFMacFriendsUIFlowsInternal.h"

NS_ASSUME_NONNULL_BEGIN

// One of the two friends: a helper in its own home and the client library driving it.
@interface UIFriend : NSObject
@property(nonatomic, strong) SZFE2EHelper* helper;
@property(nonatomic, strong) SZFE2EClient* client;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* list;
@property(nonatomic, copy, nullable) NSString* anaID; // Ana's conversation in this friend's list
@end

// The row of `list` titled `title`, and the items of one kind in a conversation.
NSDictionary* _Nullable UIRowTitled(NSDictionary* list, NSString* title);
NSArray<NSDictionary*>* UIItems(NSDictionary* conversation, NSString* kind);
// The list row (a button) whose accessibility label starts with `title`.
SZFriendsRowView* _Nullable UIRow(UIRig* rig, NSString* title);

// The steps in SPDFMacFriendsUIRemoveFlows.mm.
BOOL UIRemoveFromList(UIRig* rig, SZFE2EWorld* world);
BOOL UIRemoveFromDetails(UIRig* rig);

NS_ASSUME_NONNULL_END
