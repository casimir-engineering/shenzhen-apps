#pragma once
#import <Foundation/Foundation.h>
// A tool call's `function.arguments`, read the one way the chat session reads them before any tool runs.
//
// Providers that serve open models (the vLLM family: call ids "chatcmpl-tool-…") return arguments the model wrote
// token by token, and a long run_python call is where it shows: raw newlines and tabs inside the code string, \'
// for a quote, a ```json fence around the object, a stray token after it, or the object simply cut off while the
// finish reason still says "tool_calls". Strict JSON refused all of these and the whole request ended in an error.
//
// Strict JSON is tried first. Otherwise only repairs that cannot change what the model meant are made: surrounding
// whitespace and one ```json fence are dropped, raw control characters inside strings are escaped, an escape JSON
// does not have (\' \( …) becomes the character itself, and text after the first complete object is dropped unless
// it starts another JSON value (two objects run together could be two calls: which one was meant is not known). An
// object that ends inside a string or before its last brace is Truncated and never completed: guessing the end of
// someone's code would run code they did not write.
typedef NS_ENUM(NSInteger, SPDFMacAIToolArgumentsProblem) {
    SPDFMacAIToolArgumentsReadable,  // strict JSON, or repaired
    SPDFMacAIToolArgumentsTruncated, // the object stops before its end
    SPDFMacAIToolArgumentsInvalid,   // not one JSON object, even after the repairs above
    SPDFMacAIToolArgumentsTooLong,   // over SPDFMacAIToolArgumentsLimit characters
};
// The longest arguments string read at all, in UTF-16 units (NSString length).
extern const NSUInteger SPDFMacAIToolArgumentsLimit;
// The arguments as an object, or nil with `problem` set. `raw` is the string the provider sent (an object some
// providers send in its place is taken as it is). `repaired`, when given, is YES when the strict read failed.
NSDictionary* SPDFMacAIToolCallArguments(id raw, SPDFMacAIToolArgumentsProblem* problem, BOOL* repaired);
// The arguments as strict JSON text, for the call kept in the chat: what is sent back to the provider in later turns
// must be JSON it accepts, whatever the model first wrote.
NSString* SPDFMacAIToolArgumentsJSON(NSDictionary* arguments);
