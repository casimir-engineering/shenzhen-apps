#pragma once
#import <Foundation/Foundation.h>

// The launch's big state files, read and parsed on a background queue while AppKit starts (SPDFMacStatePrefetch.mm).
void spdf_mac_prefetch_launch_state(void);
// The parsed object for `path` when it was prefetched and the file is still the one that was read (same inode, size
// and modification time); nil otherwise, and the caller reads it itself. Each prefetched file is handed out once.
id spdf_mac_take_prefetched_state(NSString* path);
