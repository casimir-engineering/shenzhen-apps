// friends-ui-e2e's flow for how people nearby were found (SPDFMacFriendsUIE2E.h): the owner's request of 2026-10-20,
// "it should say how it found the nearby device". Ana's helper meets three visible strangers, each a real helper:
// Lena on the loopback network only, Bao over the test Bluetooth air only (another network type, so the network
// cannot see him), and Chen over both. Ana's Nearby tab says so on each row, with the icons.

#import "SPDFMacFriendsUIE2E.h"

#import "mac/SZFriendsListPage.h"

static SZFriendsRowView* UIFoundRow(UIRig* rig, NSString* title) {
    for (SZFriendsRowView* row in rig.listPage.nearbyPane.personRows)
        if ([row.accessibilityLabel hasPrefix:title] && UIVisible(row)) return row;
    return nil;
}

// A visible stranger: a helper with `env`, named and visible for the moment.
static SZFE2EClient* UIStartStranger(SZFE2EWorld* world, NSString* name, NSDictionary* env) {
    SZFE2EHelper* helper = [world helperNamed:name.lowercaseString];
    NSString* home = [helper.stateDirectory stringByAppendingString:@"-home"];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary* all = [UIDeviceEnvironment(name) mutableCopy];
    all[@"HOME"] = home;
    [all addEntriesFromDictionary:env];
    helper.extraEnvironment = all;
    if (![helper start]) return nil;
    SZFE2EClient* client = [SZFE2EClient clientForHelper:helper];
    if (!client || ![[client intent:@"activate" fields:nil][@"ok"] boolValue]) return nil;
    if (![[client intent:@"set_name" fields:@{@"name" : name}][@"ok"] boolValue]) return nil;
    if (![[client intent:@"start_visibility" fields:nil][@"ok"] boolValue]) return nil;
    return client;
}

static BOOL UIFoundNearby(UIRig* rig, SZFE2EWorld* world) {
    UIBeginFlow(rig, @"found");
    SZFE2EClient* ana = [SZFE2EClient clientForHelper:rig.helper];
    EXPECT(rig, ana && [[ana intent:@"set_name" fields:@{@"name" : @"Ana"}][@"ok"] boolValue] &&
                    [[ana intent:@"activate" fields:nil][@"ok"] boolValue],
           "Ana is named and looking");
    NSDictionary* air = @{@"SZFRIENDS_E2E_BLUETOOTH_DIR" : world.bluetoothDirectory};
    NSString* elsewhere = [NSString stringWithFormat:@"_szfo%08x._tcp", arc4random()];
    NSMutableDictionary* bluetoothOnly = [air mutableCopy];
    bluetoothOnly[@"SZFRIENDS_TEST_SERVICE_TYPE"] = elsewhere;
    SZFE2EClient* lena = UIStartStranger(world, @"Lena", @{});
    SZFE2EClient* bao = lena ? UIStartStranger(world, @"Bao", bluetoothOnly) : nil;
    SZFE2EClient* chen = bao ? UIStartStranger(world, @"Chen", air) : nil;
    EXPECT(rig, lena && bao && chen, "three strangers are visible");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    NSString* why = nil;
    EXPECT(rig, UIClick(rig.listPage.nearbyTab, &why), "the Nearby tab: %@", why);
    struct {
        NSString* name;
        NSString* label;
        NSArray* methods;
    } expected[] = {
        {@"Lena", @"Local network", @[ @"lan" ]},
        {@"Bao", @"Bluetooth", @[ @"bluetooth" ]},
        {@"Chen", @"Local network and Bluetooth", @[ @"lan", @"bluetooth" ]},
    };
    for (auto& person : expected) {
        NSString* name = person.name;
        NSString* label = person.label;
        NSArray* methods = person.methods;
        EXPECT(rig, UIWait(40, ^BOOL {
                   SZFriendsRowView* row = UIFoundRow(rig, name);
                   return [row.foundLabel isEqualToString:label] && [row.foundMethods isEqualToArray:methods];
               }),
               "%@'s row says %@ (%@): %@ %@\n%@", name, label, methods, UIFoundRow(rig, name).foundLabel,
               UIFoundRow(rig, name).foundMethods, UIDescribe(rig.content));
    }
    UIShot(rig, @"found");
    [lena close];
    [bao close];
    [chen close];
    [ana close];
    return YES;
}

BOOL UIFlowFound(SZFE2EWorld* world, UIVariant* variant) {
    [world beginScenario:[@"found-" stringByAppendingString:variant.name]];
    UIRig* rig = UIStartRig(world, variant, @"ana", @{@"SZFRIENDS_E2E_BLUETOOTH_DIR" : world.bluetoothDirectory});
    if (!rig) {
        UIFail(nil, __FILE__, __LINE__, "Ana's helper starts", @"");
        [world endScenario];
        UIRecord(variant, @"found: start", NO);
        return NO;
    }
    int failuresBefore = UIFailures;
    BOOL passed = UIFoundNearby(rig, world) && UIFailures == failuresBefore;
    UIRecord(variant, @"Nearby says how each person was found: local network, Bluetooth, both", passed);
    if (!passed) [world printLogs];
    UIStopRig(rig);
    [world endScenario];
    return passed;
}
