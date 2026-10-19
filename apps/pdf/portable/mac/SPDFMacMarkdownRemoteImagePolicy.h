#pragma once
#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/xattr.h>

// Whether a Markdown document's remote images are withheld: shown as their alt text and never fetched.
//
// Fetching an https image tells its server when the document was opened and from which network address. That is
// the reader's ordinary behaviour for the person's own notes, but a document someone else sent can use it as a read
// receipt: a friend's notes.md with ![](https://tracker.example/p.gif?id=x) reports when and where it was opened.
// Shenzhen Friends never fetches link previews in messages (brief § Product contract), and a received document is
// held to the same rule. Withheld: any file carrying com.apple.quarantine (Friends sets it on everything it
// receives, from the first byte, and browsers, Mail and AirDrop set it on downloads), and anything inside Friends'
// received folder even if the attribute was removed.
//
// Header-only: the session's remote-image half is compiled into the Markdown suites with fixed source lists.

static inline NSString* SPDFMacMarkdownFriendsReceivedDirectory(void) {
    const char* override = getenv("SZFRIENDS_STATE_DIR");
    NSString* state = override && override[0]
        ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:override length:strlen(override)]
        : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Shenzhen Friends"];
    return [state stringByAppendingPathComponent:@"received"];
}

static inline NSString* SPDFMacMarkdownRealPath(NSString* path) {
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved)
        ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)] : nil;
}

static inline BOOL SPDFMacMarkdownRemoteImagesWithheld(NSURL* documentURL, NSString* receivedDirectory) {
    if (!documentURL.isFileURL) return NO;
    const char* path = documentURL.fileSystemRepresentation;
    if (getxattr(path, "com.apple.quarantine", NULL, 0, 0, 0) >= 0) return YES;
    // Compared after resolving both, so /var and /private/var, or a symlinked state directory, still match.
    NSString* document = SPDFMacMarkdownRealPath(documentURL.path);
    NSString* received = receivedDirectory.length ? SPDFMacMarkdownRealPath(receivedDirectory) : nil;
    return document && received && [document hasPrefix:[received stringByAppendingString:@"/"]];
}
