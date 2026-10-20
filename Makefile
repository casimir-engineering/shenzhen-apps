# Common tasks for the whole repository. Every app also builds from its own directory as before; these targets only
# call those commands. `make help` lists them.

PDF := apps/pdf/portable
FILES := apps/files
THREED := apps/3d
COTURN ?=

.PHONY: help pdf pdf-tests friends friends-tests friends-one-identity-e2e friends-number friends-server-tests \
	files-setup files files-tests 3d-setup 3d-tests 3d-friends-tests

help:
	@echo "ShenzhenPDF"
	@echo "  make pdf                  dist/ShenzhenPDF.app (apps/pdf/dist)"
	@echo "  make pdf-tests            the release test sweep ShenzhenPDF's release script runs"
	@echo "Shenzhen Friends"
	@echo "  make friends              the helper, as every app embeds it"
	@echo "  make friends-tests        the Friends suite and friends-one-identity-e2e (COTURN=<turnserver> for the relay)"
	@echo "  make friends-one-identity-e2e  one identity per computer: the three apps' real Friends views on one helper,"
	@echo "                           and two computers of one profile kept the same (needs make 3d-setup once)"
	@echo "  make friends-number       is the helper build number raised since Friends last changed?"
	@echo "  make friends-server-tests the host's tests"
	@echo "Shenzhen Files"
	@echo "  make files-setup          Friends from apps/pdf, then upstream Nautilus with patches/, built"
	@echo "  make files                apps/files/dist/Shenzhen Files.app"
	@echo "  make files-tests          the Friends setup and the Friends host adapter tests"
	@echo "Shenzhen 3D"
	@echo "  make 3d-setup             npm ci and Friends from apps/pdf"
	@echo "  make 3d-tests             unit and Electron tests"
	@echo "  make 3d-friends-tests     the Friends tests, in the real Electron shell"

pdf:
	$(MAKE) -C $(PDF) mac-app

pdf-tests:
	$(MAKE) -C $(PDF) test-binaries
	$(MAKE) -C $(PDF) $$(bash -c '. $(PDF)/release/release-common.sh && spdf_discover_test_targets $(PDF)/Makefile')

friends:
	$(MAKE) -C $(PDF) friends-helper-bundle

friends-tests:
	$(MAKE) -C $(PDF) friends-suite $(if $(COTURN),FRIENDS_TEST_COTURN=$(COTURN))
	$(MAKE) friends-one-identity-e2e

# ShenzhenPDF's AppKit views, Shenzhen Files' GTK views and Shenzhen 3D's packaged Electron shell on one Friends home,
# hidden, and two computers of one profile (apps/pdf/portable/friends/tests/e2e/oneid.mk). Shenzhen 3D's client addon
# and renderer are built from this tree first; its node_modules come from make 3d-setup.
friends-one-identity-e2e:
	@test -d $(THREED)/node_modules || { echo "friends-one-identity-e2e: run make 3d-setup first" >&2; exit 1; }
	cd $(THREED) && scripts/friends/setup-friends.sh && npm run build
	$(MAKE) -C $(PDF) friends-one-identity-check FRIENDS_ONEID_3D=$(CURDIR)/$(THREED) \
		$(if $(COTURN),FRIENDS_TEST_COTURN=$(COTURN))

friends-number:
	tools/check-friends-number.sh

friends-server-tests:
	cd $(PDF)/server/friends && npm ci && npm test

files-setup:
	$(FILES)/tools/setup-friends.sh
	$(FILES)/tools/setup-nautilus-tree.sh

files:
	$(FILES)/package/make-app.sh
	$(FILES)/package/bundle-dylibs.sh

files-tests:
	$(FILES)/tools/test-setup-friends.sh
	$(FILES)/tools/test-friends-adapter.sh

3d-setup:
	cd $(THREED) && npm ci && scripts/friends/setup-friends.sh

3d-tests:
	cd $(THREED) && npm test && npm run build && npm run test:electron

3d-friends-tests:
	cd $(THREED) && npm run build && npm run test:friends
