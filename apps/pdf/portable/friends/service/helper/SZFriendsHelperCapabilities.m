// What this helper announces in its welcome (PROTOCOL.md § Capabilities), from the services it runs.

#import "service/helper/SZFriendsHelperFacts.h"
#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"

NS_ASSUME_NONNULL_BEGIN

NSArray<NSString *> *SZFriendsHelperCapabilityList(SZFriendsHelperServices *services) {
    // Only what this helper really does: a view must not offer a search that cannot find anyone. A helper under
    // SZFRIENDS_STATE_DIR runs only the adapters a test asked for and checks in only with a loopback host.
    NSMutableArray<NSString *> *capabilities = [NSMutableArray array];
    SZFriendsNearbyService *nearby = services.nearby;
    if ([nearby hasAdapterForMethod:SZFriendsDiscoveryMethodNetwork]) [capabilities addObject:@"nearby.network"];
    if ([nearby hasAdapterForMethod:SZFriendsDiscoveryMethodBluetooth]) [capabilities addObject:@"nearby.bluetooth"];
    if (services.checkInSetup != nil) [capabilities addObject:@"host.checkin"];
    // Links are made for the Friends host's pages, so only a helper that checks in offers them (PROTOCOL.md § Links).
    if (services.checkInSetup != nil && services.store != nil && services.identity != nil) {
        [capabilities addObject:@"links"];
    }
    // conversation.preview: a conversation's newest items that mark nothing read (PROTOCOL.md § Views).
    [capabilities
        addObjectsFromArray:@[ @"messages.status", @"messages.cancel", @"mentions", @"conversation.preview" ]];
    // One profile on several computers: Your computers, joining, You (PROTOCOL.md § Devices).
    if (services.store != nil && services.identity != nil && nearby != nil) [capabilities addObject:@"devices"];
    // Files a friend sent come back from them when none of the person's computers has them (§ Getting a file again).
    if (services.store != nil && services.identity != nil && nearby != nil) [capabilities addObject:@"files.again"];
    // Received files go to Downloads or the folder the person chose (PROTOCOL.md § Views, settings and received).
    if (services.transfers != nil) [capabilities addObject:@"received.folder"];
    // A document sent with what belongs to it goes as its archive and arrives as its folder (PROTOCOL.md § Intents,
    // Documents).
    if (services.transfers != nil) [capabilities addObject:@"files.documents"];
    if (nearby.reachesFriendsOnline) [capabilities addObject:@"online"];
    // This helper posts system notifications (PROTOCOL.md § Notifications).
    if (services.notifier != nil) [capabilities addObject:@"notifications"];
    return capabilities;
}

NS_ASSUME_NONNULL_END
