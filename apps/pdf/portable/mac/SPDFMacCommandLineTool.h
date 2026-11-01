#pragma once
// Settings > General > "Install Command-Line Tool": puts szpdf (SPDFMacSzpdf.h) on the person's command line without
// an administrator password, as a link in ~/.local/bin to Contents/MacOS/szpdf of this app. /usr/local/bin is not
// used: on Apple silicon Macs it belongs to root or does not exist, and writing there would need sudo.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// "<home>/.local/bin/szpdf".
FOUNDATION_EXPORT NSString* SPDFMacCommandLineToolLinkPath(NSString* home);
// Links <home>/.local/bin/szpdf to <app>/Contents/MacOS/szpdf, replacing an older link of the same name but never a
// file someone else put there. A sentence for the Settings row either way; `installed` says which.
FOUNDATION_EXPORT NSString* SPDFMacInstallCommandLineTool(NSString* appPath, NSString* home, BOOL* _Nullable installed);
// The Settings row's sentence for what is there now, without changing anything.
FOUNDATION_EXPORT NSString* SPDFMacCommandLineToolStatus(NSString* appPath, NSString* home);

NS_ASSUME_NONNULL_END
