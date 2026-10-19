#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
// Provenance belongs to the parsed source model, not to whichever file happens
// to occupy its URL later. Rerenders retain it; a disk reload installs a new one.
static inline NSString* SPDFMacMarkdownSourceRevision(id model) {
    return objc_getAssociatedObject(model,NSSelectorFromString(@"spdfLoadedSourceRevision"));
}
static inline void SPDFMacMarkdownSetSourceRevision(id model, NSString* revision) {
    objc_setAssociatedObject(model,NSSelectorFromString(@"spdfLoadedSourceRevision"),revision,OBJC_ASSOCIATION_COPY_NONATOMIC);
}
