ifndef SPDF_AI_DOCUMENT_JOBS_TESTS_INCLUDED
SPDF_AI_DOCUMENT_JOBS_TESTS_INCLUDED := 1
.PHONY: mac-ai-document-job-acceptance
mac-ai-document-job-acceptance: $(CORE_OBJ) $(CORE_RECOLOR_OBJ) mupdf-libs | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Imac -Icore -I$(MUPDF_DIR)/include mac/tests/SPDFMacAIDocumentJobsTests.mm mac/SPDFMacAIDocumentJobs.mm mac/SPDFMacAILocalTool.mm mac/SPDFMacOCRCommand.mm mac/SPDFMacOCRValidation.mm mac/SPDFMacToolEnvironment.mm mac/SPDFMacImageSave.mm $(CORE_OBJ) $(CORE_RECOLOR_OBJ) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO -lm -o "$(BUILD)/SPDFMacAIDocumentJobsTests"
	"$(BUILD)/SPDFMacAIDocumentJobsTests"

endif
