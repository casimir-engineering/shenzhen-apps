# szpdf end to end on the real app, out of sight, with the check that no command brings ShenzhenPDF forward
# (mac/tests/szpdf-e2e/szpdf_e2e.py). Opt-in: it starts a copy of the built app (its own bundle id, HOME, state folder
# and socket, windows far off screen, every activation refused and logged), so it is not part of the default suites.
# Run from portable, after make mac-app: make -f Makefile -f mac/tests/szpdf-e2e/szpdf-e2e.mk mac-szpdf-e2e
SZPDF_E2E_DIR := $(BUILD)/szpdf-e2e
.PHONY: mac-szpdf-e2e
mac-szpdf-e2e: $(MAC_BIN)
	@mkdir -p "$(SZPDF_E2E_DIR)"
	clang $(MAC_TARGET_FLAGS) -dynamiclib -fobjc-arc -Wall -Wextra -Werror mac/tests/szpdf-e2e/offscreen.m \
		-framework AppKit -framework Security -o "$(SZPDF_E2E_DIR)/offscreen.dylib"
	clang $(MAC_TARGET_FLAGS) -fobjc-arc -Wall -Wextra -Werror mac/tests/szpdf-e2e/frontapp.m -framework AppKit \
		-o "$(SZPDF_E2E_DIR)/frontapp"
	python3 -I mac/tests/szpdf-e2e/szpdf_e2e.py "$(MAC_APP)" "$(SZPDF_E2E_DIR)" $(SZPDF_E2E_ROUNDS)
