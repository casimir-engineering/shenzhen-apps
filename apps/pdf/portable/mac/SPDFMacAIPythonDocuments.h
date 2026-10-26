#pragma once
// The documents run_python may read (SPDFMacAIPythonToolProvider.h): the ones the assistant itself may see, named by
// the ids it already uses (doc:… for an open document, collection:… from list_collection, attachment:… for a file
// attached to the chat). For each run the app prepares a private folder, which the sandbox lets the code read and
// nothing else (mac/python-sandbox/SPDFPythonSandbox.h): a link to each document under a plain name, the images a PDF
// page embeds at native resolution (losslessly), pages rendered to PNG at the dpi asked for, and index.json saying
// which file is which. The code sees it as ./documents.
#import <Foundation/Foundation.h>

@class SPDFMacAIRequestContext;

NS_ASSUME_NONNULL_BEGIN

// What the model asks for, one entry of run_python's `documents`: {"id", "path" (a file inside an attached folder),
// "images_on_pages": [n], "render_pages": [n], "dpi": n}. Checked before anything runs: a problem written for the
// model, or nil.
NSString* _Nullable SPDFMacAIPythonDocumentsProblem(id _Nullable requests);

// One document the request may read: the id the model used, its title and its file.
@interface SPDFMacAIPythonDocument : NSObject
+ (instancetype)documentWithIdentifier:(NSString*)identifier title:(NSString*)title path:(NSString*)path;
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy) NSString* path;
@end

// Turns the requests' ids (and paths) into documents the assistant may see, one per request in order, or says why not
// ("Use a doc: id from list_workspace…"). Attachments come from the request's own chips only. Called on the main
// thread; `completion` runs once on the main thread.
typedef void (^SPDFMacAIPythonDocumentResolver)(NSArray<NSDictionary*>* requests, SPDFMacAIRequestContext* context,
                                               void (^completion)(NSArray<SPDFMacAIPythonDocument*>* _Nullable documents,
                                                                  NSString* _Nullable problem));

// An attachment: request ({"id", "path"?}) as the document it names, found only among `chips`, the request's own
// (SPDFMacAIChatGrants.h): an id another chat was given is unknown here. A path inside an attached folder must stay
// inside it, links followed. nil with a problem for the model.
@class SPDFMacAIRequestChip;
SPDFMacAIPythonDocument* _Nullable SPDFMacAIPythonAttachmentDocument(NSDictionary* request,
                                                                    NSArray<SPDFMacAIRequestChip*>* chips,
                                                                    NSString* _Nullable* _Nullable problem);

// The ids run_python takes, by prefix: doc:, collection:, attachment:.
BOOL SPDFMacAIPythonDocumentIdentifierValid(id identifier);

// A prepared folder. Remove it once the run is over.
@interface SPDFMacAIPythonDocumentFolder : NSObject
@property(nonatomic, readonly, copy) NSString* path;
// The documents' own files, by real path, which the sandbox may read by exact path.
@property(nonatomic, readonly, copy) NSArray<NSString*>* files;
// index.json's content, also returned to the model: {"documents": [{id, title, file, pages?, images: [{page, file,
// width, height, …}], renders: [{page, dpi, file, width, height}]}]}, paths relative to the working directory.
@property(nonatomic, readonly, copy) NSDictionary* index;
- (void)remove;
@end

// Prepares the folder off the main thread, then calls `completion` on the main thread with it, or with a problem for
// the model. `cancelled` is polled between images.
void SPDFMacAIPythonPrepareDocuments(NSArray<NSDictionary*>* requests, NSArray<SPDFMacAIPythonDocument*>* documents,
                                     BOOL (^cancelled)(void),
                                     void (^completion)(SPDFMacAIPythonDocumentFolder* _Nullable folder,
                                                        NSString* _Nullable problem));

// "pages 4 and 5 of Report", for the step's status while the folder is prepared.
NSString* SPDFMacAIPythonDocumentsSummary(NSArray<NSDictionary*>* requests, NSArray<SPDFMacAIPythonDocument*>* documents);

NS_ASSUME_NONNULL_END
