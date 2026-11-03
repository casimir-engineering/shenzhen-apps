#pragma once
// szpdf, the command-line tool for driving ShenzhenPDF from scripts and agents (portable/README.md § Command line).
// It is the app's own executable under another name: Contents/MacOS/szpdf is a link to ShenzhenPDF, and main()
// hands over here, before any AppKit start-up, when it was run by that name.
//
//   szpdf help [command]: every command, with its options, an example and its JSON fields (SPDFMacSzpdfHelp.mm).
//
// It talks to running readers over their private sockets (SPDFMacAgentChannel.h) and starts the app when none runs.
// Nothing it does brings ShenzhenPDF forward unless --front is given. Every command prints one JSON object with "ok"
// (comments without --json prints a readable list) and exits 0 on success, 1 when "ok" is false, 2 for a usage
// mistake. The commands that need no window (headings, find, check, features, export-pdf, page pictures) run in the
// tool's own process.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// YES when the process was started as "szpdf" (any directory, through any link).
BOOL SPDFMacIsSzpdfInvocation(const char* _Nullable argv0);
int SPDFMacRunSzpdf(int argc, const char* _Nonnull argv[_Nonnull]);

// The key of a usage mistake's NSError userInfo naming the command it was for ("comment add"), when known.
FOUNDATION_EXPORT NSString* const SPDFMacSzpdfUsageCommandKey;

// The command line, checked: {command, ...fields} with paths made absolute against `directory`, or nil and `error`
// (whose message is the usage line to print). Pure; tested in mac/tests/SPDFMacAgentChannelTests.mm.
NSDictionary* _Nullable SPDFMacSzpdfParseArguments(NSArray<NSString*>* arguments, NSString* directory,
                                                   NSError** error);
// The reader process an open goes to, from each process's `state` answer (keyed by pid): the one already showing
// `path`, else the one in front, else the oldest. 0 when there is none that is not quitting.
pid_t SPDFMacSzpdfChooseProcess(NSDictionary<NSNumber*, NSDictionary*>* states, NSString* path);

NS_ASSUME_NONNULL_END
