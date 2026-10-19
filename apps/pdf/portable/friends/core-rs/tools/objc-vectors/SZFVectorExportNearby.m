// Vector export: the Bluetooth presence characteristic as SZFriendsBluetoothPresence encodes and decodes it, so a
// phone or a Linux laptop on the Rust core reads a Mac's value and the Mac reads theirs.

#import "SZFVectorExport.h"

#import "service/discovery/SZFriendsBluetoothRadio.h"

static NSData *SZFTag(NSString *label) {
    return [SZFDerive(label, 16) subdataWithRange:NSMakeRange(0, 8)];
}

static NSDictionary *SZFPresenceCase(NSString *name, SZFriendsBluetoothPresence *presence) {
    NSMutableArray *callbacks = [NSMutableArray array];
    for (NSData *tag in presence.callbackTags) [callbacks addObject:SZFHexString(tag)];
    return @{
        @"name" : name,
        @"tag" : presence.presenceTag ? SZFHexString(presence.presenceTag) : [NSNull null],
        @"callback_tags" : callbacks,
        @"hidden_psm" : @(presence.hiddenPSM),
        @"public_psm" : @(presence.publicPSM),
        @"value" : SZFHexString(presence.value),
    };
}

NSDictionary *SZFExportBluetooth(void) {
    NSMutableArray<NSData *> *five = [NSMutableArray array];
    for (NSString *label in @[ @"cb one", @"cb two", @"cb three", @"cb four", @"cb five" ]) {
        [five addObject:SZFTag(label)];
    }
    NSArray *encode = @[
        SZFPresenceCase(@"hidden, tag and slots", [[SZFriendsBluetoothPresence alloc]
                                                       initWithPresenceTag:SZFTag(@"presence")
                                                              callbackTags:[five subarrayWithRange:NSMakeRange(0, 4)]
                                                                 hiddenPSM:0x0081
                                                                 publicPSM:0]),
        SZFPresenceCase(@"no tag yet", [[SZFriendsBluetoothPresence alloc] initWithPresenceTag:nil
                                                                                   callbackTags:@[]
                                                                                      hiddenPSM:0
                                                                                      publicPSM:0]),
        SZFPresenceCase(@"public only", [[SZFriendsBluetoothPresence alloc] initWithPresenceTag:nil
                                                                                    callbackTags:@[]
                                                                                       hiddenPSM:0
                                                                                       publicPSM:0x10F5]),
        SZFPresenceCase(@"five slots keep four", [[SZFriendsBluetoothPresence alloc]
                                                      initWithPresenceTag:SZFTag(@"presence")
                                                             callbackTags:five
                                                                hiddenPSM:0xFFFF
                                                                publicPSM:0x0101]),
    ];
    // Values as another device might send them; `accepted` is the helper's verdict.
    NSMutableArray *decode = [NSMutableArray array];
    NSData *hidden = [[SZFriendsBluetoothPresence alloc] initWithPresenceTag:SZFTag(@"presence")
                                                                  callbackTags:@[ five[0] ]
                                                                     hiddenPSM:0x0083
                                                                     publicPSM:0]
                         .value;
    NSMutableData *longer = [hidden mutableCopy];
    [longer appendBytes:"\x07\x07\x07" length:3];
    NSMutableData *version2 = [hidden mutableCopy];
    ((uint8_t *)version2.mutableBytes)[0] = 2;
    NSMutableData *overclaim = [hidden mutableCopy];
    ((uint8_t *)overclaim.mutableBytes)[14] = 2;
    NSMutableData *fiveClaimed = [hidden mutableCopy];
    ((uint8_t *)fiveClaimed.mutableBytes)[14] = 5;
    [fiveClaimed appendData:[NSMutableData dataWithLength:32]];
    NSMutableData *flagOff = [hidden mutableCopy];
    ((uint8_t *)flagOff.mutableBytes)[1] = 0;
    NSArray *inputs = @[
        @[ @"as encoded", hidden ], @[ @"longer", longer ], @[ @"version 2", version2 ],
        @[ @"short", [hidden subdataWithRange:NSMakeRange(0, 14)] ], @[ @"claims two tags", overclaim ],
        @[ @"claims five tags", fiveClaimed ], @[ @"flag off", flagOff ]
    ];
    for (NSArray *input in inputs) {
        SZFriendsBluetoothPresence *presence = [SZFriendsBluetoothPresence presenceFromValue:input[1]];
        NSMutableDictionary *entry = [@{@"name" : input[0], @"value" : SZFHexString(input[1])} mutableCopy];
        entry[@"accepted"] = @(presence != nil);
        if (presence) entry[@"decoded"] = SZFPresenceCase(input[0], presence);
        [decode addObject:entry];
    }
    return @{
        @"uuids" : @{
            @"service" : SZFriendsBluetoothServiceUUID,
            @"public" : SZFriendsBluetoothPublicUUID,
            @"presence_characteristic" : SZFriendsBluetoothPresenceCharacteristicUUID,
            @"public_characteristic" : SZFriendsBluetoothPublicCharacteristicUUID,
        },
        @"encode" : encode,
        @"decode" : decode,
    };
}
