#pragma once
#import <Foundation/Foundation.h>
#include <sys/types.h>

// Every reader window is its own process. When Finder (or Open Recent, or a link)
// asks one of them for a document another window already shows, the request is
// handed to that window instead of opening a second copy here.
FOUNDATION_EXPORT NSString* const SPDFMacShowDocumentNotification;
// The owning window's answer to a ShowDocument request. Without it in time, the
// asking window opens the document itself.
FOUNDATION_EXPORT NSString* const SPDFMacShowDocumentConfirmedNotification;

// The process of another window whose saved session lists `path`, or 0. Windows
// whose recorded process is this one or is no longer a running reader are skipped
// (a quit leaves its windows in the session for the next launch to restore). The
// most recently focused owner wins when several windows show the same document.
pid_t SPDFMacOtherWindowShowingPath(id session, NSString* path, pid_t selfPID, BOOL (^isRunningReader)(pid_t pid));

// The document a ShowDocument request asks this process to show, or nil when the
// request is for another process or is not a plain document path.
NSString* SPDFMacShowDocumentRequestPath(NSDictionary* userInfo, pid_t selfPID);

// The one-based page a ShowDocument request asks for, or nil for none or a malformed one.
NSNumber* SPDFMacShowDocumentRequestPage(NSDictionary* userInfo);

// The request a ShowDocument confirmation answers when it is addressed to `selfPID`, or nil.
NSString* SPDFMacShowDocumentConfirmedRequest(NSDictionary* userInfo, pid_t selfPID);
