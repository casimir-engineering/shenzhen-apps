#pragma once
// Where a document the assistant makes is written: the person's Downloads folder, or a folder inside it, under a clear
// name. A name already taken gets " 2", " 3"… before its extension; nothing there is ever replaced, because every
// install is one exclusive rename of a finished file. Foundation only, so the job runner and its tests link it alone; keeping the
// file in Collection and showing it in the chat is SPDFMacAIOutputs.h.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The folder outputs go to: the test override when set, else "Downloads" inside SPDF_STATE_DIR when that is set (a
// private state for experiments and tests never reaches the real Downloads), else the person's Downloads folder.
// Computed when called, never at launch.
NSString* SPDFMacAIDownloadsDirectory(void);
// Tests only: nil restores the default.
void SPDFMacAISetDownloadsDirectoryForTesting(NSString* _Nullable directory);

// A folder inside Downloads named by `relative` ("Reports/October"), made when missing: each part a plain name (no
// "..", no leading dot, no separators or colons), at most 4 levels, and never a link, so it cannot lead out of
// Downloads. An empty `relative` is Downloads itself. nil with a problem written for the model.
NSString* _Nullable SPDFMacAIDownloadsSubfolder(NSString* _Nullable relative, NSString* _Nullable* _Nullable problem);
// `name` with " n" before its extension ("Report 2.pdf"): n 1 is `name` itself.
NSString* SPDFMacAIOutputNumberedName(NSString* name, NSUInteger n);
// A file name made from text a person or the model gave (a chart's caption): folder separators and colons become
// "-", control characters and leading dots go, at most 80 characters, and it ends in `extension`. Empty text gives
// `fallback`.extension.
NSString* SPDFMacAIOutputFileName(NSString* _Nullable text, NSString* fallback, NSString* extension);
// The name a document job's output gets when the request named none: "Report (OCR).pdf", "Report (French).pdf",
// "Notes.pdf" for a Markdown export, "Report (copy).pdf" for a PDF exported as a PDF.
NSString* SPDFMacAIJobOutputName(NSString* source, NSString* kind, NSString* _Nullable targetLanguage);

// Moves the finished file `staged` into `directory` as `name` or the first free numbered name, creating `directory`
// when missing. On another volume it is first copied beside its destination under a hidden name, so the visible
// name still appears only complete. Receipt: {path, identity} for SPDFMacAIOutputIsCurrent; nil leaves `staged`
// where it was.
NSDictionary* _Nullable SPDFMacAIOutputInstallFile(NSString* staged, NSString* directory, NSString* name,
                                                    NSError** error);
// The same for bytes: written to a private temporary file, then installed.
NSDictionary* _Nullable SPDFMacAIOutputWriteData(NSData* data, NSString* directory, NSString* name, NSError** error);

// A regular file's stat identity and SHA-256, or nil.
NSDictionary* _Nullable SPDFMacAIOutputIdentity(NSString* path);
// YES while the file at the receipt's path is still exactly the one installed.
BOOL SPDFMacAIOutputIsCurrent(NSDictionary* _Nullable receipt);
// Removes the receipt's file only while it is current; never anything else.
BOOL SPDFMacAIOutputRemove(NSDictionary* _Nullable receipt);

NS_ASSUME_NONNULL_END
