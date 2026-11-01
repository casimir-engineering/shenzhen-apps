#pragma once
// The channel between the szpdf command-line tool (SPDFMacSzpdf.mm) and running ShenzhenPDF processes.
//
// Every reader process (a window is a process) listens, from after its first paint, on a Unix socket of its own:
// "<state dir>/Agent/<pid>.sock". The directory is 0700 and the socket 0600, both owned by the user, and the reader
// drops a connection whose peer is another user (getpeereid), so only this user's programs on this Mac can talk to
// it. Nothing goes over the network. One request per connection: a JSON object on one line, answered by one JSON
// object on one line.
//
// Foundation only, and tested headlessly (mac/tests/SPDFMacAgentChannelTests.mm).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The longest request or answer line, in bytes. A screenshot answers with a path, never with the picture.
FOUNDATION_EXPORT const NSUInteger SPDFMacAgentChannelMaxLine;

// "<stateDirectory>/Agent".
FOUNDATION_EXPORT NSString* SPDFMacAgentChannelDirectory(NSString* stateDirectory);
// "<stateDirectory>/Agent/<pid>.sock".
FOUNDATION_EXPORT NSString* SPDFMacAgentChannelSocketPath(NSString* stateDirectory, pid_t pid);
// The pid a socket's file name stands for ("123.sock" -> 123), or 0 for any other name.
FOUNDATION_EXPORT pid_t SPDFMacAgentChannelPIDFromName(NSString* name);
// YES when `path` fits a Unix socket address (sun_path holds 103 bytes and a NUL).
FOUNDATION_EXPORT BOOL SPDFMacAgentChannelPathFits(NSString* path);

// A request line checked before anything acts on it: an object with a known "command" and fields of the right types.
// Commands: "state", "open" {path, page?, heading?, front?, wait?}, "screenshot" {windowId, output},
// "comments-changed" {path}. nil with `error` set for anything else.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentChannelValidateRequest(NSData* line, NSError** error);
// One line of JSON (sorted keys) ending in "\n".
FOUNDATION_EXPORT NSData* SPDFMacAgentChannelEncode(NSDictionary* object);

// Creates the directory 0700 if needed and checks it: a real directory, owned by this user, closed to others.
FOUNDATION_EXPORT BOOL SPDFMacAgentChannelPrepareDirectory(NSString* directory, NSError** error);
// Sends `request` to the socket at `path` and waits up to `timeout` seconds for the answer.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentChannelExchange(NSString* path, NSDictionary* request,
                                                                      NSTimeInterval timeout, NSError** error);

NS_ASSUME_NONNULL_END
