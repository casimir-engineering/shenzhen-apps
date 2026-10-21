ifndef SPDF_AI_DOCUMENT_JOBS_TESTS_INCLUDED
SPDF_AI_DOCUMENT_JOBS_TESTS_INCLUDED := 1
# Document jobs, and where every document the assistant makes goes (mac/SPDFMacAIOutputs.h): Downloads and Collection.
# Both binaries use temporary folders for Downloads and Collection, never the person's own.
.PHONY: mac-ai-document-job-acceptance
mac-ai-document-job-acceptance: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MAC_COLLECTION_PARSER_LIBS) mupdf-libs | $(BUILD)
	rm -f "$(BUILD)/SPDFMacAIDocumentJobsTests" "$(BUILD)/SPDFMacAIOutputsTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacAIDocumentJobsTests.mm mac/SPDFMacAIDocumentJobs.mm mac/SPDFMacAIOutputFiles.mm mac/SPDFMacAILocalTool.mm mac/SPDFMacOCRCommand.mm mac/SPDFMacOCRValidation.mm mac/SPDFMacToolEnvironment.mm mac/SPDFMacImageSave.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO -lm -o "$(BUILD)/SPDFMacAIDocumentJobsTests"
	"$(BUILD)/SPDFMacAIDocumentJobsTests"
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-incomplete-implementation -Wno-objc-protocol-method-implementation -Imac mac/tests/SPDFMacAIOutputsTests.mm mac/SPDFMacAIOutputs.mm mac/SPDFMacAIOutputFiles.mm mac/SPDFMacAIChatActivity.mm mac/SPDFMacCollectionStore*.mm mac/SPDFMacSearchFileCache.mm $(MAC_COLLECTION_PARSER_SRCS) $(MAC_COLLECTION_PARSER_LIBS) -framework Cocoa -framework PDFKit -framework ImageIO -o "$(BUILD)/SPDFMacAIOutputsTests"
	"$(BUILD)/SPDFMacAIOutputsTests"

endif
