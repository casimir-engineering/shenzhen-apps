// Documents a run may read (documents_dir and document_files, SPDFPythonSandboxDocumentPaths) and files it keeps in
// out/. The code reads a granted file and everything in a granted folder; a file beside a granted one, a link in a
// granted folder that leads out, a ".." out of it and any write there are refused by the sandbox itself. Included by
// SPDFPythonSandboxTests.m after SPDFPythonSandboxEscapeChecks.h.
#pragma once
#import "SPDFPythonSandboxEscapeChecks.h"

#include <sys/stat.h>

static NSString* DocumentsWrite(NSString* path, NSString* text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return path;
}

static void CheckDocumentPathRules(NSString* scratch) {
    NSString* prepared = [scratch stringByAppendingPathComponent:@"rules-prepared"];
    mkdir(prepared.fileSystemRepresentation, 0700);
    NSString* file = DocumentsWrite([scratch stringByAppendingPathComponent:@"rules/a.txt"], @"a");
    NSString* reason = nil;
    NSDictionary* paths = SPDFPythonSandboxDocumentPaths(prepared, @[ file ], &reason);
    CHECK([paths[@"document_literals"] isEqual:@[ file ]] && [paths[@"document_subpaths"] count] == 1,
          "a prepared folder and a file: the file by its exact path, the folder whole");
    CHECK(!SPDFPythonSandboxDocumentPaths(NSHomeDirectory(), @[], &reason) && reason.length,
          "the home folder is never a prepared folder");
    CHECK(!SPDFPythonSandboxDocumentPaths(prepared, @[ NSHomeDirectory() ], &reason) &&
          !SPDFPythonSandboxDocumentPaths(prepared, @[ @"/Users" ], &reason) &&
          !SPDFPythonSandboxDocumentPaths(prepared, @[ @"/" ], &reason),
          "a folder that holds the home folder is never readable");
    chmod(prepared.fileSystemRepresentation, 0755);
    CHECK(!SPDFPythonSandboxDocumentPaths(prepared, @[], &reason), "a prepared folder others can read is refused");
    chmod(prepared.fileSystemRepresentation, 0700);
    CHECK(!SPDFPythonSandboxDocumentPaths(prepared, @[ @"relative.txt" ], &reason) &&
          !SPDFPythonSandboxDocumentPaths(prepared, @[ [scratch stringByAppendingPathComponent:@"missing"] ], &reason),
          "relative or missing documents are refused");
    CHECK(!SPDFPythonSandboxValidInputName(@"documents") && !SPDFPythonSandboxValidInputName(@"out"),
          "inputs can't take the names of the run's own folders");
}

static void CheckDocuments(SandboxSuite* suite, NSString* scratch) {
    // The person's side: a file given alone with a sibling beside it, and a folder with a link leading out of it.
    NSString* given = DocumentsWrite([scratch stringByAppendingPathComponent:@"shared/given.txt"], @"given-file");
    DocumentsWrite([scratch stringByAppendingPathComponent:@"shared/sibling.txt"], @"sibling-secret");
    NSString* folder = [scratch stringByAppendingPathComponent:@"granted"];
    DocumentsWrite([folder stringByAppendingPathComponent:@"inner/data.txt"], @"inner-data");
    symlink(suite.secret.fileSystemRepresentation, [folder stringByAppendingPathComponent:@"escape"].fileSystemRepresentation);
    symlink([scratch stringByAppendingPathComponent:@"shared"].fileSystemRepresentation,
            [folder stringByAppendingPathComponent:@"shared-link"].fileSystemRepresentation);
    // The app's side: the private folder of links for this run.
    NSString* prepared = [scratch stringByAppendingPathComponent:@"prepared"];
    mkdir(prepared.fileSystemRepresentation, 0700);
    symlink(given.fileSystemRepresentation, [prepared stringByAppendingPathComponent:@"given.txt"].fileSystemRepresentation);
    symlink(folder.fileSystemRepresentation, [prepared stringByAppendingPathComponent:@"folder"].fileSystemRepresentation);
    DocumentsWrite([prepared stringByAppendingPathComponent:@"index.json"], @"{\"documents\": []}");
    NSString* code = [NSString stringWithFormat:
        @"import os\n"
         "def attempt(name, action):\n"
         "    try:\n"
         "        value = action()\n"
         "        print('READ', name, value)\n"
         "    except Exception as error:\n"
         "        print('REFUSED', name, type(error).__name__)\n"
         "attempt('given', lambda: open('documents/given.txt').read())\n"
         "attempt('index', lambda: len(open('documents/index.json').read()) > 0)\n"
         "attempt('inner', lambda: open('documents/folder/inner/data.txt').read())\n"
         "attempt('listing', lambda: sorted(os.listdir('documents/folder')))\n"
         "attempt('sibling', lambda: open('%@').read())\n"
         "attempt('dotdot', lambda: open('documents/folder/../shared/sibling.txt').read())\n"
         "attempt('escape-link', lambda: open('documents/folder/escape').read())\n"
         "attempt('folder-link', lambda: open('documents/folder/shared-link/sibling.txt').read())\n"
         "attempt('write-folder', lambda: open('documents/folder/new.txt', 'w').write('x'))\n"
         "attempt('write-prepared', lambda: open('documents/new.txt', 'w').write('x'))\n"
         "open('out/kept.csv', 'w').write('a,b\\n1,2\\n')\n",
        [scratch stringByAppendingPathComponent:@"shared/sibling.txt"]];
    NSDictionary* result = SuiteRun(suite, code, @{@"documents_dir" : prepared,
                                                   @"document_files" : @[ given, folder ]});
    NSString* out = result[@"stdout"] ?: @"";
    CHECK([out containsString:@"READ given given-file"] && [out containsString:@"READ index True"] &&
          [out containsString:@"READ inner inner-data"] && [out containsString:@"READ listing"],
          "the code reads a granted file, the run's index and everything in a granted folder");
    for (NSString* name in @[ @"sibling", @"dotdot", @"escape-link", @"folder-link", @"write-folder",
                              @"write-prepared" ])
        CHECK([out containsString:[NSString stringWithFormat:@"REFUSED %@ ", name]],
              [[NSString stringWithFormat:@"refused: %@ (%@)", name, out] UTF8String]);
    CHECK(![out containsString:@"sibling-secret"] && ![out containsString:suite.token],
          "nothing beside a granted file, and nothing a link leads to outside a granted folder");
    CHECK([[[NSString alloc] initWithData:SuiteFile(result, @"out/kept.csv") encoding:NSUTF8StringEncoding]
              isEqual:@"a,b\n1,2\n"],
          "a file the code keeps in out/ comes back as out/…");
    BOOL listed = NO;
    for (NSDictionary* file in result[@"files"]) listed |= [file[@"name"] hasPrefix:@"documents"];
    CHECK(!listed && ![NSFileManager.defaultManager fileExistsAtPath:[folder stringByAppendingPathComponent:@"new.txt"]],
          "the documents never come back as results, and nothing was written beside them");
    NSDictionary* refused = SuiteRun(suite, @"print('ran')\n", @{@"documents_dir" : prepared,
                                                                 @"document_files" : @[ NSHomeDirectory() ]});
    CHECK([refused[@"error"] isEqual:@"bad_request"] && ![refused[@"stdout"] length],
          "a request to read the home folder runs nothing");
}
