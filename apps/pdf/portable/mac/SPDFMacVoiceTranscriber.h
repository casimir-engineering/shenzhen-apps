#pragma once
// What the chat view calls on SPDFMacVoiceTranscriber.swift, Apple's on-device speech recognition (macOS 26). The class
// is looked up by name (SPDFVoiceTranscriberClass), so binaries built without the Swift file have no voice input.
#import <Foundation/Foundation.h>

@protocol SPDFVoiceTranscribing <NSObject>
@property(class, nonatomic, readonly) BOOL isSupported;
// 0: not asked yet, 1: allowed, 2: denied or restricted. Never asks.
@property(class, nonatomic, readonly) NSInteger microphoneStatus;
// The keyboard input source's language ("zh-Hans", "en"), or none.
@property(class, nonatomic, readonly) NSArray<NSString*>* inputSourceLanguages;
+ (void)requestMicrophone:(void (^)(BOOL granted))done;
// Every language speech can be turned into text in, and those already on this Mac (BCP 47), on the main thread.
+ (void)loadLanguages:(void (^)(NSArray<NSString*>* supported, NSArray<NSString*>* installed))done;
// The supported language closest to `language`, or nil.
+ (void)resolveLanguage:(NSString*)language done:(void (^)(NSString* found))done;
// The whole session's settled text and the words still being recognised.
@property(nonatomic, copy) void (^onText)(NSString* settled, NSString* pending);
// "preparing", "downloading" (with the fraction done), "listening", "finishing", "stopped".
@property(nonatomic, copy) void (^onState)(NSString* state, double fraction);
// "microphone", "language", "download", "audio" or "engine", and a message for the log.
@property(nonatomic, copy) void (^onError)(NSString* kind, NSString* message);
- (void)startWithLanguage:(NSString*)language;
- (void)startWithLanguage:(NSString*)language audioFile:(NSURL*)file realTime:(BOOL)realTime;
- (void)stop;
- (void)cancel;
@end

static inline Class<SPDFVoiceTranscribing> SPDFVoiceTranscriberClass(void) {
    Class found = NSClassFromString(@"SPDFVoiceTranscriber");
    return found && [(Class<SPDFVoiceTranscribing>)found isSupported] ? (Class<SPDFVoiceTranscribing>)found : Nil;
}
