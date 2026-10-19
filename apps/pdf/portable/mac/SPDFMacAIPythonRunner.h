#pragma once
// Running one request through the sandbox helper (mac/python-sandbox/SPDFPythonSandbox.h, embedded in
// Contents/Helpers/spdf-python-sandbox): JSON in on stdin, JSON out on stdout. The helper enforces every limit itself;
// this side only adds an outer deadline and Stop, for a helper that stopped answering.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPDFMacAIPythonRunCompletion)(NSDictionary* result);

@protocol SPDFMacAIPythonRunning <NSObject>
// Starts one run. `completion` runs once, on the main thread, with the helper's result or {"ok": false, "error",
// "message"} when there is none. The returned block stops the run; calling it after completion does nothing.
- (dispatch_block_t)runRequest:(NSDictionary*)request completion:(SPDFMacAIPythonRunCompletion)completion;
@end

@interface SPDFMacAIPythonSandboxRunner : NSObject <SPDFMacAIPythonRunning>
- (instancetype)initWithHelperPath:(NSString*)helperPath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString* helperPath;
// Seconds before the run is stopped from outside: 45, the helper's own 30 s wall limit plus reading results back.
@property(nonatomic) NSTimeInterval timeout;
// Seconds between asking the helper to stop (SIGTERM: it kills the code, deletes the work directory and reports) and
// ending its whole process group: 5.
@property(nonatomic) NSTimeInterval stopGrace;
@end

// Contents/Helpers/spdf-python-sandbox in `bundle` when it is there and executable; nil in a build without it (the
// headless suites that link the reader), which then offers no Python tool.
NSString* _Nullable SPDFMacAIPythonHelperPath(NSBundle* bundle);

NS_ASSUME_NONNULL_END
