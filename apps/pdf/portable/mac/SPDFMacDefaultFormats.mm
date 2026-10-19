#import "SPDFMacDefaultFormats.h"
#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
NSArray<NSDictionary*>* SPDFMacDefaultFormats(void) {
    return @[@{@"extension":@"pdf",@"name":@"PDF"},@{@"extension":@"epub",@"name":@"EPUB"},
        @{@"extension":@"md",@"name":@"Markdown"},@{@"extension":@"txt",@"name":@"Text"},
        @{@"extension":@"png",@"name":@"PNG images"},@{@"extension":@"jpg",@"name":@"JPEG images"},
        @{@"extension":@"tiff",@"name":@"TIFF images"},@{@"extension":@"svg",@"name":@"SVG images"},
        @{@"extension":@"cbz",@"name":@"Comic archives (CBZ)"},
        @{@"extension":@"docx",@"name":@"Word documents"},@{@"extension":@"xlsx",@"name":@"Excel spreadsheets"},
        @{@"extension":@"pptx",@"name":@"PowerPoint presentations"},@{@"extension":@"xps",@"name":@"XPS"},
        @{@"extension":@"mobi",@"name":@"MOBI ebooks"},@{@"extension":@"gif",@"name":@"GIF images"},
        @{@"extension":@"bmp",@"name":@"BMP images"}];
}
static NSString* TypeForExtension(NSString* extension) {
    for(NSDictionary* format in SPDFMacDefaultFormats()) if([format[@"extension"] isEqual:extension])
        return [UTType typeWithFilenameExtension:extension].identifier;
    return nil;
}
NSArray<NSDictionary*>* SPDFMacDefaultFormatStatus(void) {
    NSMutableArray* formats=[NSMutableArray array]; NSString* app=NSBundle.mainBundle.bundleIdentifier;
    for(NSDictionary* format in SPDFMacDefaultFormats()) {
        NSString* type=TypeForExtension(format[@"extension"]);
        NSString* handler=type ? CFBridgingRelease(LSCopyDefaultRoleHandlerForContentType((__bridge CFStringRef)type,kLSRolesViewer)) : nil;
        NSMutableDictionary* row=[format mutableCopy]; row[@"isDefault"]=@([handler isEqual:app]);
        [formats addObject:row];
    }
    return formats;
}
BOOL SPDFMacMakeDefaultForFormat(NSString* extension,NSError** error) {
    if(error)*error=nil;
    NSString* type=TypeForExtension(extension); NSString* app=NSBundle.mainBundle.bundleIdentifier;
    if(!type.length || !app.length) {
        if(error)*error=[NSError errorWithDomain:@"ShenzhenPDF.DefaultReader" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported file format."}]; return NO;
    }
    LSRegisterURL((__bridge CFURLRef)NSBundle.mainBundle.bundleURL,true);
    OSStatus status=LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)type,kLSRolesAll,(__bridge CFStringRef)app);
    NSString* handler=CFBridgingRelease(LSCopyDefaultRoleHandlerForContentType((__bridge CFStringRef)type,kLSRolesViewer));
    if(status==noErr && [handler isEqual:app])return YES;
    if(error)*error=[NSError errorWithDomain:@"ShenzhenPDF.DefaultReader" code:status ?: 2 userInfo:@{
        NSLocalizedDescriptionKey:[NSString stringWithFormat:@"macOS did not change the default for .%@ files.",extension],
        NSLocalizedRecoverySuggestionErrorKey:@"In Finder, select a file of this type, choose Get Info, then Open With → ShenzhenPDF → Change All."}];
    return NO;
}
