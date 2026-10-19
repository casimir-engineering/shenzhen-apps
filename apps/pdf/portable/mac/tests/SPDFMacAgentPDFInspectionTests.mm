#import "../SPDFMacAgentPDFInspection.h"
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include <assert.h>

static void writeFixture(NSString* path, NSUInteger count, CGFloat width) {
    CGRect box = CGRectMake(0, 0, width, 400);
    CGContextRef context = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &box, NULL);
    assert(context);
    for (NSUInteger page = 0; page < count; ++page) {
        CGPDFContextBeginPage(context, NULL);
        CGContextSetRGBFillColor(context, 1, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(0, 380, width, 20));
        CGContextSetRGBFillColor(context, 0, 0, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, 20));
        NSString* text = [NSString stringWithFormat:@"Page %lu inspect", (unsigned long)page + 1];
        CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), 16, NULL);
        NSAttributedString* string = [[NSAttributedString alloc] initWithString:text attributes:
            @{(__bridge NSString*)kCTFontAttributeName:(__bridge id)font}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
        CGContextSetTextPosition(context, 30, 320);
        CTLineDraw(line, context);
        CFRelease(line);
        CFRelease(font);
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context);
    CGContextRelease(context);
}

int main(void) {
    @autoreleasepool {
        NSString* temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:NO attributes:nil error:nil]);
        NSString* path = [temporary stringByAppendingPathComponent:@"sample.pdf"];
        writeFixture(path, 3, 300);
        NSData* original = [NSData dataWithContentsOfFile:path];
        NSError* error = nil;
        NSDictionary* report = SPDFMacAgentInspectPDF(@{@"path":path}, &error);
        assert(report && !error && [NSJSONSerialization isValidJSONObject:report]);
        assert([report[@"pageCount"] integerValue] == 3 && [report[@"inspectedPageCount"] integerValue] == 3);
        NSDictionary* first = [report[@"pages"] firstObject];
        assert([first[@"canonicalText"] containsString:@"Page 1 inspect"]);
        NSDictionary* line = [first[@"lines"] firstObject];
        assert([line[@"range"][@"location"] integerValue] == 0 && [line[@"range"][@"length"] integerValue] == 14);
        assert(fabs([line[@"rect"][@"x"] doubleValue] - 30) < 1);
        assert([line[@"rect"][@"y"] doubleValue] > 50 && [line[@"rect"][@"y"] doubleValue] < 85);
        assert([report isEqual:SPDFMacAgentInspectPDF(@{@"path":path}, nil)]);
        NSString* output = [temporary stringByAppendingPathComponent:@"images"];
        NSDictionary* selected = SPDFMacAgentInspectPDF(@{@"path":path, @"page":@2, @"renderDirectory":output}, &error);
        assert(selected && !error && [selected[@"pages"] count] == 1 && [selected[@"images"] count] == 1);
        assert([selected[@"pages"][0][@"page"] integerValue] == 2);
        assert([selected[@"pages"][0][@"canonicalText"] containsString:@"Page 2 inspect"]);
        NSBitmapImageRep* image = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:selected[@"images"][0]]];
        assert(image.pixelsWide == 300 && image.pixelsHigh == 400);
        NSColor* top = [[image colorAtX:10 y:10] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor* bottom = [[image colorAtX:10 y:390] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        assert(top.redComponent > 0.9 && top.blueComponent < 0.1);
        assert(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1);
        assert(!SPDFMacAgentInspectPDF(@{@"path":path, @"renderDirectory":output}, &error));
        assert([NSFileManager.defaultManager fileExistsAtPath:selected[@"images"][0]]);
        NSString* rejected = [temporary stringByAppendingPathComponent:@"rejected"];
        assert(!SPDFMacAgentInspectPDF(@{@"path":path, @"page":@4, @"renderDirectory":rejected}, &error));
        assert(![NSFileManager.defaultManager fileExistsAtPath:rejected]);
        assert(!SPDFMacAgentInspectPDF(@{@"path":path, @"paper":@{@"paper-size":@"A5"}}, &error));
        assert(!SPDFMacAgentInspectPDF(@{@"path":path, @"page":@YES}, &error));
        assert([original isEqual:[NSData dataWithContentsOfFile:path]]);
        NSString* large = [temporary stringByAppendingPathComponent:@"large.pdf"];
        writeFixture(large, 1, 5000);
        assert(!SPDFMacAgentInspectPDF(@{@"path":large, @"renderDirectory":rejected}, &error));
        assert(![NSFileManager.defaultManager fileExistsAtPath:rejected]);
        NSString* many = [temporary stringByAppendingPathComponent:@"many.pdf"];
        writeFixture(many, 102, 300);
        NSDictionary* bounded = SPDFMacAgentInspectPDF(@{@"path":many}, nil);
        assert([bounded[@"pageCount"] integerValue] == 102 && [bounded[@"pages"] count] == 100);
        assert([bounded[@"truncated"] boolValue] && [bounded[@"nextPage"] integerValue] == 101);
        assert([NSFileManager.defaultManager removeItemAtPath:temporary error:nil]);
        puts("SPDFMacAgentPDFInspectionTests passed");
    }
}
