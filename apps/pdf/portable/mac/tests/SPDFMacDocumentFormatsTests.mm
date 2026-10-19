#define SPDF_TEXT_DOCUMENT_FORMAT_TESTING 1
#import "SPDFMacSupport.h"
#import "SPDFMacCollectionThumbnail.h"
#include "shenzhen_pdf_core.h"
#include "spdf_recolor.h"
#include <stdio.h>

static void Check(BOOL ok, NSString* message) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        Check(argc==3,@"fixture and repository paths required");
        NSString* directory = @(argv[1]); NSString* repo = @(argv[2]);
        NSFileManager* fm = NSFileManager.defaultManager;
        Check(SPDFReadableDocumentPath(@"document.pdf") && SPDFReadableDocumentPath(@"picture.png") &&
            SPDFReadableDocumentPath(@"source.py") && SPDFReadableDocumentPath(@"notes.mdown") &&
            !SPDFReadableDocumentPath(@"unknown.bin"), @"ordinary path classification works without materializing catalogs");
        Check(SPDFSourceDocumentCatalogBuildCount == 0, @"PDF/image/source/title path checks do not initialize source catalog");
        // The picker, drop filter and Launch Services must advertise the same set.
        NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:
            [repo stringByAppendingPathComponent:@"portable/mac/Info.plist"]];
        NSMutableSet* registered = [NSMutableSet set];
        for (NSDictionary* type in plist[@"CFBundleDocumentTypes"])
            [registered addObjectsFromArray:type[@"CFBundleTypeExtensions"] ?: @[]];
        Check([registered isEqualToSet:[NSSet setWithArray:SPDFReadableDocumentExtensions()]],@"Finder types match opening policy");
        Check(SPDFSourceDocumentCatalogBuildCount == 1, @"complete Open extension list explicitly initializes source catalog");
        NSArray* types = spdf_document_content_types();
        for (NSString* ext in SPDFReadableDocumentExtensions()) {
            Check(SPDFReadableDocumentPath([@"test." stringByAppendingString:ext.uppercaseString]),ext);
            Check([types containsObject:[UTType typeWithFilenameExtension:ext]],[@"Picker includes " stringByAppendingString:ext]);
            Check([spdf_display_name_for_path([@"file." stringByAppendingString:ext]) isEqual:@"file"],[@"tab title hides " stringByAppendingString:ext]);
        }
        for (NSString* unsupported in @[@"x.heic",@"x.webp",@"x.jxr",@"x.cbr",@"x.exe",@"x.doc",@"x.spdf-command"])
            Check(!SPDFReadableDocumentPath(unsupported),@"unlinked decoders and command files excluded");
        // ImageIO encoders supply real image fixtures without optional tooling.
        NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:24 pixelsHigh:24
            bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:72 bitsPerPixel:24];
        for(int i=0;i<24*24;i++) { bitmap.bitmapData[i*3]=32; bitmap.bitmapData[i*3+1]=96; bitmap.bitmapData[i*3+2]=192; }
        NSDictionary* encoders = @{@"jpg":@(NSBitmapImageFileTypeJPEG),@"tiff":@(NSBitmapImageFileTypeTIFF),
            @"bmp":@(NSBitmapImageFileTypeBMP),@"gif":@(NSBitmapImageFileTypeGIF),@"jp2":@(NSBitmapImageFileTypeJPEG2000)};
        for (NSString* ext in encoders) {
            NSData* bytes = [bitmap representationUsingType:(NSBitmapImageFileType)[encoders[ext] integerValue] properties:@{}];
            Check(bytes.length>0,[@"encode " stringByAppendingString:ext]);
            Check([bytes writeToFile:[directory stringByAppendingPathComponent:[@"picture." stringByAppendingString:ext]] atomically:YES],@"write image");
        }
        NSUInteger rendered=0;
        for (NSString* filename in [fm contentsOfDirectoryAtPath:directory error:nil]) {
            NSString* path = [directory stringByAppendingPathComponent:filename];
            char error[512]={0}; spdf_document* doc = spdf_open(path.fileSystemRepresentation,error,sizeof(error));
            Check(doc!=NULL,[NSString stringWithFormat:@"open %@: %s",filename,error]);
            Check(spdf_page_count(doc)>0,[@"page count " stringByAppendingString:filename]);
            spdf_bitmap pixels={};
            Check(spdf_render_page_rgba(doc,0,.5,&pixels,error,sizeof(error)),[NSString stringWithFormat:@"render %@: %s",filename,error]);
            Check(pixels.width>0 && pixels.height>0 && pixels.rgba,@"render has pixels");
            BOOL ink=NO;
            for(int y=0;y<pixels.height && !ink;y++) for(int x=0;x<pixels.width;x++) {
                unsigned char* p=pixels.rgba+y*pixels.stride+x*4;
                if (MIN(p[0],MIN(p[1],p[2]))<240) { ink=YES; break; }
            }
            Check(ink,[@"page contains visible content: " stringByAppendingString:filename]);
            if (spdf_recolor_path_is_picture(path.UTF8String)) {
                spdf_bitmap dark={};
                Check(spdf_render_page_rgba_opts(doc,0,.5,SPDF_RENDER_DARK_THEME | SPDF_RENDER_PRESERVE_IMAGES,NULL,&dark,error,sizeof(error)),@"dark picture render");
                Check(dark.width==pixels.width && dark.height==pixels.height && dark.stride==pixels.stride &&
                    !memcmp(dark.rgba,pixels.rgba,pixels.stride*pixels.height),@"dark theme preserves picture pixels");
                spdf_free_bitmap(&dark);
                Check(spdf_render_page_rgba_opts(doc,0,.5,SPDF_RENDER_DARK_THEME,NULL,&dark,error,sizeof(error)),
                    @"dark picture render with Keep Image Colors disabled");
                Check(dark.width==pixels.width && dark.height==pixels.height && dark.stride==pixels.stride &&
                    memcmp(dark.rgba,pixels.rgba,pixels.stride*pixels.height),@"disabled preservation recolors picture pixels");
                spdf_free_bitmap(&dark);
            }
            if ([@[@"png",@"jpg",@"tiff",@"bmp",@"gif",@"jp2"] containsObject:path.pathExtension]) {
                NSImage* thumbnail=SPDFCollectionImageThumbnail([NSURL fileURLWithPath:path],1);
                Check(thumbnail!=nil,[@"Collection image preview " stringByAppendingString:filename]);
                Check(thumbnail.size.width<=300 && thumbnail.size.height<=300,@"bounded thumbnail dimensions");
                Check(spdf_recolor_path_is_picture(path.UTF8String),@"pictures retain original colors");
            }
            NSString* evidence=NSProcessInfo.processInfo.environment[@"SPDF_FORMAT_EVIDENCE_DIR"];
            if (evidence.length && [@[@"picture.png",@"word.docx",@"book.epub"] containsObject:filename]) {
                [fm createDirectoryAtPath:evidence withIntermediateDirectories:YES attributes:nil error:nil];
                unsigned char* plane=pixels.rgba;
                NSBitmapImageRep* rendered=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&plane
                    pixelsWide:pixels.width pixelsHigh:pixels.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                    isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:pixels.stride bitsPerPixel:32];
                [[rendered representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:
                    [evidence stringByAppendingPathComponent:[filename stringByAppendingString:@".png"]] atomically:YES];
            }
            spdf_free_bitmap(&pixels); spdf_close(doc); ++rendered;
            printf("Rendered %s\n",filename.UTF8String);
        }
        NSString* imagePath=[directory stringByAppendingPathComponent:@"picture.png"];
        NSString* sourcePath=[directory stringByAppendingPathComponent:@"example.py"];
        [@"print('literal source')" writeToFile:sourcePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString* folder=[directory stringByAppendingPathComponent:@"folder.pdf"];
        [fm createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:nil];
        NSPasteboard* board=[NSPasteboard pasteboardWithUniqueName];
        [board writeObjects:@[[NSURL fileURLWithPath:imagePath], [NSURL fileURLWithPath:sourcePath], [NSURL fileURLWithPath:folder],
            [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"absent.pdf"]],
            [NSURL URLWithString:@"https://example.com/image.png"]]];
        Check([SPDFDocumentPathsFromPasteboard(board) isEqual:@[imagePath,sourcePath]],@"drop accepts local readable file and rejects folder/missing/remote URLs");
        [board clearContents];
        NSString* invalid=[directory stringByAppendingPathComponent:@"invalid.png"];
        const unsigned char truncatedPNG[]={137,80,78,71,13,10,26,10,0,0,0,0};
        [[NSData dataWithBytes:truncatedPNG length:sizeof(truncatedPNG)] writeToFile:invalid atomically:YES];
        [board writeObjects:@[[NSURL fileURLWithPath:invalid]]];
        Check(SPDFDocumentPathsFromPasteboard(board).count==1,@"hover/drop policy does not eagerly decode file contents");
        char invalidError[512]={0};
        spdf_document* invalidDoc=spdf_open(invalid.fileSystemRepresentation,invalidError,sizeof(invalidError));
        spdf_bitmap invalidPixels={};
        BOOL decoded=invalidDoc && spdf_render_page_rgba(invalidDoc,0,1,&invalidPixels,invalidError,sizeof(invalidError));
        Check(!decoded && invalidError[0],@"unreadable files return an ordinary decoding error");
        spdf_free_bitmap(&invalidPixels); if(invalidDoc) spdf_close(invalidDoc);
        [board releaseGlobally];
        // Guard the native entry points without creating or ordering a reader window.
        NSDictionary* contracts=@{
            @"SPDFMacFileBrowsing.mm":@"SPDFDocumentPathsFromPasteboard(pasteboard)",
            @"SPDFMacDocumentView.mm":@"SPDFDocumentPathsFromPasteboard(sender.draggingPasteboard)",
            @"SPDFMacUIHelpers.mm":@"SPDFDocumentPathsFromPasteboard(sender.draggingPasteboard)",
            @"SPDFMacTabStripDrag.mm":@"[self.reader openFilesFromPasteboard:sender.draggingPasteboard]",
            @"SPDFMacTabStripView.mm":@"SPDFTabDragPasteboardType, NSPasteboardTypeFileURL"};
        for (NSString* file in contracts) {
            NSString* source=[NSString stringWithContentsOfFile:[[repo stringByAppendingPathComponent:@"portable/mac"]
                stringByAppendingPathComponent:file] encoding:NSUTF8StringEncoding error:nil];
            Check([source containsString:contracts[file]],[@"drop routing: " stringByAppendingString:file]);
        }
        printf("SPDFMacDocumentFormatsTests passed (%lu rendered fixtures)\n",(unsigned long)rendered);
    }
    return 0;
}
