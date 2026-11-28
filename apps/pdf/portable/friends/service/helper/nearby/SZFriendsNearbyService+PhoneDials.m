// Bluetooth to a phone: the phone dials (+Dial asks this before it dials a phone over Bluetooth itself).
//
// Whoever dials an L2CAP channel is the link's central, and the central sets the connection interval. A phone as
// central asks for 11.25 to 15 ms (CONNECTION_PRIORITY_HIGH) and gets 15 ms; a Mac as central keeps 30 ms, since
// CoreBluetooth cannot ask for less and a Mac refuses the phone's request (Apple accepts only ranges from 15 ms up).
// Measured 2026-11-28 between this Mac and a POCO F7, with the phone's packets at full size (it asks for the ATT MTU):
// 85 to 98 KB/s each way on a link the phone dialled, 20 to 57 KB/s on one the Mac dialled. So a Mac waits before
// it dials a phone over Bluetooth: long enough for a phone in the foreground, which sees the Mac too, to dial first
// (the race then keeps its session); a phone in the background cannot scan, so the Mac's dial still comes, later.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"
#import "service/sync/SZFriendsSync.h"

// A phone's dial takes about 3.5 s from seeing the Mac: its 0.5 s stagger, a GATT read, 1.5 s for the Mac to set
// up its side, the channel and the handshake.
const NSTimeInterval SZFriendsBluetoothDialDeferToPhone = 8;

static BOOL SZFriendsIsPhoneSystem(NSString *system) {
    // Android only: an iPhone as central uses 30 ms too, so deferring to one gains nothing.
    return [system.lowercaseString hasPrefix:@"android"];
}

static NSString *SZFriendsPhoneDialsKeyHex(NSData *key) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:key.length * 2];
    const uint8_t *bytes = key.bytes;
    for (NSUInteger i = 0; i < key.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

@implementation SZFriendsNearbyService (PhoneDials)

- (BOOL)bluetoothPeerDialsItself:(SZFriendsDialPlan *)plan {
    SZFriendsStore *store = self.services.store;
    if (plan.purpose == SZFriendsLinkPurposeOwnDevice && plan.ownDeviceHex != nil) {
        NSData *root = [self activeSyncEngine].rootKey;
        if (root == nil) return NO;
        for (SZFriendsDeviceRecord *device in [store devicesOfRootKey:root]) {
            if ([SZFriendsPhoneDialsKeyHex(device.deviceKey) isEqualToString:plan.ownDeviceHex.lowercaseString]) {
                return SZFriendsIsPhoneSystem(device.system);
            }
        }
        return NO;
    }
    if (plan.purpose == SZFriendsLinkPurposeFriend && plan.conversationID != nil) {
        // Which of a friend's devices a Bluetooth sighting is cannot be told before the session: only a friend whose
        // every device is a phone is left to dial.
        NSData *root = [store personWithConversationID:plan.conversationID].identityKey;
        if (root == nil) return NO;
        NSUInteger phones = 0;
        for (SZFriendsDeviceRecord *device in [store devicesOfRootKey:root]) {
            if (device.state != SZFriendsChainDeviceAuthorized) continue;
            if (!SZFriendsIsPhoneSystem(device.system)) return NO;
            phones++;
        }
        return phones > 0;
    }
    return NO;
}

@end
