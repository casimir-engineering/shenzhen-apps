#pragma once
#import "SPDFMacDelegatePrivate.h"

// Raw camera sensor frames (.raw, .raw10), drawn by core/spdf_sensor_raw.c. Installed when the app loads, before anything
// opens a document; the Bayer order a reader picks for a frame is kept per file in bayer-orders.yaml.
void SPDFMacInstallSensorFrames(void);

@interface ShenzhenMacDelegate (SensorFrames)
// The picture's "Bayer Order" submenu, added to the document context menu for a sensor frame.
- (void)addBayerOrderItemsToMenu:(NSMenu*)menu;
- (void)chooseBayerOrder:(NSMenuItem*)sender;
@end
