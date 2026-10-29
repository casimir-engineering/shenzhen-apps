.PHONY: mac-ai-translation-tests
mac-ai-translation-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAITranslationTests.mm mac/SPDFMacAITranslation.mm mac/SPDFMacAIJobTranslator.mm mac/SPDFMacAIChatActivity.mm mac/SPDFMacTranslateLanguagePopover.mm mac/SPDFMacAIOutputFiles.mm mac/SPDFMacAITransport.mm -framework Cocoa -framework Security -o "$(BUILD)/SPDFMacAITranslationTests"
	"$(BUILD)/SPDFMacAITranslationTests"
