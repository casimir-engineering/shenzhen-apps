// The Mac's real Wi-Fi for the Wi-Fi Direct boost (ADR 0019): CoreWLAN, Location Services for network names, and
// Network.framework's path monitor. Created only for a person's own home; tests use a mock of SZFriendsWiFiJoining.

#import <Foundation/Foundation.h>

#import "service/transfer/SZFriendsDirectWiFiBoost.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsCoreWLANWiFi : NSObject <SZFriendsWiFiJoining>
@end

NS_ASSUME_NONNULL_END
