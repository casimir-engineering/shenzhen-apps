#import <Foundation/Foundation.h>
#import "SPDFMacDocumentRename.h"
static int failures;
static void Check(BOOL ok, NSString* label) { if (!ok) { failures++; fprintf(stderr,"FAIL %s\n",label.UTF8String); } }
int main(void) { @autoreleasepool {
    NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* source=[directory stringByAppendingPathComponent:@"Original.PDF"];
    NSData* contents=[@"unchanged document bytes" dataUsingEncoding:NSUTF8StringEncoding];
    [contents writeToFile:source atomically:YES];
    NSString* destination=SPDFDocumentRenameDestination(source,@"  Assembly R2  ");
    Check([destination.lastPathComponent isEqual:@"Assembly R2.PDF"],@"preserve original extension");
    Check([SPDFDocumentRenameDestination(source,@"Renamed.pdf").lastPathComponent isEqual:@"Renamed.pdf"],@"avoid duplicate extensions");
    for (NSString* name in @[@"",@"..",@"../outside",@"folder/name",@"a:b",@"a\nb"])
        Check(SPDFDocumentRenameDestination(source,name)==nil,@"reject invalid names and directory traversal");
    NSError* error=nil;
    Check(SPDFRenameDocumentFile(source,destination,&error),@"rename existing file");
    Check(![NSFileManager.defaultManager fileExistsAtPath:source] && [[NSData dataWithContentsOfFile:destination] isEqual:contents],@"move without altering document bytes");
    [contents writeToFile:source atomically:YES];
    Check(!SPDFRenameDocumentFile(source,destination,&error),@"never overwrite another file");
    Check([NSFileManager.defaultManager fileExistsAtPath:source],@"failed rename leaves original intact");
    Check(SPDFRenameDocumentFile(destination,destination,&error),@"unchanged name is a no-op");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    if (!failures) puts("Document rename tests passed");
} return failures ? 1 : 0; }
