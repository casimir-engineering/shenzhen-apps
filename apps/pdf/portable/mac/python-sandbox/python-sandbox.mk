# The assistant's Python sandbox (mac/python-sandbox/SPDFPythonSandbox.h): the helper ShenzhenPDF.app embeds as
# Contents/Helpers/spdf-python-sandbox, and the suites behind mac-ai-python-tests. Included by portable/Makefile, so
# make runs in portable/ and every path is relative to it.
#
# The helper is a bare Mach-O with its Info.plist in __TEXT,__info_plist: codesign takes the identifier from there,
# and Contents/Helpers is where nested code is signed on its own before the outer bundle, like the Collection
# companion and the Friends helper. Same architecture and deployment target as the app, so the release verifier's
# Mach-O sweep (arm64, minOS 12.0, no Homebrew libraries) holds for it too.
MAC_PYTHON_SANDBOX_DIR := mac/python-sandbox
MAC_PYTHON_SANDBOX_NAME := spdf-python-sandbox
MAC_PYTHON_SANDBOX_IDENTIFIER := com.intuition.shenzhenpdf.python-sandbox
MAC_PYTHON_SANDBOX_SRCS := $(addprefix $(MAC_PYTHON_SANDBOX_DIR)/,SPDFPythonSandboxMain.m SPDFPythonSandboxRun.m \
	SPDFPythonSandboxFiles.m SPDFPythonSandboxProfile.m SPDFPythonSandboxExec.c)
MAC_PYTHON_SANDBOX_HDRS := $(wildcard $(MAC_PYTHON_SANDBOX_DIR)/*.h)
MAC_PYTHON_SANDBOX_BUILD := $(BUILD)/python-sandbox
MAC_PYTHON_SANDBOX_BIN := $(MAC_PYTHON_SANDBOX_BUILD)/$(MAC_PYTHON_SANDBOX_NAME)
MAC_PYTHON_SANDBOX_HELPER := $(MAC_APP)/Contents/Helpers/$(MAC_PYTHON_SANDBOX_NAME)
MAC_PYTHON_SANDBOX_FLAGS := $(MAC_TARGET_FLAGS) -fobjc-arc -Wall -Wextra -Werror -I$(MAC_PYTHON_SANDBOX_DIR)

MAC_PYTHON_SANDBOX_PLIST := $(MAC_PYTHON_SANDBOX_BUILD)/Info.plist

# The embedded Info.plist carries the app's version and build, as the app's own does, so crash reports and the
# notary log name a real release. Regenerated on every make, but replaced (and the helper relinked) only when its
# text changes: make cannot see MAC_VERSION or MAC_BUILD change, and the plist is linked in, not set afterwards.
.PHONY: mac-python-sandbox-plist-check
mac-python-sandbox-plist-check:
$(MAC_PYTHON_SANDBOX_PLIST): $(MAC_PYTHON_SANDBOX_DIR)/Info.plist mac-python-sandbox-plist-check
	@mkdir -p "$(@D)"
	@case "$(MAC_BUILD)" in ''|*[!0-9]*) echo "MAC_BUILD must be a whole number: $(MAC_BUILD)" >&2; exit 1;; esac
	sed -e 's/SPDF_PYTHON_SANDBOX_VERSION/$(MAC_VERSION)/' -e 's/SPDF_PYTHON_SANDBOX_BUILD/$(MAC_BUILD)/' \
		$(MAC_PYTHON_SANDBOX_DIR)/Info.plist > "$@.new"
	@if grep -q SPDF_PYTHON_SANDBOX_ "$@.new"; then echo "unreplaced placeholder in $@" >&2; exit 1; fi
	@if cmp -s "$@.new" "$@"; then rm -f "$@.new"; else mv "$@.new" "$@"; fi

$(MAC_PYTHON_SANDBOX_BIN): $(MAC_PYTHON_SANDBOX_SRCS) $(MAC_PYTHON_SANDBOX_HDRS) $(MAC_PYTHON_SANDBOX_PLIST) \
	$(MAC_PYTHON_SANDBOX_DIR)/python-sandbox.mk
	@mkdir -p "$(@D)"
	clang $(PORTABLE_OPTFLAGS) $(MAC_PYTHON_SANDBOX_FLAGS) $(MAC_PYTHON_SANDBOX_SRCS) -framework Foundation \
		-sectcreate __TEXT __info_plist "$(MAC_PYTHON_SANDBOX_PLIST)" -Wl,-dead_strip -o "$@"

# Copied in by the app build after the Friends helper; signed by its own line before the outer bundle.
define MAC_PYTHON_SANDBOX_EMBED
mkdir -p "$(MAC_APP)/Contents/Helpers"
cp "$(MAC_PYTHON_SANDBOX_BIN)" "$(MAC_PYTHON_SANDBOX_HELPER)"
endef

# Run at the end of the app build: a stale or unsigned helper would make every run_python refuse.
define MAC_PYTHON_SANDBOX_CHECK
codesign --verify --strict --verbose=2 "$(MAC_PYTHON_SANDBOX_HELPER)"
test "$$(codesign -d --verbose=2 "$(MAC_PYTHON_SANDBOX_HELPER)" 2>&1 | sed -n 's/^Identifier=//p')" = \
	"$(MAC_PYTHON_SANDBOX_IDENTIFIER)"
test -x "$(MAC_PYTHON_SANDBOX_HELPER)"
test "$$(launchctl plist __TEXT,__info_plist "$(MAC_PYTHON_SANDBOX_HELPER)" | \
	sed -n 's/^[[:space:]]*"CFBundleShortVersionString" = "\(.*\)";$$/\1/p')" = "$(MAC_VERSION)"
endef

# The suites. Both run the real helper and a real Python on this Mac in throwaway directories, with no network:
# SPDFPythonSandboxTests attempts every escape the plan names; SPDFMacAIPythonTests drives run_python through the
# reader's provider, runner and installer, and Settings' Python row (with a stand-in install script: a suite never
# downloads anything). SPDFPythonSandboxPackagingTests checks the helper's embedded version and the release
# verifier's checks of it.
MAC_PYTHON_SANDBOX_TEST := $(MAC_PYTHON_SANDBOX_BUILD)/SPDFPythonSandboxTests
MAC_AI_PYTHON_TEST := $(MAC_PYTHON_SANDBOX_BUILD)/SPDFMacAIPythonTests
MAC_AI_PYTHON_SRCS := mac/SPDFMacAIPythonToolProvider.mm mac/SPDFMacAIPythonRunner.mm mac/SPDFMacAIPythonResults.mm \
	mac/SPDFMacAIPythonInstall.mm mac/SPDFMacAIPythonSettingsSource.mm mac/SPDFMacAIPythonDocuments.mm \
	mac/SPDFMacAIPythonOutputs.mm mac/SPDFMacAIChatGrants.mm mac/SPDFMacAIAttachmentToolProvider.mm \
	mac/SPDFMacAIWebPDF.mm mac/SPDFMacAIWebAddress.mm mac/SPDFMacAIChatSessionGrants.mm mac/SPDFMacAIOutputFiles.mm \
	mac/SPDFMacAISaveFileToolProvider.mm
MAC_AI_PYTHON_PROFILE_OBJ := $(MAC_PYTHON_SANDBOX_BUILD)/SPDFPythonSandboxProfile.o

.PHONY: mac-ai-python-suite
mac-ai-python-suite: $(MAC_PYTHON_SANDBOX_BIN) $(CORE_OBJS) mupdf-libs
	bash $(MAC_PYTHON_SANDBOX_DIR)/tests/SPDFPythonSandboxPackagingTests.sh "$(MAC_PYTHON_SANDBOX_BIN)" \
		"$(MAC_PYTHON_SANDBOX_PLIST)" "$(MAC_VERSION)"
	rm -f "$(MAC_PYTHON_SANDBOX_TEST)" "$(MAC_AI_PYTHON_TEST)" "$(MAC_AI_PYTHON_PROFILE_OBJ)"
	clang $(MAC_PYTHON_SANDBOX_FLAGS) -I$(MAC_PYTHON_SANDBOX_DIR)/tests \
		$(MAC_PYTHON_SANDBOX_DIR)/tests/SPDFPythonSandboxTests.m $(MAC_PYTHON_SANDBOX_DIR)/SPDFPythonSandboxProfile.m \
		$(MAC_PYTHON_SANDBOX_DIR)/SPDFPythonSandboxFiles.m -framework Foundation -o "$(MAC_PYTHON_SANDBOX_TEST)"
	"$(MAC_PYTHON_SANDBOX_TEST)" "$(MAC_PYTHON_SANDBOX_BIN)"
	clang $(MAC_PYTHON_SANDBOX_FLAGS) -c $(MAC_PYTHON_SANDBOX_DIR)/SPDFPythonSandboxProfile.m \
		-o "$(MAC_AI_PYTHON_PROFILE_OBJ)"
	# The reader's two hooks for Settings' Python row need the whole app to link: compiled for syntax here, and
	# their lines checked as source text by the suite.
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -fsyntax-only -Imac -Icore \
		-I$(MUPDF_DIR)/include mac/SPDFMacAIPythonIntegration.mm mac/SPDFMacAICapabilitiesSettingsIntegration.mm
	clang++ $(MAC_TARGET_FLAGS) -std=c++17 -fobjc-arc -Wall -Wextra -Werror -Imac -Icore -I$(MUPDF_DIR)/include \
		-I$(MAC_PYTHON_SANDBOX_DIR) -I$(MAC_PYTHON_SANDBOX_DIR)/tests \
		$(MAC_PYTHON_SANDBOX_DIR)/tests/SPDFMacAIPythonTests.mm $(MAC_AI_PYTHON_SRCS) $(MAC_AI_SESSION_SRCS) \
		$(MAC_SETTINGS_WINDOW_SRCS) mac/SPDFMacAISettings.mm mac/SPDFMacToolEnvironment.mm \
		"$(MAC_AI_PYTHON_PROFILE_OBJ)" $(CORE_OBJS) $(MUPDF_LIBS) -framework Cocoa -framework ImageIO \
		-framework UniformTypeIdentifiers -lm -o "$(MAC_AI_PYTHON_TEST)"
	"$(MAC_AI_PYTHON_TEST)" "$(MAC_PYTHON_SANDBOX_BIN)"
