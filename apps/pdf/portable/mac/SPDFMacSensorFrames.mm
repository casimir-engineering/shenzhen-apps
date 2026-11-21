// Raw camera sensor frames: see SPDFMacSensorFrames.h.
#import "SPDFMacSensorFrames.h"
#import "SPDFMacStateDirectory.h"
#include "spdf_sensor_raw.h"
#include "spdf_yaml.h"
#include <os/lock.h>

static NSString* const kOrdersFile = @"bayer-orders.yaml";
static os_unfair_lock ordersLock = OS_UNFAIR_LOCK_INIT;

static NSString* OrdersPath(void) { return [SPDFMacStateDirectoryPath() stringByAppendingPathComponent:kOrdersFile]; }

// Read on every open, so a pick made in another window applies to the next frame opened here.
static NSDictionary* ReadOrders(void) {
    NSMutableData* data = [[NSData dataWithContentsOfFile:OrdersPath()] mutableCopy];
    if (!data) return @{};
    [data appendBytes:"" length:1];
    char* json = spdf_json_from_yaml((const char*)data.bytes);
    if (!json) return @{};
    NSData* text = [NSData dataWithBytesNoCopy:json length:strlen(json) freeWhenDone:YES];
    id object = [NSJSONSerialization JSONObjectWithData:text options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static void WriteOrders(NSDictionary* orders) {
    NSMutableData* json = [[NSJSONSerialization dataWithJSONObject:orders options:NSJSONWritingSortedKeys
                                                             error:nil] mutableCopy];
    if (!json) return;
    [json appendBytes:"" length:1];
    char header[128];
    spdf_state_header_for_file(kOrdersFile.UTF8String, header, sizeof(header));
    char* yaml = spdf_yaml_from_json((const char*)json.bytes, header);
    if (!yaml) return;
    NSData* data = [NSData dataWithBytesNoCopy:yaml length:strlen(yaml) freeWhenDone:YES];
    [NSFileManager.defaultManager createDirectoryAtPath:SPDFMacStateDirectoryPath() withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    [data writeToFile:OrdersPath() atomically:YES];
}

static int OrderNamed(id name) {
    if (![name isKindOfClass:NSString.class]) return SPDF_SENSOR_ORDER_AUTO;
    for (int order = 0; order < SPDF_SENSOR_ORDER_COUNT; ++order)
        if ([name isEqualToString:@(spdf_sensor_raw_order_name(order))]) return order;
    return SPDF_SENSOR_ORDER_AUTO;
}

static int LookupOrder(const char* path) {
    @autoreleasepool {
        if (!path) return SPDF_SENSOR_ORDER_AUTO;
        os_unfair_lock_lock(&ordersLock);
        NSDictionary* orders = ReadOrders();
        os_unfair_lock_unlock(&ordersLock);
        return OrderNamed(orders[@(path)]);
    }
}

void SPDFMacInstallSensorFrames(void) {
    spdf_sensor_raw_set_order_lookup(LookupOrder);
    spdf_sensor_raw_install();
}

// Before main(): the launch prerender, the szpdf tool and every window open documents through spdf_open.
__attribute__((constructor)) static void InstallAtLoad(void) { SPDFMacInstallSensorFrames(); }

@interface ShenzhenMacDelegate (SensorFramesPrivate)
- (void)loadSelectedTab;
@end

@implementation ShenzhenMacDelegate (SensorFrames)

// The path the frame was opened from: a read-only original is shown from its working copy.
- (NSString*)sensorFrameOpenedPath {
    return _workingPath.length ? _workingPath : _path;
}

- (void)addBayerOrderItemsToMenu:(NSMenu*)menu {
    if (!_doc || !spdf_sensor_raw_path(_path.fileSystemRepresentation)) return;
    int shown = spdf_sensor_raw_shown_order([self sensorFrameOpenedPath].fileSystemRepresentation);
    NSMenuItem* parent = [[NSMenuItem alloc] initWithTitle:@"Bayer Order" action:nil keyEquivalent:@""];
    NSMenu* orders = [[NSMenu alloc] initWithTitle:@"Bayer Order"];
    for (int order = 0; order < SPDF_SENSOR_ORDER_COUNT; ++order) {
        NSMenuItem* item = [orders addItemWithTitle:@(spdf_sensor_raw_order_name(order))
                                             action:@selector(chooseBayerOrder:)
                                      keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(order);
        item.state = order == shown ? NSControlStateValueOn : NSControlStateValueOff;
    }
    parent.submenu = orders;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:parent];
}

- (void)chooseBayerOrder:(NSMenuItem*)sender {
    SPDFDocumentTab* tab = [self selectedTab];
    NSString* opened = [self sensorFrameOpenedPath];
    if (!tab || !_path.length || ![sender.representedObject isKindOfClass:NSNumber.class]) return;
    NSString* name = @(spdf_sensor_raw_order_name([sender.representedObject intValue]) ?: "");
    if (!name.length) return;
    os_unfair_lock_lock(&ordersLock);
    NSMutableDictionary* orders = [ReadOrders() mutableCopy];
    orders[_path] = name;
    if (![opened isEqualToString:_path]) orders[opened] = name;
    WriteOrders(orders);
    os_unfair_lock_unlock(&ordersLock);
    [self discardCachedRuntimeForTab:tab];
    [self loadSelectedTab];
}

@end
