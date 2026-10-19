#import "SPDFMacAIPagePreview.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacMarkdownPrinting.h"
#import "markdown/SPDFTextDocumentFormats.h"
#import "markdown/SPDFMarkdownDocument.h"
#import <ImageIO/ImageIO.h>
#include "shenzhen_pdf_core.h"
#include <sys/stat.h>
static id PreviewError(NSError** error, NSString* message) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.AI.Preview" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
static BOOL PreviewOptions(NSDictionary* options, CGRect* region, NSUInteger* dimension, NSError** error) {
    *region=CGRectMake(0,0,1,1); *dimension=1600;
    if (options && ![options isKindOfClass:NSDictionary.class]) return !!PreviewError(error,@"Invalid image options.");
    id value=options[@"maxDimension"];
    if (value) {
        double number=[value isKindOfClass:NSNumber.class] ? [value doubleValue] : NAN;
        if (!isfinite(number) || number<256 || number>2400 || floor(number)!=number)
            return !!PreviewError(error,@"maxDimension must be an integer between 256 and 2400 pixels.");
        *dimension=(NSUInteger)number;
    }
    NSDictionary* crop=options[@"region"];
    if (crop) {
        if (![crop isKindOfClass:NSDictionary.class]) return !!PreviewError(error,@"Invalid page region.");
        for (NSString* key in @[@"x",@"y",@"width",@"height"])
            if (![crop[key] isKindOfClass:NSNumber.class] || !isfinite([crop[key] doubleValue]))
                return !!PreviewError(error,@"Region requires finite x, y, width and height.");
        *region=CGRectMake([crop[@"x"] doubleValue],[crop[@"y"] doubleValue],
            [crop[@"width"] doubleValue],[crop[@"height"] doubleValue]);
        if (region->origin.x<0 || region->origin.y<0 || region->size.width<=0 || region->size.height<=0 ||
            CGRectGetMaxX(*region)>1 || CGRectGetMaxY(*region)>1)
            return !!PreviewError(error,@"Region must be inside the page in normalized top-left coordinates (0 to 1).");
    }
    return YES;
}
static NSData* PreviewPNG(CGImageRef image) {
    if (!image) return nil;
    NSMutableData* data=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
        CFSTR("public.png"),1,NULL);
    if (!destination) return nil;
    CGImageDestinationAddImage(destination,image,NULL);
    BOOL success=CGImageDestinationFinalize(destination); CFRelease(destination);
    return success ? data : nil;
}
static NSDictionary* Preview(NSString* path, BOOL landscape, NSUInteger page, NSDictionary* candidate,
    NSDictionary* options, NSProgress* progress, NSError** error) {
    CGRect region; NSUInteger dimension;
    if (!PreviewOptions(options,&region,&dimension,error)) return nil;
    NSString* stamp=SPDFSearchFileStamp(path);
    if (!page || !stamp || progress.cancelled) return PreviewError(error,@"Page unavailable or request cancelled.");
    if (candidate[@"revision"] && ![candidate[@"revision"] isEqual:stamp])
        return PreviewError(error,@"This document snapshot is stale. Wait for the reader to reload it.");
    NSData* png=nil; NSUInteger pixelsWide=0,pixelsHigh=0; NSSize paper=NSZeroSize;
    if (SPDFIsRenderedTextDocumentPath(path)) {
        if (candidate && ![candidate[@"sourceRevision"] isEqual:candidate[@"revision"]])
            return PreviewError(error,@"This text snapshot is stale. Wait for the reader to reload it.");
        SPDFMarkdownPaginationPlan* plan=candidate[@"paginationPlan"];
        SPDFMarkdownRenderedDocument* rendered=candidate[@"renderedDocument"];
        if (candidate && (!plan || !rendered)) return PreviewError(error,@"Open this text document before rendering a page preview.");
        if (!candidate) {
            SPDFMarkdownDocument* doc=[SPDFMarkdownDocument documentWithURL:[NSURL fileURLWithPath:path] options:nil error:error];
            if (!doc) return nil;
            SPDFMarkdownPageConfiguration* configuration=landscape ? [SPDFMarkdownPageConfiguration A4LandscapeConfiguration] :
                [SPDFMarkdownPageConfiguration A4PortraitConfiguration];
            plan=[doc paginationPlanForConfiguration:doc.authoredPageConfiguration ?: configuration]; rendered=doc.renderedDocument;
        }
        if (page>plan.pages.count) return PreviewError(error,@"Page is outside the document.");
        paper=plan.configuration.paperSize;
        if (paper.width<=0 || paper.height<=0 || !isfinite(paper.width) || !isfinite(paper.height))
            return PreviewError(error,@"Invalid paper dimensions.");
        CGFloat width=paper.width*region.size.width,height=paper.height*region.size.height;
        CGFloat scale=dimension/MAX(width,height);
        if (!isfinite(scale) || scale>10000) return PreviewError(error,@"Region is too small to render safely.");
        pixelsWide=MAX(1,(NSUInteger)ceil(width*scale)); pixelsHigh=MAX(1,(NSUInteger)ceil(height*scale));
        pixelsWide=MIN(dimension,pixelsWide); pixelsHigh=MIN(dimension,pixelsHigh);
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(NULL,pixelsWide,pixelsHigh,8,pixelsWide*4,space,kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
        if (!context) return PreviewError(error,@"Page image could not be allocated.");
        CGContextSetRGBFillColor(context,1,1,1,1); CGContextFillRect(context,CGRectMake(0,0,pixelsWide,pixelsHigh));
        CGContextScaleCTM(context,scale,scale);
        // The public crop uses top-left coordinates; the print plan draws into a bottom-left Quartz context.
        CGContextTranslateCTM(context,-paper.width*region.origin.x,-paper.height*(1-CGRectGetMaxY(region)));
        [plan drawPageAtIndex:page-1 attributedString:rendered.attributedString inContext:context];
        CGImageRef image=CGBitmapContextCreateImage(context); png=PreviewPNG(image);
        if (image) CGImageRelease(image); CGContextRelease(context);
    } else {
        char message[1024]={}; spdf_document* doc=spdf_open(path.fileSystemRepresentation,message,sizeof(message));
        if (!doc) return PreviewError(error,@"Document is locked or unavailable.");
        float width=0,height=0;
        if (page>(NSUInteger)spdf_page_count(doc) ||
            !spdf_page_size(doc,(int)page-1,&width,&height,message,sizeof(message)) ||
            width<=0 || height<=0 || !isfinite(width) || !isfinite(height)) {
            spdf_close(doc); return PreviewError(error,@"Page is outside the document or has invalid dimensions.");
        }
        paper=NSMakeSize(width,height);
        spdf_rect crop={(float)(width*region.origin.x),(float)(height*region.origin.y),
            (float)(width*CGRectGetMaxX(region)),(float)(height*CGRectGetMaxY(region))};
        // Reserve two pixels for outward rounding of a crop with a fractional pixel origin.
        float scale=(dimension-2)/MAX(crop.x1-crop.x0,crop.y1-crop.y0);
        if (!isfinite(scale) || scale>10000 || scale<=0) {
            spdf_close(doc); return PreviewError(error,@"Region is too small to render safely.");
        }
        NSObject* tokenLock=[NSObject new]; __block spdf_render_token* token=spdf_render_token_new();
        void (^previousCancellation)(void)=progress.cancellationHandler;
        progress.cancellationHandler=^{
            @synchronized(tokenLock) { if (token) spdf_render_token_cancel(token); }
            if (previousCancellation) previousCancellation();
        };
        if (progress.cancelled) spdf_render_token_cancel(token);
        spdf_bitmap bitmap={};
        BOOL rendered=spdf_render_page_region_rgba_opts(doc,(int)page-1,scale,crop,SPDF_RENDER_DEFAULT,
            token,&bitmap,message,sizeof(message));
        @synchronized(tokenLock) { spdf_render_token_free(token); token=NULL; }
        progress.cancellationHandler=previousCancellation; spdf_close(doc);
        if (!rendered) return PreviewError(error,progress.cancelled ? @"Request cancelled." : @"Page could not be rendered.");
        pixelsWide=bitmap.width; pixelsHigh=bitmap.height;
        if (pixelsWide>dimension || pixelsHigh>dimension) {
            spdf_free_bitmap(&bitmap); return PreviewError(error,@"Page image exceeds its pixel budget.");
        }
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,bitmap.rgba,(size_t)bitmap.stride*bitmap.height,NULL);
        CGImageRef image=CGImageCreate(bitmap.width,bitmap.height,8,32,bitmap.stride,space,
            kCGImageAlphaLast|kCGBitmapByteOrder32Big,provider,NULL,false,kCGRenderingIntentDefault);
        CGColorSpaceRelease(space); CGDataProviderRelease(provider);
        png=PreviewPNG(image);
        if (image) CGImageRelease(image); spdf_free_bitmap(&bitmap);
    }
    if (!png || png.length>8*1024*1024) return PreviewError(error,@"Page preview exceeds its image budget.");
    if (progress.cancelled || ![stamp isEqual:SPDFSearchFileStamp(path)]) return PreviewError(error,@"Page changed or request cancelled.");
    NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ShenzhenPDF-AI-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSString* output=[root stringByAppendingPathComponent:@"page.png"];
    if (![png writeToFile:output options:NSDataWritingAtomic error:error]) { [NSFileManager.defaultManager removeItemAtPath:root error:nil]; return nil; }
    chmod(output.fileSystemRepresentation,0600);
    return @{@"path":output,@"revision":stamp,@"page":@(page),@"pixelWidth":@(pixelsWide),@"pixelHeight":@(pixelsHigh),
        @"pageWidth":@(paper.width),@"pageHeight":@(paper.height),@"maxDimension":@(dimension),
        @"region":@{@"x":@(region.origin.x),@"y":@(region.origin.y),@"width":@(region.size.width),@"height":@(region.size.height)}};
}
NSDictionary* SPDFAIPagePreview(NSString* path, BOOL landscape, NSUInteger page, NSProgress* progress, NSError** error) {
    return Preview(path,landscape,page,nil,nil,progress,error);
}
NSDictionary* SPDFAIPagePreviewForCandidate(NSDictionary* candidate, NSUInteger page, NSProgress* progress, NSError** error) {
    return SPDFAIPagePreviewForCandidateWithOptions(candidate,page,nil,progress,error);
}
NSDictionary* SPDFAIPagePreviewWithOptions(NSString* path, BOOL landscape, NSUInteger page, NSDictionary* options,
    NSProgress* progress, NSError** error) {
    return Preview(path,landscape,page,nil,options,progress,error);
}
NSDictionary* SPDFAIPagePreviewForCandidateWithOptions(NSDictionary* candidate, NSUInteger page, NSDictionary* options,
    NSProgress* progress, NSError** error) {
    return Preview(candidate[@"readPath"] ?: candidate[@"path"],[candidate[@"landscape"] boolValue],page,candidate,options,progress,error);
}
