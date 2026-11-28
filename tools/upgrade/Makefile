# aurora-upgrade: make install DESTDIR=... PREFIX=/usr
# Installs the command with the installer's own policy (extracted from
# NativeInspectionPolicySource.swift, the one source) and the pinned-image
# qualification list. Needs apfuse and apfuse-mount (apfs-linux-rs) at run time.
PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib/aurora-upgrade
SHAREDIR ?= $(PREFIX)/share/aurora-upgrade
PYTHON ?= /usr/bin/python3
REPO := ../..

install:
	install -Dm0644 aurora_upgrade.py $(DESTDIR)$(LIBDIR)/aurora_upgrade.py
	for f in __init__ remotezip; do \
		install -Dm0644 $(REPO)/asahi_firmware/$$f.py $(DESTDIR)$(LIBDIR)/asahi_firmware/$$f.py; done
	install -d $(DESTDIR)$(SHAREDIR)
	$(PYTHON) -I -c 'import json,sys; sys.path.insert(0, "."); import aurora_upgrade as a; \
		json.dump(a.load_policy(sys.argv[1]), open(sys.argv[2], "w"), indent=1, sort_keys=True)' \
		$(REPO)/macOS/Sources/AuroraAppleInstaller/NativeInspectionPolicySource.swift \
		$(DESTDIR)$(SHAREDIR)/native-policy.json
	install -Dm0644 $(REPO)/macOS/scripts/firmware-qualification.json $(DESTDIR)$(SHAREDIR)/firmware-qualification.json
	install -d $(DESTDIR)$(PREFIX)/bin
	printf '#!/bin/sh\nexec %s -I %s/aurora_upgrade.py "$$@"\n' '$(PYTHON)' '$(LIBDIR)' \
		> $(DESTDIR)$(PREFIX)/bin/aurora-upgrade
	chmod 0755 $(DESTDIR)$(PREFIX)/bin/aurora-upgrade

check:
	cd $(REPO) && $(PYTHON) -I -m unittest discover -s tests -p 'test_aurora_upgrade.py' -v

.PHONY: install check
