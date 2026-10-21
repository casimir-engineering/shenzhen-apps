.PHONY: mac-ai-translation-tests
mac-ai-translation-tests: | $(BUILD)
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac mac/tests/SPDFMacAITranslationTests.mm mac/SPDFMacTranslationChoiceMenu.mm mac/SPDFMacAITranslation.mm mac/SPDFMacAITranslationPanel.mm mac/SPDFMacAIOutputFiles.mm mac/SPDFMacAITransport.mm mac/SPDFMacAISettings.mm mac/SPDFMacAICredentials.mm mac/SPDFMacSearchablePicker.mm mac/SPDFMacGroupActionButton.mm -framework Cocoa -framework UniformTypeIdentifiers -framework Security -framework LocalAuthentication -o "$(BUILD)/SPDFMacAITranslationTests"
	"$(BUILD)/SPDFMacAITranslationTests"
