// szpdf's commands as data (SPDFMacSzpdfInternal.h): what each takes, its help, an example and the fields it answers.
// The argument parser (SPDFMacSzpdfArguments.mm), `szpdf help` and `szpdf schema` all read this one table.
#import "SPDFMacSzpdfInternal.h"

// Long texts are written as adjacent literals inside array literals on purpose.
#pragma clang diagnostic ignored "-Wobjc-string-concatenation"

// Fields every answer has.
static NSArray* CommonFields(void) {
    return @[
        @[ @"ok", @"true when the command did what it was asked; false with \"error\" otherwise" ],
        @[ @"error", @"only when ok is false: {\"code\": a stable code (szpdf help errors), \"message\": what went wrong}" ],
    ];
}

NSArray<NSDictionary*>* SPDFMacSzpdfCommandTable(void) {
    static NSArray* table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      table = @[
          @{@"name" : @"open", @"args" : @[ @"file" ],
            @"flags" : @[ @"--front", @"--background", @"--wait", @"--reload" ],
            @"valued" : @[ @"--page", @"--heading", @"--timeout" ],
            @"usage" : @"szpdf open <file> [--page N | --heading TEXT] [--front] [--wait] [--reload] [--timeout S]",
            @"summary" : @"Show a document in ShenzhenPDF, behind your other windows unless --front.",
            @"options" : @[
                @[ @"--page N", @"go to page N (from 1); implies --wait" ],
                @[ @"--heading TEXT", @"go to a heading: exact, then any case, then the start of a heading, then any part "
                                      @"of one; \"Parent › Heading\" names it by path; implies --wait" ],
                @[ @"--front", @"bring ShenzhenPDF and the window to the front (nothing else ever does)" ],
                @[ @"--background", @"the default: never take the focus" ],
                @[ @"--wait", @"answer once the layout is final and the first visible page is drawn" ],
                @[ @"--reload", @"read the file again first, as `szpdf reload` does" ],
                @[ @"--timeout S", @"seconds to wait for ShenzhenPDF to start and the document to load (default 30)" ],
            ],
            @"example" : @"szpdf open report.md --heading \"Power › Rails\" --wait",
            @"fields" : @[
                @[ @"opened", @"the document is in a window" ], @[ @"windowId", @"the window, for screenshot and close" ],
                @[ @"path", @"the document's real path" ], @[ @"page", @"page now shown, from 1" ],
                @[ @"pageCount", @"pages in the document (final once rendered is true)" ],
                @[ @"heading", @"the heading at the page shown" ], @[ @"headingPath", @"outermost first" ],
                @[ @"rendered", @"with --wait, --page, --heading or --reload: layout final and first visible page drawn" ],
                @[ @"reloaded", @"with --reload: the file was read again" ],
                @[ @"fileModified", @"the file's modification time (ISO 8601)" ],
                @[ @"front", @"ShenzhenPDF is the active app with this window key" ],
                @[ @"matches/closest", @"with a heading error: the headings it could mean" ],
            ]},
          @{@"name" : @"reload", @"args" : @[ @"file" ], @"valued" : @[ @"--timeout" ],
            @"usage" : @"szpdf reload <file> [--timeout S]",
            @"summary" : @"Read a document again after you rewrote it, re-render it, and say when it is done.",
            @"options" : @[ @[ @"--timeout S", @"seconds to wait for the new layout (default 30)" ] ],
            @"example" : @"szpdf reload report.md",
            @"fields" : @[
                @[ @"reloaded", @"the document was read again (it must be open: see szpdf open)" ],
                @[ @"fileModified", @"the modification time of the file now shown" ],
                @[ @"pageCount", @"pages after the reload" ], @[ @"rendered", @"layout final, first visible page drawn" ],
                @[ @"windowId", @"the window showing it" ], @[ @"page/heading/headingPath", @"where the reader is" ],
            ]},
          @{@"name" : @"close", @"args" : @[ @"file|windowId" ],
            @"usage" : @"szpdf close <file|windowId>",
            @"summary" : @"Close the tabs showing a document, or every tab of one window. Never asks, never comes forward.",
            @"options" : @[],
            @"example" : @"szpdf close report.md",
            @"fields" : @[ @[ @"closed", @"the paths whose tabs closed" ], @[ @"windowIds", @"the windows they were in" ] ]},
          @{@"name" : @"state", @"usage" : @"szpdf state",
            @"summary" : @"What ShenzhenPDF shows: processes, windows, and every open document.",
            @"options" : @[], @"example" : @"szpdf state",
            @"fields" : @[
                @[ @"running", @"ShenzhenPDF runs and answers" ], @[ @"processes", @"pid, active, quitting" ],
                @[ @"windows", @"windowId, title, visible, onScreen, minimized, key, frame [x,y,w,h], documents" ],
                @[ @"documents[]", @"path, windowId, selected, loaded, page, pageCount, heading, headingPath, "
                                   @"reloadedAt, loadedFileModified, fileModified, upToDate" ],
                @[ @"loaded", @"the tab's document has been read; when false, reloadedAt, loadedFileModified, "
                              @"upToDate, heading and headingPath are null" ],
                @[ @"upToDate", @"the file has not changed since it was read" ],
            ]},
          @{@"name" : @"headings", @"args" : @[ @"file" ],
            @"usage" : @"szpdf headings <file>",
            @"summary" : @"The heading tree with pages (and source lines for Markdown). Works without the app.",
            @"options" : @[], @"example" : @"szpdf headings report.md",
            @"fields" : @[
                @[ @"headings[]", @"level, title, path (outermost first), page (from 1), line (Markdown source line, or "
                                  @"null), duplicate (another heading has the same title)" ],
                @[ @"pageCount", @"pages, laid out at the document's own paper settings (default A4 portrait)" ],
            ]},
          @{@"name" : @"outline", @"args" : @[ @"file" ], @"alias" : @"headings",
            @"usage" : @"szpdf outline <file>", @"summary" : @"The same as szpdf headings.",
            @"options" : @[], @"example" : @"szpdf outline manual.pdf", @"fields" : @[]},
          @{@"name" : @"find", @"args" : @[ @"file", @"text" ], @"flags" : @[ @"--case" ], @"valued" : @[ @"--limit" ],
            @"usage" : @"szpdf find <file> TEXT [--case] [--limit N]",
            @"summary" : @"Where a text occurs: page, source line, heading and the words around it. Works without the app.",
            @"options" : @[ @[ @"--case", @"match case (default: ignore it)" ],
                            @[ @"--limit N", @"at most N matches (default 50)" ] ],
            @"example" : @"szpdf find report.md \"4.7 kΩ\"",
            @"fields" : @[
                @[ @"matches[]", @"page, line (Markdown source line; for a PDF the line on its page), headingPath, text "
                                 @"(the match), context (the line around it)" ],
                @[ @"count", @"matches found (before --limit)" ],
            ]},
          @{@"name" : @"screenshot", @"args" : @[ @"windowId|file", @"out.png" ],
            @"valued" : @[ @"--page", @"--region", @"--scale" ],
            @"usage" : @"szpdf screenshot <windowId|file> <out.png> [--page N] [--region x,y,w,h] [--scale S]",
            @"summary" : @"A picture of a window, or of one page drawn from the document, without moving anything.",
            @"options" : @[
                @[ @"--page N", @"draw page N of the window's document (or of <file>) instead of the window" ],
                @[ @"--region x,y,w,h", @"only that part of the page, in page points from its top left (72 per inch)" ],
                @[ @"--scale S", @"pixels per point for a page (default 2, at most 8)" ],
            ],
            @"example" : @"szpdf screenshot report.md page3.png --page 3 --scale 2",
            @"fields" : @[ @[ @"path", @"the picture written" ], @[ @"width/height", @"its size in pixels" ],
                           @[ @"page", @"with --page" ], @[ @"windowId", @"for a window" ] ]},
          @{@"name" : @"export-page", @"args" : @[ @"file", @"page", @"out.png" ],
            @"valued" : @[ @"--scale", @"--region" ],
            @"usage" : @"szpdf export-page <file> <N> <out.png> [--scale S] [--region x,y,w,h]",
            @"summary" : @"Page N of a document as a PNG (the same as screenshot <file> <out.png> --page N).",
            @"options" : @[ @[ @"--scale S", @"pixels per point (default 2)" ],
                            @[ @"--region x,y,w,h", @"part of the page, in points from its top left" ] ],
            @"example" : @"szpdf export-page report.md 1 cover.png", @"fields" : @[]},
          @{@"name" : @"export-pdf", @"args" : @[ @"file", @"out.pdf" ],
            @"usage" : @"szpdf export-pdf <file.md> <out.pdf>",
            @"summary" : @"A Markdown document as a PDF, laid out as ShenzhenPDF prints it. Works without the app.",
            @"options" : @[], @"example" : @"szpdf export-pdf report.md report.pdf",
            @"fields" : @[ @[ @"path", @"the PDF written" ], @[ @"pageCount", @"its pages" ] ]},
          @{@"name" : @"comments", @"args" : @[ @"file" ], @"flags" : @[ @"--wait-new" ],
            @"valued" : @[ @"--version", @"--since", @"--timeout" ],
            @"usage" : @"szpdf comments <file> [--version N] [--wait-new [--since ISO] [--timeout S]] [--json]",
            @"summary" : @"The comments on a document, or wait until someone adds, answers, edits or resolves one.",
            @"options" : @[
                @[ @"--version N", @"the comments of version N (szpdf version list)" ],
                @[ @"--wait-new", @"block until a comment or reply is added, edited, resolved or removed, then print "
                                  @"what changed" ],
                @[ @"--since ISO", @"with --wait-new: comments and replies dated after this count as new at once" ],
                @[ @"--timeout S", @"with --wait-new: give up after S seconds (default 600) with timedOut true, exit 0" ],
                @[ @"--json", @"JSON (the default for every command except this one, which prints a list without it)" ],
            ],
            @"example" : @"szpdf comments report.md --wait-new --timeout 1800",
            @"fields" : @[
                @[ @"comments[]", @"id, line (Markdown) or page (PDF), quote, headingPath, author, date, status "
                                  @"(open/resolved), text, replies [{author, date, text}]" ],
                @[ @"commentsFile", @"Markdown: the \"<name> - comments.md\" file beside the document" ],
                @[ @"changes[]", @"with --wait-new: kind (added, reply, edited, resolved, reopened, removed), id, "
                                 @"author, date, text, quote, and reply for kind reply" ],
                @[ @"timedOut", @"with --wait-new: nothing changed in time" ],
            ]},
          @{@"name" : @"comment add", @"args" : @[ @"file", @"text" ], @"valued" : @[ @"--line", @"--quote", @"--heading",
                                                                                     @"--page", @"--author" ],
            @"usage" : @"szpdf comment add <file> (--line N | --quote TEXT | --heading H | --page N) TEXT [--author NAME]",
            @"summary" : @"Add a comment on a line, a passage, a heading or (PDF) a page.",
            @"options" : @[
                @[ @"--line N", @"Markdown: on the block at source line N" ],
                @[ @"--quote TEXT", @"on these words; they must occur once (else the error lists where)" ],
                @[ @"--heading H", @"on a heading, matched as open --heading matches" ],
                @[ @"--page N", @"PDF: a note at the top of page N" ],
                @[ @"--author NAME", @"the name it is signed with (default: $SZPDF_AUTHOR, else the name ShenzhenPDF "
                                     @"signs your comments with, else the Mac's)" ],
            ],
            @"example" : @"szpdf comment add report.md --quote \"4.7 kΩ\" \"Datasheet says 2.2 kΩ at 1 MHz.\"",
            @"fields" : @[ @[ @"comment", @"the new comment, with its id (the id reply and resolve take)" ],
                           @[ @"readersRefreshed", @"windows that redrew it" ] ]},
          @{@"name" : @"comment reply", @"args" : @[ @"file", @"id", @"text" ], @"valued" : @[ @"--author" ],
            @"usage" : @"szpdf comment reply <file> <id> TEXT [--author NAME]",
            @"summary" : @"Answer a comment.",
            @"options" : @[ @[ @"--author NAME", @"the name it is signed with (default: $SZPDF_AUTHOR, else Agent)" ] ],
            @"example" : @"szpdf comment reply report.md m1a2b3c4d \"Fixed in v3.\"",
            @"fields" : @[ @[ @"comment", @"the comment with its replies" ],
                           @[ @"readersRefreshed", @"windows that redrew it" ] ]},
          @{@"name" : @"comment resolve", @"args" : @[ @"file", @"id" ], @"flags" : @[ @"--reopen" ],
            @"valued" : @[ @"--author" ],
            @"usage" : @"szpdf comment resolve <file> <id> [--reopen] [--author NAME]",
            @"summary" : @"Mark a comment resolved, or open again.",
            @"options" : @[ @[ @"--reopen", @"mark it open again" ],
                            @[ @"--author NAME", @"who resolved it (default: $SZPDF_AUTHOR, else Agent)" ] ],
            @"example" : @"szpdf comment resolve report.md m1a2b3c4d",
            @"fields" : @[ @[ @"comment", @"the comment, status resolved or open" ] ]},
          @{@"name" : @"version new", @"args" : @[ @"file" ], @"valued" : @[ @"--carry" ],
            @"usage" : @"szpdf version new <file> [--carry open|all|none]",
            @"summary" : @"Freeze the current text as <name> vN beside it before you rewrite the file.",
            @"options" : @[ @[ @"--carry open|all|none", @"which comments come along to the file you rewrite (default "
                                                         @"open: the unresolved ones); the frozen copy keeps all" ] ],
            @"example" : @"szpdf version new report.md   # then write the new text to report.md",
            @"fields" : @[ @[ @"version", @"number, name, path, commentsPath, date, current" ],
                           @[ @"via", @"app (a running ShenzhenPDF did it) or files" ] ]},
          @{@"name" : @"version list", @"args" : @[ @"file" ], @"usage" : @"szpdf version list <file>",
            @"summary" : @"The versions of a document, oldest first; the file itself is the last.",
            @"options" : @[], @"example" : @"szpdf version list report.md",
            @"fields" : @[ @[ @"versions[]", @"number, name, path, commentsPath, date, current" ] ]},
          @{@"name" : @"version compare", @"args" : @[ @"file", @"older", @"newer" ],
            @"flags" : @[ @"--background", @"--front", @"--wait" ],
            @"usage" : @"szpdf version compare <file> <older> <newer> [--front] [--wait]",
            @"summary" : @"What changed between two versions, and a comparison window behind your windows.",
            @"options" : @[ @[ @"--front", @"bring the comparison window to the front" ],
                            @[ @"--wait", @"answer once the window has compared them (\"changes\" is then its count)" ] ],
            @"example" : @"szpdf version compare report.md 1 2 --wait",
            @"fields" : @[
                @[ @"blocks[]", @"kind (added, removed, changed), old {from, to}, new {from, to} (lines, from 1; a PDF's "
                                @"also give pages), before, after (the text)" ],
                @[ @"changes", @"how many changed regions (the window's count with --wait, else the blocks)" ],
                @[ @"opened/windowId/loaded", @"the comparison window" ],
            ]},
          @{@"name" : @"check", @"args" : @[ @"file" ], @"usage" : @"szpdf check <file.md>",
            @"summary" : @"What the reader will do with a Markdown file: missing or oversized images, HTML it ignores, "
                         @"broken links, duplicate headings, comments that lost their place, wide tables.",
            @"options" : @[], @"example" : @"szpdf check report.md",
            @"fields" : @[ @[ @"issues[]", @"severity (error, warning, info), line, code, message" ],
                           @[ @"errors/warnings", @"counts" ], @[ @"pageCount", @"pages as laid out" ] ]},
          @{@"name" : @"features", @"valued" : @[ @"--format" ], @"usage" : @"szpdf features [--format md|pdf|all]",
            @"summary" : @"What the reader renders, as data: for writing a Markdown file that displays as you mean.",
            @"options" : @[ @[ @"--format md|pdf|all", @"which document kind (default all)" ] ],
            @"example" : @"szpdf features --format md",
            @"fields" : @[ @[ @"features[]", @"format, area, name, support (yes, partial, no), notes, example" ],
                           @[ @"limits", @"the numbers behind them (picture file bytes, diagram sizes, ...)" ] ]},
          @{@"name" : @"schema", @"args" : @[ @"command?" ], @"usage" : @"szpdf schema [command]",
            @"summary" : @"Every command's options and JSON fields, and the error codes, as JSON.",
            @"options" : @[], @"example" : @"szpdf schema open", @"fields" : @[]},
          @{@"name" : @"help", @"args" : @[ @"command?" ], @"usage" : @"szpdf help [command | errors]",
            @"summary" : @"This help; `szpdf help <command>` (or `szpdf <command> --help`) for one command.",
            @"options" : @[], @"example" : @"szpdf help comment add", @"fields" : @[]},
      ];
    });
    return table;
}

NSArray<NSArray<NSString*>*>* SPDFMacSzpdfErrorCodes(void) {
    return @[
        @[ @"usage", @"the command line is wrong (exit status 2); the usage is on standard error" ],
        @[ @"not-found", @"no document (or picture folder) at that path" ],
        @[ @"unsupported", @"the command does not apply to this kind of document" ],
        @[ @"not-running", @"ShenzhenPDF is not running and this command does not start it" ],
        @[ @"not-open", @"the document is not open in ShenzhenPDF" ],
        @[ @"not-responding", @"ShenzhenPDF runs but did not answer in time" ],
        @[ @"launch-failed", @"ShenzhenPDF could not be started" ],
        @[ @"quitting", @"ShenzhenPDF is quitting and did not finish in time" ],
        @[ @"no-window", @"no window has that id" ],
        @[ @"load-failed", @"the document could not be read or laid out" ],
        @[ @"timeout", @"the document did not finish loading in time" ],
        @[ @"page-out-of-range", @"the document has fewer pages" ],
        @[ @"line-out-of-range", @"the document has fewer lines, or nothing to comment on there" ],
        @[ @"heading-not-found", @"no heading matches; \"closest\" lists the five nearest" ],
        @[ @"heading-ambiguous", @"several headings match; \"matches\" lists them" ],
        @[ @"quote-not-found", @"those words are not in the document" ],
        @[ @"quote-ambiguous", @"those words occur more than once; \"matches\" lists where" ],
        @[ @"comment-not-found", @"no comment has that id" ],
        @[ @"version-not-found", @"no such version" ],
        @[ @"unsaved-changes", @"close refused: the tab holds something not saved" ],
        @[ @"write-failed", @"a file could not be written" ],
        @[ @"failed", @"anything else; the message says what" ],
    ];
}

NSDictionary* SPDFMacSzpdfCommandNamed(NSString* name) {
    for (NSDictionary* entry in SPDFMacSzpdfCommandTable())
        if ([entry[@"name"] isEqualToString:name]) return entry;
    return nil;
}

static NSString* Columns(NSArray<NSArray<NSString*>*>* rows, NSUInteger indent) {
    NSUInteger width = 0;
    for (NSArray* row in rows) width = MAX(width, [row[0] length]);
    NSMutableString* out = [NSMutableString string];
    NSString* pad = [@"" stringByPaddingToLength:indent withString:@" " startingAtIndex:0];
    for (NSArray* row in rows)
        [out appendFormat:@"%@%@  %@\n", pad, [row[0] stringByPaddingToLength:width withString:@" " startingAtIndex:0],
                          row[1]];
    return out;
}

NSString* SPDFMacSzpdfHelpText(NSString* name) {
    if ([name isEqualToString:@"errors"])
        return [NSString stringWithFormat:@"Error codes (\"error\": {\"code\", \"message\"}), stable across versions:\n\n%@",
                                          Columns(SPDFMacSzpdfErrorCodes(), 2)];
    NSDictionary* entry = name ? SPDFMacSzpdfCommandNamed(name) : nil;
    if (!entry) {
        NSMutableArray* rows = [NSMutableArray array];
        for (NSDictionary* command in SPDFMacSzpdfCommandTable()) [rows addObject:@[ command[@"name"], command[@"summary"] ]];
        return [NSString
            stringWithFormat:
                @"szpdf drives ShenzhenPDF from scripts and agents. Nothing it does brings ShenzhenPDF to the front "
                @"unless you pass --front.\n\nCommands:\n%@\n"
                @"Every command prints one JSON object with \"ok\" (comments prints a list unless --json); --json is "
                @"accepted everywhere. Exit status: 0 ok, 1 when \"ok\" is false, 2 for a usage mistake.\n"
                @"szpdf help <command> shows a command's options, an example and its fields; szpdf help errors the "
                @"error codes; szpdf schema all of it as JSON; szpdf --version the version.\n",
                Columns(rows, 2)];
    }
    NSMutableString* out = [NSMutableString stringWithFormat:@"szpdf %@: %@\n\nUsage: %@\n", entry[@"name"], entry[@"summary"], entry[@"usage"]];
    if ([entry[@"options"] count]) [out appendFormat:@"\nOptions:\n%@", Columns(entry[@"options"], 2)];
    [out appendFormat:@"\nExample:\n  %@\n", entry[@"example"]];
    NSArray* fields = [entry[@"fields"] count] ? [CommonFields() arrayByAddingObjectsFromArray:entry[@"fields"]] : nil;
    if (fields) [out appendFormat:@"\nJSON fields:\n%@", Columns(fields, 2)];
    if (entry[@"alias"]) [out appendFormat:@"\nSee szpdf help %@ for the fields.\n", entry[@"alias"]];
    return out;
}

NSString* SPDFMacSzpdfUsageText(NSString* name) {
    NSDictionary* entry = name ? SPDFMacSzpdfCommandNamed(name) : nil;
    if (!entry) return @"usage: szpdf <command> [arguments]\nRun \"szpdf help\" for the commands.";
    return [NSString stringWithFormat:@"usage: %@\nRun \"szpdf help %@\" for the options, an example and the fields.",
                                      entry[@"usage"], entry[@"name"]];
}

NSDictionary* SPDFMacSzpdfSchema(NSString* name) {
    NSMutableArray* commands = [NSMutableArray array];
    for (NSDictionary* entry in SPDFMacSzpdfCommandTable()) {
        if (name && ![entry[@"name"] isEqualToString:name]) continue;
        NSMutableDictionary* fields = [NSMutableDictionary dictionary];
        for (NSArray* field in [CommonFields() arrayByAddingObjectsFromArray:entry[@"fields"]]) fields[field[0]] = field[1];
        NSMutableDictionary* options = [NSMutableDictionary dictionary];
        for (NSArray* option in entry[@"options"]) options[option[0]] = option[1];
        [commands addObject:@{@"name" : entry[@"name"], @"usage" : entry[@"usage"], @"summary" : entry[@"summary"],
                              @"options" : options, @"fields" : fields, @"example" : entry[@"example"]}];
    }
    NSMutableDictionary* codes = [NSMutableDictionary dictionary];
    for (NSArray* code in SPDFMacSzpdfErrorCodes()) codes[code[0]] = code[1];
    return @{@"commands" : commands, @"errorCodes" : codes,
             @"exitStatus" : @{@"0" : @"ok is true", @"1" : @"ok is false", @"2" : @"usage mistake"}};
}

#pragma mark - Answers

NSDictionary* SPDFMacSzpdfFailure(NSString* code, NSString* message, NSDictionary* extra) {
    NSMutableDictionary* answer = [extra mutableCopy] ?: [NSMutableDictionary dictionary];
    answer[@"ok"] = @NO;
    answer[@"error"] = @{@"code" : code, @"message" : message ?: @"Failed."};
    return answer;
}

NSDictionary* SPDFMacSzpdfNormalized(NSDictionary* answer) {
    NSMutableDictionary* out = [answer mutableCopy];
    id error = out[@"error"];
    if ([error isKindOfClass:NSString.class]) {
        out[@"error"] = @{@"code" : out[@"errorCode"] ?: @"failed", @"message" : error};
    }
    [out removeObjectForKey:@"errorCode"];
    out[@"ok"] = @(out[@"error"] == nil);
    return out;
}

static NSISO8601DateFormatter* ISOFormatter(void) {
    static NSISO8601DateFormatter* formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      formatter = [NSISO8601DateFormatter new];
      formatter.timeZone = NSTimeZone.localTimeZone;
      formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return formatter;
}

NSString* SPDFMacSzpdfISODate(NSDate* date) { return date ? [ISOFormatter() stringFromDate:date] : nil; }

NSDate* SPDFMacSzpdfParseISODate(NSString* text) {
    NSDate* date = [ISOFormatter() dateFromString:text];
    if (date) return date;
    NSISO8601DateFormatter* fractional = [NSISO8601DateFormatter new];
    fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [fractional dateFromString:text];
}
