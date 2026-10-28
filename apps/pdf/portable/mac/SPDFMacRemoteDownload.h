// One linked document downloading into the file the reader opens (docs/szpdf-links.md).
//
// The file gets its final size at once and each byte is written at its own offset as it arrives; the core reads the
// file through spdf_progressive (core/spdf_progressive.h) until every byte is in, and asks for the bytes it is
// waiting on. Where the server answers range requests:
//   - the first request is for the start of the file, and tells whether ranges work and how long the file is;
//   - a file that is not linearized has its end fetched next (trailer and cross-reference table), so it opens;
//   - the bytes a page being drawn waits for are fetched before anything else, newest request first: the page on
//     screen, or the one the reader jumped to, comes before the rest;
//   - the rest of the file is filled in from the start meanwhile.
// A server without ranges sends the file from the start in one stream, and pages show as they arrive.
//
// Everything runs on one private queue; the delegate hears on the main queue. The file's modification date stays put
// while bytes arrive, so the reader's file watcher sees no change until the download completes.

#import <Foundation/Foundation.h>

#include "spdf_progressive.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacRemoteDownloadFailure) {
    SPDFMacRemoteDownloadFailureNone = 0,
    SPDFMacRemoteDownloadFailureNetwork,     // no connection, a timeout, the connection dropped
    SPDFMacRemoteDownloadFailureCertificate, // the site's certificate is not valid
    SPDFMacRemoteDownloadFailureNotFound,    // 404, 410
    SPDFMacRemoteDownloadFailureForbidden,   // 401, 403
    SPDFMacRemoteDownloadFailureServer,      // any other error status
    SPDFMacRemoteDownloadFailureNotPDF,      // the bytes are not a PDF
    SPDFMacRemoteDownloadFailureInsecureRedirect, // redirected away from https
    SPDFMacRemoteDownloadFailureTooLarge,
    SPDFMacRemoteDownloadFailureDisk,
};

@class SPDFMacRemoteDownload;

@protocol SPDFMacRemoteDownloadDelegate <NSObject>
// New bytes arrived (at most every 80 ms, and at once after a quiet spell).
- (void)remoteDownloadDidProgress:(SPDFMacRemoteDownload*)download;
// Every byte is in (failure None) or the download stopped.
- (void)remoteDownloadDidFinish:(SPDFMacRemoteDownload*)download;
@end

@interface SPDFMacRemoteDownload : NSObject
- (instancetype)initWithURL:(NSURL*)url path:(NSString*)path NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSURL* url;
@property(nonatomic, readonly) NSString* path;
@property(nonatomic, weak, nullable) id<SPDFMacRemoteDownloadDelegate> delegate;

// Starts, carrying on from what a stopped download of the same address left in the file (its ranges sidecar).
- (void)start;
// Fetches small ranges at these offsets (a PDF's page objects) ahead of the fill, after anything a page waits on.
- (void)prefetchOffsets:(NSArray<NSNumber*>*)offsets;
// Stops, keeping what arrived for a later start.
- (void)cancel;
// Stops and lets go of the file at once (before another download of it starts, or when its tab closes): documents
// already open on it read what arrived and fail on the rest.
- (void)detach;

// Read on the main queue; updated just before each delegate call.
@property(nonatomic, readonly) int64_t length;   // -1 until known
@property(nonatomic, readonly) int64_t received;
@property(nonatomic, readonly) BOOL finished;
@property(nonatomic, readonly) SPDFMacRemoteDownloadFailure failure;
@property(nonatomic, readonly) NSInteger httpStatus;

// Whether a stopped download left this file part way (the reader then carries on with it rather than showing it).
+ (BOOL)fileIsPartial:(NSString*)path;
// The address a partial file was downloading from, or nil.
+ (nullable NSURL*)sourceURLOfPartialFile:(NSString*)path;
@end

NS_ASSUME_NONNULL_END
