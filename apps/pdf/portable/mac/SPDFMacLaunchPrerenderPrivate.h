#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacLaunchWorkPolicy.h"

#include "shenzhen_pdf_core.h"

// Launch prerender (implemented in SPDFMacLaunchPrerender.mm). Kicked off from
// main() before AppKit init; opens the document the launch will select
// (restored active tab, or the CLI/Finder-opened file) and, when the restore
// zoom is viewport-independent, renders its preferred page on a background
// thread while NSApplication init and the window build overlap. Adopted later
// only on an exact (path, attributes, page, zoom, scale) match; any mismatch
// falls back to the existing synchronous path.
@interface ShenzhenMacDelegate (LaunchPrerender)
- (void)startLaunchPrerender;
- (void)retargetLaunchPrerenderToOpenedPath:(NSString*)path;
- (void)beginLaunchPrerenderForNamedPath:(NSString*)namedPath;
- (spdf_document*)takeLaunchPrerenderedDocumentForPath:(NSString*)path attributes:(NSDictionary*)attributes;
- (void)releaseLaunchPrerenderedMetadata;
@end

// Coordinator services the prerender worker reuses; implemented in
// ShenzhenPDFMac.mm alongside the rest of the delegate.
@interface ShenzhenMacDelegate (LaunchPrerenderHost)
- (id)stateObjectFromFile:(NSString*)name;
- (NSString*)pathForStateFile:(NSString*)name;
- (BOOL)pathIsOnCloudStorage:(NSString*)path;
- (BOOL)sourcePathIsReadOnly:(NSString*)path;
- (NSDictionary*)readOnlySourceAttributesForPath:(NSString*)path;
- (spdf_document*)openSpdfDocumentAtPath:(NSString*)path
                              sourcePath:(NSString*)sourcePath
                                  status:(spdf_open_status*)status
                                   error:(char*)err
                             errorLength:(size_t)errLen;
@end

// Discard a never-adopted prerender off-main. Called from the launch tail in
// ShenzhenPDFMac.mm as well as from the retarget path.
void spdf_discard_launch_prerender(void);

// Helpers defined in ShenzhenPDFMac.mm and reused by the prerender worker.
id spdf_state_object_from_yaml_data(NSData* data);
unsigned long long spdf_file_size_from_attributes(NSDictionary* attributes);
NSDate* spdf_file_modification_date_from_attributes(NSDictionary* attributes);
extern const CGFloat kMinZoom;
extern const CGFloat kMaxZoom;
