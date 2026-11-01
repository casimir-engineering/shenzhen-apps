// Installing the szpdf link (SPDFMacCommandLineTool.h).
#import "SPDFMacCommandLineTool.h"

#include <sys/stat.h>
#include <unistd.h>

static NSString* const kNotOnPath = @"If Terminal can’t find szpdf, add ~/.local/bin to your PATH.";

NSString* SPDFMacCommandLineToolLinkPath(NSString* home) {
    return [home stringByAppendingPathComponent:@".local/bin/szpdf"];
}

static NSString* Target(NSString* appPath) {
    return [appPath stringByAppendingPathComponent:@"Contents/MacOS/szpdf"];
}

// The link's destination when `path` is a symbolic link, @"" when it is anything else, nil when nothing is there.
static NSString* LinkDestination(NSString* path) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return nil;
    if (!S_ISLNK(info.st_mode)) return @"";
    return [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:path error:nil] ?: @"";
}

NSString* SPDFMacCommandLineToolStatus(NSString* appPath, NSString* home) {
    NSString* destination = LinkDestination(SPDFMacCommandLineToolLinkPath(home));
    if ([destination isEqualToString:Target(appPath)])
        return [@"Installed in ~/.local/bin. " stringByAppendingString:kNotOnPath];
    if (destination.length) return @"~/.local/bin/szpdf is from another copy of ShenzhenPDF. Install to use this one.";
    return @"Lets scripts and agents open documents and read or answer comments from Terminal, with szpdf.";
}

NSString* SPDFMacInstallCommandLineTool(NSString* appPath, NSString* home, BOOL* installed) {
    if (installed) *installed = NO;
    NSString* link = SPDFMacCommandLineToolLinkPath(home);
    NSString* destination = LinkDestination(link);
    if (destination && !destination.length)
        return @"~/.local/bin/szpdf is a file ShenzhenPDF didn’t put there, so it was left alone.";
    NSError* error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:link.stringByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:&error])
        return [NSString stringWithFormat:@"Couldn’t create ~/.local/bin: %@", error.localizedDescription];
    if (destination) unlink(link.fileSystemRepresentation);
    if (symlink(Target(appPath).fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        return [NSString stringWithFormat:@"Couldn’t install szpdf in ~/.local/bin: %s", strerror(errno)];
    if (installed) *installed = YES;
    return [@"Installed in ~/.local/bin. " stringByAppendingString:kNotOnPath];
}
