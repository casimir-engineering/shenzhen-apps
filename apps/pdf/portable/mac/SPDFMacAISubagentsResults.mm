#import "SPDFMacAISubagentsResults.h"
#import "SPDFMacAICitations.h"

const NSUInteger SPDFMacAISubagentTitleLimit = 80;
const NSUInteger SPDFMacAISubagentInstructionsLimit = 4000;
const NSUInteger SPDFMacAISubagentSummaryLimit = 2000;
const NSUInteger SPDFMacAISubagentSourceLimit = 8;

static NSString* Trimmed(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString* text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

NSArray<NSDictionary<NSString*, NSString*>*>* SPDFMacAISubagentTasks(id arguments, NSString** refusal) {
    NSString* problem = nil;
    NSMutableArray* tasks = [NSMutableArray array];
    id list = [arguments isKindOfClass:NSDictionary.class] ? arguments[@"tasks"] : nil;
    if (![list isKindOfClass:NSArray.class])
        problem = @"Pass tasks: an array of 1 to 4 objects, each with a title and instructions.";
    else if ([arguments count] != 1) problem = @"run_subagents takes only tasks.";
    else if ([list count] < 1 || [list count] > 4) problem = @"Run 1 to 4 tasks at a time.";
    for (id item in problem ? @[] : list) {
        NSString* title = [item isKindOfClass:NSDictionary.class] ? Trimmed(item[@"title"]) : nil;
        NSString* instructions = [item isKindOfClass:NSDictionary.class] ? Trimmed(item[@"instructions"]) : nil;
        if (!title || !instructions || [item count] != 2) {
            problem = @"Each task takes exactly a title and instructions, both non-empty text.";
        } else if (title.length > SPDFMacAISubagentTitleLimit) {
            problem = @"Keep each task's title under 80 characters: it is shown to the user while the task runs.";
        } else if (instructions.length > SPDFMacAISubagentInstructionsLimit) {
            problem = @"Keep each task's instructions under 4,000 characters.";
        } else if ([title containsString:@"\0"] || [instructions containsString:@"\0"]) {
            problem = @"Task text cannot contain NUL characters.";
        }
        if (problem) break;
        // A row title is one line; a newline from the model would only be cut off there.
        NSArray* words = [title componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        title = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
            componentsJoinedByString:@" "];
        [tasks addObject:@{@"title" : title, @"instructions" : instructions}];
    }
    if (problem) {
        if (refusal) *refusal = problem;
        return nil;
    }
    return tasks;
}

NSString* SPDFMacAISubagentClipped(NSString* text, NSUInteger limit) {
    if (text.length <= limit || !limit) return text;
    NSUInteger end = [text rangeOfComposedCharacterSequenceAtIndex:limit - 1].location;
    return [[text substringToIndex:end] stringByAppendingString:@"…"];
}

// Every string in the task's tool results: where a web address must appear for it to count as returned by a tool.
// Parsed rather than searched as text, because the session writes results with escaped slashes ("https:\/\/").
static void CollectStrings(id value, NSMutableArray* strings, NSUInteger depth) {
    if (depth > 20 || strings.count > 50000) return;
    if ([value isKindOfClass:NSString.class]) [strings addObject:value];
    else if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value) CollectStrings(value[key], strings, depth + 1);
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) CollectStrings(item, strings, depth + 1);
    }
}

static NSArray<NSString*>* ToolStrings(NSDictionary* chat) {
    NSMutableArray* strings = [NSMutableArray array];
    id messages = [chat isKindOfClass:NSDictionary.class] ? chat[@"messages"] : nil;
    for (NSDictionary* message in [messages isKindOfClass:NSArray.class] ? messages : @[]) {
        if (![message isKindOfClass:NSDictionary.class] || ![message[@"role"] isEqual:@"tool"] ||
            ![message[@"content"] isKindOfClass:NSString.class]) continue;
        NSData* data = [message[@"content"] dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length > 100000) continue; // the session never stores a larger result
        CollectStrings([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], strings, 0);
    }
    return strings;
}

static NSRegularExpression* LinkPattern(void) {
    static NSRegularExpression* pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // [words](address): words on one line, an address without spaces or parentheses.
        pattern = [NSRegularExpression
            regularExpressionWithPattern:@"\\[([^\\[\\]\\n]{0,300})\\]\\(([^()\\s]{1,2048})\\)" options:0 error:nil];
    });
    return pattern;
}

static NSRegularExpression* AddressPattern(void) {
    static NSRegularExpression* pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:
            @"spdf-ai://document\\?[^\\s<>()\\[\\]]+|https://[^\\s<>()\\[\\]\"'`]+" options:0 error:nil];
    });
    return pattern;
}

static BOOL Returned(NSString* address, NSDictionary* chat, NSArray<NSString*>* toolStrings) {
    if ([address hasPrefix:@"spdf-ai:"])
        return SPDFMacAIChatContainsCitation(chat, SPDFMacAICitationArguments([NSURL URLWithString:address]));
    if (![address hasPrefix:@"https://"]) return NO;
    for (NSString* string in toolStrings) if ([string containsString:address]) return YES;
    return NO;
}

NSDictionary<NSString*, id>* SPDFMacAISubagentFindings(NSString* answer, NSDictionary* chat) {
    NSDictionary* safeChat = [chat isKindOfClass:NSDictionary.class] ? chat : @{};
    // A genuine page link with an invented highlight keeps its page, as in the main chat.
    NSString* text = SPDFMacAIRepairCitationLinks([answer isKindOfClass:NSString.class] ? answer : @"", safeChat);
    NSArray<NSString*>* toolStrings = ToolStrings(safeChat);
    NSMutableArray* sources = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    NSMutableArray<NSTextCheckingResult*>* unlink = [NSMutableArray array];
    NSArray<NSTextCheckingResult*>* links = [LinkPattern() matchesInString:text options:0
                                                                     range:NSMakeRange(0, text.length)];
    NSMutableArray* candidates = [links mutableCopy];
    for (NSTextCheckingResult* bare in [AddressPattern() matchesInString:text options:0
                                                                   range:NSMakeRange(0, text.length)]) {
        BOOL insideLink = NO;
        for (NSTextCheckingResult* link in links) insideLink = insideLink || NSIntersectionRange(link.range,
                                                                                                bare.range).length;
        if (!insideLink) [candidates addObject:bare];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSTextCheckingResult* a, NSTextCheckingResult* b) {
        return a.range.location < b.range.location ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (NSTextCheckingResult* candidate in candidates) {
        BOOL link = candidate.numberOfRanges == 3;
        NSString* label = link ? [text substringWithRange:[candidate rangeAtIndex:1]] : nil;
        NSString* address = [text substringWithRange:link ? [candidate rangeAtIndex:2] : candidate.range];
        // Sentence punctuation after a bare address is not part of it.
        if (!link) address = [address stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@".,;:!?*_"]];
        BOOL returned = Returned(address, safeChat, toolStrings);
        if (link && !returned) [unlink addObject:candidate];
        if (!returned || [seen containsObject:address] || sources.count >= SPDFMacAISubagentSourceLimit) continue;
        [seen addObject:address];
        NSMutableDictionary* source = [NSMutableDictionary dictionary];
        NSString* title = Trimmed(label);
        if (title) source[@"title"] = SPDFMacAISubagentClipped(title, 200);
        source[[address hasPrefix:@"spdf-ai:"] ? @"citation" : @"url"] = address;
        [sources addObject:source];
    }
    NSMutableString* summary = [text mutableCopy];
    for (NSTextCheckingResult* link in unlink.reverseObjectEnumerator)
        [summary replaceCharactersInRange:link.range withString:[text substringWithRange:[link rangeAtIndex:1]]];
    NSString* trimmed = Trimmed(summary) ?: @"";
    return @{@"summary" : SPDFMacAISubagentClipped(trimmed, SPDFMacAISubagentSummaryLimit), @"sources" : sources};
}

static NSString* Replaced(NSString* text, NSString* pattern, NSString* with) {
    NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionAnchorsMatchLines error:nil];
    return [expression stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                                           withTemplate:with];
}

// **strong**, __strong__, *emphasis* and _emphasis_ reduced to their words. An asterisk between spaces ("2 * 3") and
// underscores inside a word (file_name) are not emphasis, as in the chat's Markdown.
static NSString* Unemphasized(NSString* text) {
    text = Replaced(text, @"\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", @"$1");
    text = Replaced(text, @"(?<!\\w)__(?=\\S)(.+?)(?<=\\S)__(?!\\w)", @"$1");
    text = Replaced(text, @"(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])", @"$1");
    return Replaced(text, @"(?<![_\\w])_(?=[^\\s_])(.+?)(?<=[^\\s_])_(?![_\\w])", @"$1");
}

// A finished helper's findings are Markdown, shown in a row's plain text: the marks would show as asterisks, hashes and
// backticks. Inside a code span the characters are the code's own, so only its backticks go.
NSString* SPDFMacAISubagentPlainText(NSString* markdown) {
    if (![markdown isKindOfClass:NSString.class]) return @"";
    NSString* text = [LinkPattern() stringByReplacingMatchesInString:markdown options:0
                                                               range:NSMakeRange(0, markdown.length)
                                                        withTemplate:@"$1"];
    // A heading's words, without the hashes before them or the closing ones after.
    text = Replaced(text, @"^[ \\t]{0,3}#{1,6}[ \\t]+(.*?)(?:[ \\t]+#+)?[ \\t]*$", @"$1");
    NSRegularExpression* code = [NSRegularExpression regularExpressionWithPattern:@"(`+)(.+?)\\1(?!`)" options:0
                                                                            error:nil];
    NSMutableString* plain = [NSMutableString string];
    __block NSUInteger from = 0;
    [code enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                        usingBlock:^(NSTextCheckingResult* match, NSMatchingFlags flags, BOOL* stop) {
        (void)flags; (void)stop;
        [plain appendString:Unemphasized([text substringWithRange:NSMakeRange(from, match.range.location - from)])];
        [plain appendString:[text substringWithRange:[match rangeAtIndex:2]]];
        from = NSMaxRange(match.range);
    }];
    [plain appendString:Unemphasized([text substringFromIndex:from])];
    return plain;
}

NSString* SPDFMacAISubagentCurrentTool(NSArray* messages) {
    if (![messages isKindOfClass:NSArray.class]) return nil;
    NSUInteger answered = 0;
    for (NSDictionary* message in messages.reverseObjectEnumerator) {
        if (![message isKindOfClass:NSDictionary.class]) return nil;
        if ([message[@"role"] isEqual:@"tool"] || [message[@"role"] isEqual:@"preview"]) {
            answered += [message[@"role"] isEqual:@"tool"];
            continue;
        }
        if (![message[@"role"] isEqual:@"assistant"]) return nil;
        NSArray* calls = message[@"tool_calls"];
        if (![calls isKindOfClass:NSArray.class] || answered >= calls.count) return nil;
        NSDictionary* call = calls[answered];
        id function = [call isKindOfClass:NSDictionary.class] ? call[@"function"] : nil;
        id name = [function isKindOfClass:NSDictionary.class] ? function[@"name"] : nil;
        return [name isKindOfClass:NSString.class] ? name : nil;
    }
    return nil;
}

NSString* SPDFMacAISubagentStepText(NSString* tool) {
    static NSDictionary* steps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // In progress, so each ends in an ellipsis, as "Thinking…" does.
        steps = @{@"search_documents" : @"Searching documents…", @"read_pages" : @"Reading pages…",
                  @"render_page" : @"Looking at a page…", @"list_workspace" : @"Checking open documents…",
                  @"document_metadata" : @"Checking a document…", @"list_collection" : @"Searching the Collection…",
                  @"current_view" : @"Checking what’s on screen…", @"reader_state" : @"Checking what’s on screen…",
                  @"list_chats" : @"Looking through chats…", @"web_search" : @"Searching the web…",
                  @"open_page" : @"Reading a web page…", @"run_python" : @"Running Python…"};
    });
    return [tool isKindOfClass:NSString.class] && steps[tool] ? steps[tool] : @"Working…";
}

NSString* SPDFMacAISubagentProblemLine(NSString* problem) {
    NSString* text = Trimmed(problem);
    if (!text) return nil;
    NSArray* lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    text = Trimmed(lines.firstObject) ?: text;
    NSRange stop = [text rangeOfString:@". "];
    if (stop.location != NSNotFound) text = [text substringToIndex:stop.location + 1];
    return SPDFMacAISubagentClipped(text, 160);
}
