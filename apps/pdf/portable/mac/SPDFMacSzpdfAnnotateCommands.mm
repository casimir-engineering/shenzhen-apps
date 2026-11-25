// `szpdf annotate` and `szpdf canvas new` as data (SPDFMacSzpdfInternal.h): their rows in the
// command table, their command lines read into operations, and the operation schema (spdf_paint_schema()) seen from
// Foundation, for help, the assistant's tool descriptions and flag types. Foundation and the paint core only: the
// headless szpdf suites link this file without the app.
#import "SPDFMacSzpdfInternal.h"

#include "spdf_paint.h"

#include <stdio.h>
#include <stdlib.h>

#pragma clang diagnostic ignored "-Wobjc-string-concatenation"

#pragma mark - The schema, as Foundation objects

NSDictionary* SPDFAnnotateSchemaObject(void) {
    static NSDictionary* schema;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      const char* text = spdf_paint_schema();
      NSData* data = text ? [NSData dataWithBytes:text length:strlen(text)] : nil;
      id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      schema = [object isKindOfClass:NSDictionary.class] ? object : @{};
    });
    return schema;
}

NSArray<NSString*>* SPDFAnnotateOperationNames(void) {
    NSMutableArray* names = [NSMutableArray array];
    for (int i = 0; i < spdf_paint_op_count(); i++) [names addObject:@(spdf_paint_op_at(i)->name)];
    return names;
}

NSDictionary* SPDFAnnotateOperationSchema(NSString* name) {
    id entry = SPDFAnnotateSchemaObject()[@"operations"][name ?: @""];
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}

// A property with its "$ref" replaced by the definition it names (the property's own keys win).
NSDictionary* SPDFAnnotateResolvedProperty(NSDictionary* property) {
    NSString* reference = [property[@"$ref"] isKindOfClass:NSString.class] ? property[@"$ref"] : nil;
    if (![reference hasPrefix:@"#/$defs/"]) return property;
    NSDictionary* definition = SPDFAnnotateSchemaObject()[@"$defs"][[reference substringFromIndex:8]];
    if (![definition isKindOfClass:NSDictionary.class]) return property;
    NSMutableDictionary* merged = [SPDFAnnotateResolvedProperty(definition) mutableCopy];
    for (NSString* key in property)
        if (![key isEqual:@"$ref"]) merged[key] = property[key];
    return merged;
}

static NSString* DefinitionName(NSDictionary* property) {
    NSString* reference = [property[@"$ref"] isKindOfClass:NSString.class] ? property[@"$ref"] : nil;
    return [reference hasPrefix:@"#/$defs/"] ? [reference substringFromIndex:8] : nil;
}

#pragma mark - A compact reference, for the assistant's tool description

static NSString* Hint(NSDictionary* property) {
    NSString* name = DefinitionName(property);
    if (name && ![@[ @"align", @"opacity", @"page" ] containsObject:name]) return name;
    NSDictionary* resolved = SPDFAnnotateResolvedProperty(property);
    if ([resolved[@"enum"] isKindOfClass:NSArray.class])
        return [[resolved[@"enum"] valueForKey:@"description"] componentsJoinedByString:@"|"];
    if (resolved[@"const"]) return [NSString stringWithFormat:@"%@", [resolved[@"const"] isEqual:@YES] ? @"true" : resolved[@"const"]];
    if ([resolved[@"anyOf"] isKindOfClass:NSArray.class]) {
        NSMutableArray* parts = [NSMutableArray array];
        for (NSDictionary* alternative in resolved[@"anyOf"]) [parts addObject:Hint(alternative)];
        return [parts componentsJoinedByString:@"|"];
    }
    id type = resolved[@"type"];
    if ([type isKindOfClass:NSArray.class]) return [type componentsJoinedByString:@"|"];
    if ([name isEqual:@"opacity"]) return @"percent";
    return [type isKindOfClass:NSString.class] ? type : @"value";
}

NSString* SPDFAnnotateOperationReference(void) {
    static NSString* reference;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSMutableString* text = [NSMutableString stringWithString:
          @"Operations, each {\"op\": name, ...arguments} (* = required). Pictures and canvases are measured in "
          @"pixels, PDF pages in points from the page's top-left corner, y down; on a PDF, page is the page from 1.\n"];
      for (NSString* name in SPDFAnnotateOperationNames()) {
          NSDictionary* schema = SPDFAnnotateOperationSchema(name);
          NSSet* required = [NSSet setWithArray:schema[@"required"] ?: @[]];
          NSMutableArray* arguments = [NSMutableArray array];
          NSDictionary* properties = schema[@"properties"];
          for (NSString* key in [properties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
              if ([key isEqual:@"op"]) continue;
              [arguments addObject:[NSString stringWithFormat:@"%@%@: %@", key, [required containsObject:key] ? @"*" : @"",
                                                              Hint(properties[key])]];
          }
          [text appendFormat:@"%@ {%@} %@\n", name, [arguments componentsJoinedByString:@", "],
                             schema[@"description"] ?: @""];
      }
      [text appendString:@"Types: color \"#RRGGBB\" or \"#RRGGBBAA\"; point [x, y] or [x, y, pressure 0-1]; points "
                         @"[point, ...]; rect {x, y, w, h}; id and ids: layer and object ids from annotate_state; "
                         @"percent 0-100"];
      NSDictionary* definitions = SPDFAnnotateSchemaObject()[@"$defs"];
      for (NSString* key in [definitions.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
          NSDictionary* definition = SPDFAnnotateResolvedProperty(definitions[key]);
          if ([definition[@"enum"] isKindOfClass:NSArray.class] || [definition[@"anyOf"] isKindOfClass:NSArray.class])
              [text appendFormat:@"; %@: %@", key, Hint(definition)];
          else if ([definition[@"properties"] isKindOfClass:NSDictionary.class] && ![key isEqual:@"rect"]) {
              NSMutableArray* fields = [NSMutableArray array];
              NSDictionary* properties = definition[@"properties"];
              for (NSString* field in [properties.allKeys sortedArrayUsingSelector:@selector(compare:)])
                  [fields addObject:[NSString stringWithFormat:@"%@: %@", field, Hint(properties[field])]];
              [text appendFormat:@"; %@: {%@}", key, [fields componentsJoinedByString:@", "]];
          }
      }
      [text appendString:@".\n"];
      reference = text;
    });
    return reference;
}

#pragma mark - Command table rows

static NSString* OperationList(void) {
    NSMutableArray* rows = [NSMutableArray array];
    NSUInteger width = 0;
    for (NSString* name in SPDFAnnotateOperationNames()) width = MAX(width, name.length);
    for (NSString* name in SPDFAnnotateOperationNames())
        [rows addObject:[NSString stringWithFormat:@"  %@  %@", [name stringByPaddingToLength:width withString:@" " startingAtIndex:0],
                                                   @(spdf_paint_op_find(name.UTF8String)->summary)]];
    return [NSString stringWithFormat:@"\nOperations (szpdf annotate schema <op> gives one's arguments):\n%@\n",
                                      [rows componentsJoinedByString:@"\n"]];
}

NSArray<NSDictionary*>* SPDFMacSzpdfAnnotateCommandRows(void) {
    return @[
        @{@"name" : @"annotate", @"args" : @[ @"file|tab", @"op" ],
          @"usage" : @"szpdf annotate <file|tab> <op> [--name value ...] [--json '{...}'] | <file|tab> --script "
                     @"ops.json | <file|tab> state [--page N] | schema [op]",
          @"summary" : @"Draw, paint, fill in and change pictures, canvases and PDF pages, one operation at a time "
                       @"or a script of them, exactly as Annotate's tools do.",
          @"options" : @[
              @[ @"<file|tab>", @"a document's path (opened behind your windows if it is not open) or a tab id from "
                                @"szpdf canvas new" ],
              @[ @"--NAME VALUE", @"an argument of the operation (--keep-ratio or --keepRatio give keepRatio; points "
                                  @"as \"x,y x,y\", a rect as \"x,y,w,h\"; --bold alone is true, --no-bold false)" ],
              @[ @"--json '{...}'", @"the operation's arguments whole (with \"op\" in it, the op word may be left out)" ],
              @[ @"--script FILE", @"a JSON array of operations applied in order, stopping at the first error "
                                   @"(- reads standard input)" ],
              @[ @"--page N", @"on a PDF, the page the operation acts on, from 1" ],
              @[ @"--timeout S", @"seconds to wait for ShenzhenPDF (default 60)" ],
          ],
          @"more" : OperationList(),
          @"example" : @"szpdf annotate photo.png shape.add --shape rectangle --rect 40,40,200,120 --outline "
                       @"'{\"color\":\"#E02020\",\"width\":4}'",
          @"fields" : @[
              @[ @"(operation's own)", @"what the operation answers, such as id for a new object (szpdf annotate schema)" ],
              @[ @"results[]", @"--script: each operation's answer, up to the first error" ],
              @[ @"tab", @"the tab's id, for later commands" ], @[ @"windowId", @"the window showing it" ],
              @[ @"form", @"state on a PDF: its form fields and what was placed (form.state)" ],
          ]},
        @{@"name" : @"canvas new", @"flags" : @[ @"--front" ], @"valued" : @[ @"--width", @"--height", @"--background", @"--timeout" ],
          @"usage" : @"szpdf canvas new [--width W] [--height H] [--background C] [--front]",
          @"summary" : @"Open a new blank canvas in a tab with Annotate on, behind your windows unless --front.",
          @"options" : @[
              @[ @"--width W, --height H", @"pixels, 1 to 16384 (default 1000 x 1000)" ],
              @[ @"--background C", @"transparent (the default) or #RRGGBB" ],
              @[ @"--front", @"bring the window to the front" ],
          ],
          @"example" : @"szpdf canvas new --width 1200 --height 800 --background '#FFFFFF'",
          @"fields" : @[ @[ @"tab", @"the new tab's id, for szpdf annotate" ], @[ @"windowId", @"the window showing it" ] ]},
    ];
}

#pragma mark - Reading the command line

static NSError* Usage(NSString* problem, NSString* command) {
    return [NSError errorWithDomain:@"ShenzhenPDF.szpdf" code:2
                           userInfo:@{NSLocalizedDescriptionKey : problem, @"command" : command}];
}

static NSString* Absolute(NSString* path, NSString* directory) {
    NSString* absolute = path.isAbsolutePath ? path : [directory stringByAppendingPathComponent:path];
    char resolved[PATH_MAX];
    if (realpath(absolute.fileSystemRepresentation, resolved)) return @(resolved);
    NSString* folder = absolute.stringByDeletingLastPathComponent;
    if (realpath(folder.fileSystemRepresentation, resolved))
        return [@(resolved) stringByAppendingPathComponent:absolute.lastPathComponent];
    return absolute.stringByStandardizingPath;
}

BOOL SPDFMacSzpdfIsAnnotateCommand(NSArray<NSString*>* arguments) {
    return [@[ @"annotate", @"canvas" ] containsObject:arguments.firstObject ?: @""];
}

BOOL SPDFAnnotateIsTabIdentifier(NSString* text) {
    return [text isKindOfClass:NSString.class] && [text hasPrefix:@"tab-"] && text.length < 40;
}

// Paths in an operation's arguments are the caller's (relative to its folder); the app needs them whole.
NSDictionary* SPDFAnnotateAbsoluteArguments(NSDictionary* op, NSString* directory) {
    NSMutableDictionary* out = [op mutableCopy];
    for (NSString* key in @[ @"path", @"out" ])
        if ([out[key] isKindOfClass:NSString.class] && [out[key] length] && ![out[key] isAbsolutePath])
            out[key] = Absolute(out[key], directory);
    return out;
}

static NSNumber* Number(NSString* text, BOOL whole) {
    NSScanner* scanner = [NSScanner scannerWithString:text];
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.atEnd || !isfinite(value)) return nil;
    if (whole && value != floor(value)) return nil;
    return whole ? @((long long)value) : @(value);
}

static id JSONValue(NSString* text) {
    NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
}

static id TruthValue(NSString* text) {
    NSString* lower = text.lowercaseString;
    if ([@[ @"true", @"yes", @"on", @"1" ] containsObject:lower]) return @YES;
    if ([@[ @"false", @"no", @"off", @"0" ] containsObject:lower]) return @NO;
    return nil;
}

// "x,y" -> [x, y]; "x,y x,y" or "x,y;x,y" -> [[x, y], [x, y]]; "1,2,3" -> [1, 2, 3].
static NSArray* NumberList(NSString* text) {
    NSMutableArray* numbers = [NSMutableArray array];
    for (NSString* part in [text componentsSeparatedByString:@","]) {
        NSNumber* number = Number([part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet], NO);
        if (!number) return nil;
        [numbers addObject:number];
    }
    return numbers;
}

static id ArrayValue(NSString* text, NSDictionary* schema) {
    if ([text hasPrefix:@"["]) return JSONValue(text);
    NSDictionary* items = [schema[@"items"] isKindOfClass:NSDictionary.class] ? SPDFAnnotateResolvedProperty(schema[@"items"]) : nil;
    if ([items[@"type"] isEqual:@"array"]) {
        NSMutableArray* points = [NSMutableArray array];
        NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@" ;"];
        for (NSString* part in [text componentsSeparatedByCharactersInSet:separators]) {
            if (!part.length) continue;
            NSArray* point = NumberList(part);
            if (point.count < 2 || point.count > 3) return nil;
            [points addObject:point];
        }
        return points.count ? points : nil;
    }
    return NumberList(text);
}

// The flag's text as the type the operation's schema gives that argument.
static id Convert(NSString* text, NSDictionary* property) {
    NSDictionary* schema = SPDFAnnotateResolvedProperty(property);
    if ([schema[@"anyOf"] isKindOfClass:NSArray.class]) {
        for (NSDictionary* alternative in schema[@"anyOf"]) {
            NSDictionary* resolved = SPDFAnnotateResolvedProperty(alternative);
            if ([resolved[@"enum"] containsObject:text] || [resolved[@"const"] isEqual:text]) return text;
        }
        for (NSDictionary* alternative in schema[@"anyOf"]) {
            id value = Convert(text, alternative);
            if (value) return value;
        }
        return nil;
    }
    if (schema[@"const"]) return TruthValue(text) ? (TruthValue(text) == schema[@"const"] ? schema[@"const"] : nil) : nil;
    if ([schema[@"enum"] isKindOfClass:NSArray.class]) return [schema[@"enum"] containsObject:text] ? text : nil;
    id type = schema[@"type"];
    if ([type isKindOfClass:NSArray.class]) {
        if ([type containsObject:@"boolean"] && TruthValue(text)) return TruthValue(text);
        return [type containsObject:@"string"] ? text : JSONValue(text);
    }
    if ([type isEqual:@"string"]) {
        NSString* pattern = [schema[@"pattern"] isKindOfClass:NSString.class] ? schema[@"pattern"] : nil;
        return !pattern || [text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound ? text : nil;
    }
    if ([type isEqual:@"integer"] || [type isEqual:@"number"]) return Number(text, [type isEqual:@"integer"]);
    if ([type isEqual:@"boolean"]) return TruthValue(text);
    if ([type isEqual:@"array"]) return ArrayValue(text, schema);
    if ([type isEqual:@"object"]) {
        if (![text hasPrefix:@"{"] && [schema[@"required"] isEqual:(@[ @"x", @"y", @"w", @"h" ])]) {
            NSArray* numbers = NumberList(text);
            return numbers.count == 4 ? @{@"x" : numbers[0], @"y" : numbers[1], @"w" : numbers[2], @"h" : numbers[3]} : nil;
        }
        return JSONValue(text);
    }
    return JSONValue(text) ?: text;
}

// --keep-ratio, --keepRatio and --keep_ratio all name keepRatio; --png-base64 names png_base64.
static NSString* PropertyName(NSString* flag, NSDictionary* properties) {
    NSMutableString* camel = [NSMutableString string];
    BOOL upper = NO;
    for (NSUInteger i = 0; i < flag.length; i++) {
        unichar c = [flag characterAtIndex:i];
        if (c == '-') { upper = YES; continue; }
        [camel appendString:upper ? [[NSString stringWithCharacters:&c length:1] uppercaseString] : [NSString stringWithCharacters:&c length:1]];
        upper = NO;
    }
    for (NSString* candidate in @[ flag, [flag stringByReplacingOccurrencesOfString:@"-" withString:@"_"], camel ])
        if (properties[candidate] && ![candidate isEqual:@"op"]) return candidate;
    return nil;
}

// The operation's arguments from --name value pairs. nil and *problem when one does not fit.
static NSMutableDictionary* OperationFromFlags(NSString* name, NSArray<NSString*>* flags, NSString** problem) {
    NSDictionary* properties = SPDFAnnotateOperationSchema(name)[@"properties"] ?: @{};
    NSMutableDictionary* op = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < flags.count; i++) {
        NSString* flag = flags[i];
        if (![flag hasPrefix:@"--"] || flag.length < 3) {
            *problem = [NSString stringWithFormat:@"Unexpected %@: give arguments as --name value.", flag];
            return nil;
        }
        NSString* key = [flag substringFromIndex:2], *value = nil;
        NSRange equals = [key rangeOfString:@"="];
        if (equals.location != NSNotFound) {
            value = [key substringFromIndex:equals.location + 1];
            key = [key substringToIndex:equals.location];
        }
        NSString* property = PropertyName(key, properties);
        BOOL negated = NO;
        if (!property && [key hasPrefix:@"no-"]) {
            property = PropertyName([key substringFromIndex:3], properties);
            negated = property && [SPDFAnnotateResolvedProperty(properties[property])[@"type"] isEqual:@"boolean"];
            if (!negated) property = nil;
        }
        if (!property) {
            *problem = [NSString stringWithFormat:@"%@ is not an argument of %@; szpdf annotate schema %@ lists them.",
                                                  flag, name, name];
            return nil;
        }
        NSDictionary* schema = SPDFAnnotateResolvedProperty(properties[property]);
        BOOL boolean = [schema[@"type"] isEqual:@"boolean"] || [schema[@"const"] isEqual:@YES];
        if (negated) { op[property] = @NO; continue; }
        if (!value && boolean && (i + 1 >= flags.count || !TruthValue(flags[i + 1]))) { op[property] = @YES; continue; }
        if (!value && i + 1 >= flags.count) {
            *problem = [NSString stringWithFormat:@"%@ needs a value.", flag];
            return nil;
        }
        if (!value) value = flags[++i];
        id converted = Convert(value, properties[property]);
        if (!converted) {
            NSArray* choices = [schema[@"enum"] isKindOfClass:NSArray.class] ? schema[@"enum"] : nil;
            *problem = choices ? [NSString stringWithFormat:@"%@ is one of %@.", flag, [choices componentsJoinedByString:@", "]]
                               : [NSString stringWithFormat:@"%@ %@ is not a value %@ takes; szpdf annotate schema %@ "
                                                            @"says what it takes.", flag, value, property, name];
            return nil;
        }
        op[property] = converted;
    }
    return op;
}

static NSArray* ScriptOperations(NSString* path, NSString* directory, NSString** problem) {
    NSData* data = [path isEqual:@"-"] ? [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile]
                                       : [NSData dataWithContentsOfFile:Absolute(path, directory)];
    id script = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([script isKindOfClass:NSDictionary.class]) script = script[@"ops"];
    NSMutableArray* ops = [NSMutableArray array];
    for (id op in [script isKindOfClass:NSArray.class] ? script : @[]) {
        if (![op isKindOfClass:NSDictionary.class] || ![op[@"op"] isKindOfClass:NSString.class]) {
            *problem = @"Each operation of the script is an object with \"op\".";
            return nil;
        }
        [ops addObject:SPDFAnnotateAbsoluteArguments(op, directory)];
    }
    if (!ops.count)
        *problem = data ? @"The script is a JSON array of operations ({\"op\": ...}), or {\"ops\": [...]}."
                        : [NSString stringWithFormat:@"No script at %@.", path];
    return ops.count ? ops : nil;
}

static NSDictionary* ParseCanvas(NSArray<NSString*>* arguments, NSError** error) {
    NSString* const name = @"canvas new";
    if (arguments.count < 2 || ![arguments[1] isEqual:@"new"]) {
        if (error) *error = Usage(@"szpdf canvas takes new: szpdf canvas new [--width W] [--height H].", name);
        return nil;
    }
    NSMutableDictionary* command = [@{@"command" : @"canvas-new", @"front" : @NO, @"timeout" : @60} mutableCopy];
    NSString* problem = nil;
    for (NSUInteger i = 2; i < arguments.count && !problem; i++) {
        NSString* flag = arguments[i];
        if ([flag isEqual:@"--help"] || [flag isEqual:@"-h"]) return @{@"command" : @"help", @"topic" : name};
        if ([flag isEqual:@"--front"]) { command[@"front"] = @YES; continue; }
        if ([flag isEqual:@"--json"]) continue;
        if (![@[ @"--width", @"--height", @"--background", @"--timeout" ] containsObject:flag]) {
            problem = [NSString stringWithFormat:@"%@ does not apply to szpdf canvas new.", flag];
            break;
        }
        if (i + 1 >= arguments.count) { problem = [NSString stringWithFormat:@"%@ needs a value.", flag]; break; }
        NSString* value = arguments[++i];
        if ([flag isEqual:@"--background"]) {
            if (![value isEqual:@"transparent"] && !Convert(value, @{@"$ref" : @"#/$defs/color"}))
                problem = @"--background is transparent or a colour as #RRGGBB.";
            command[@"background"] = value;
            continue;
        }
        NSNumber* number = Number(value, YES);
        long long high = [flag isEqual:@"--timeout"] ? 86400 : SPDF_PAINT_MAX_SIDE;
        if (!number || number.longLongValue < 1 || number.longLongValue > high)
            problem = [flag isEqual:@"--timeout"] ? @"--timeout takes whole seconds."
                                                  : [NSString stringWithFormat:@"%@ is a number of pixels from 1 to 16384.", flag];
        command[[flag substringFromIndex:2]] = number ?: @0;
    }
    if (problem) {
        if (error) *error = Usage(problem, name);
        return nil;
    }
    return command;
}

NSDictionary* SPDFMacSzpdfParseAnnotateArguments(NSArray<NSString*>* arguments, NSString* directory, NSError** error) {
    if ([arguments.firstObject isEqual:@"canvas"]) return ParseCanvas(arguments, error);
    NSString* const name = @"annotate";
    if ([arguments containsObject:@"--help"] || [arguments containsObject:@"-h"])
        return @{@"command" : @"help", @"topic" : name};
    NSMutableArray<NSString*>* rest = [[arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)] mutableCopy];
    // szpdf's own options, wherever they are; --json alone is szpdf's "answer as JSON", always true here.
    NSMutableDictionary* command = [@{@"command" : @"annotate", @"timeout" : @60} mutableCopy];
    NSString* problem = nil, *json = nil, *script = nil;
    for (NSUInteger i = 0; i < rest.count && !problem;) {
        NSString* word = rest[i];
        BOOL valued = [word isEqual:@"--timeout"] || [word isEqual:@"--script"] ||
                      ([word isEqual:@"--json"] && i + 1 < rest.count && [rest[i + 1] hasPrefix:@"{"]);
        if ([word isEqual:@"--json"] && !valued) { [rest removeObjectAtIndex:i]; continue; }
        if (!valued) { i++; continue; }
        if (i + 1 >= rest.count) { problem = [NSString stringWithFormat:@"%@ needs a value.", word]; break; }
        NSString* value = rest[i + 1];
        [rest removeObjectsInRange:NSMakeRange(i, 2)];
        if ([word isEqual:@"--json"]) json = value;
        else if ([word isEqual:@"--script"]) script = value;
        else {
            NSNumber* seconds = Number(value, YES);
            if (!seconds || seconds.longLongValue < 1 || seconds.longLongValue > 86400) problem = @"--timeout takes whole seconds.";
            command[@"timeout"] = seconds ?: @60;
        }
    }
    NSString* target = rest.count && ![rest[0] hasPrefix:@"--"] ? rest[0] : nil;
    BOOL schemaFile = target && [NSFileManager.defaultManager fileExistsAtPath:Absolute(target, directory)];
    if (!problem && [target isEqual:@"schema"] && !schemaFile) {
        if (rest.count > 2) problem = @"szpdf annotate schema takes at most one operation's name.";
        else if (rest.count == 2 && !spdf_paint_op_find([rest[1] UTF8String]))
            problem = [NSString stringWithFormat:@"No operation %@; szpdf annotate schema lists them.", rest[1]];
        else return rest.count == 2 ? @{@"command" : @"annotate-schema", @"op" : rest[1]} : @{@"command" : @"annotate-schema"};
    }
    if (!problem && !target) problem = @"szpdf annotate needs <file|tab> first, then an operation, state or --script.";
    if (!problem) {
        command[@"target"] = SPDFAnnotateIsTabIdentifier(target) ? target : Absolute(target, directory);
        NSString* verb = rest.count > 1 && ![rest[1] hasPrefix:@"--"] ? rest[1] : nil;
        NSArray* flags = [rest subarrayWithRange:NSMakeRange(verb ? 2 : 1, rest.count - (verb ? 2 : 1))];
        NSDictionary* whole = json ? JSONValue(json) : nil;
        if (json && ![whole isKindOfClass:NSDictionary.class]) problem = @"--json takes a JSON object.";
        else if (script) {
            if (verb || flags.count || json) problem = @"--script takes the operations from the file alone.";
            else {
                command[@"ops"] = ScriptOperations(script, directory, &problem) ?: @[];
                command[@"script"] = @YES;
            }
        } else if ([verb isEqual:@"state"]) {
            NSMutableDictionary* state = OperationFromFlags(@"doc.state", flags, &problem);
            if (state) {
                state[@"op"] = @"doc.state";
                command[@"ops"] = @[ state, @{@"op" : @"form.state"} ];
                command[@"state"] = @YES;
            }
        } else {
            NSString* op = verb ?: ([whole[@"op"] isKindOfClass:NSString.class] ? whole[@"op"] : nil);
            if (!op) problem = @"Name an operation (szpdf annotate schema lists them), state, or --script FILE.";
            else if (!spdf_paint_op_find(op.UTF8String))
                problem = [NSString stringWithFormat:@"No operation %@; szpdf annotate schema lists them.", op];
            else {
                NSMutableDictionary* arguments = [whole mutableCopy] ?: [NSMutableDictionary dictionary];
                NSDictionary* given = OperationFromFlags(op, flags, &problem);
                if (given) [arguments addEntriesFromDictionary:given];
                arguments[@"op"] = op;
                command[@"ops"] = @[ SPDFAnnotateAbsoluteArguments(arguments, directory) ];
            }
        }
    }
    if (problem) {
        if (error) *error = Usage(problem, name);
        return nil;
    }
    return command;
}

NSDictionary* SPDFMacSzpdfAnnotateSchemaAnswer(NSString* op) {
    if (!op) return @{@"ok" : @YES, @"schema" : SPDFAnnotateSchemaObject(), @"operations" : SPDFAnnotateOperationNames()};
    NSDictionary* schema = SPDFAnnotateOperationSchema(op);
    if (!schema) return SPDFMacSzpdfFailure(@"usage", [NSString stringWithFormat:@"No operation %@.", op], nil);
    return @{@"ok" : @YES, @"op" : op, @"schema" : schema, @"$defs" : SPDFAnnotateSchemaObject()[@"$defs"] ?: @{}};
}
