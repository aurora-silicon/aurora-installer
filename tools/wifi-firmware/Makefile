# aurora-wifi-firmware: make install DESTDIR=... PREFIX=/usr
# Installs the tool with the repository's own radio converters (asahi_firmware
# core, cpio, wifi, bluetooth, mt7932, centauri) and restore image reader (ipsw, aea_ro,
# apfs_ro, remotezip, udif_ro, restore-images.json), so a distribution needs no
# other copy of them. Needs python3-cryptography and liblzfse at run time.
PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib/aurora-wifi-firmware
UNITDIR ?= $(PREFIX)/lib/systemd/system
PYTHON ?= /usr/bin/python3
REPO := ../..

install:
	install -Dm0644 aurora_wifi_firmware.py $(DESTDIR)$(LIBDIR)/aurora_wifi_firmware.py
	for f in __init__ core cpio wifi bluetooth mt7932 centauri ipsw aea_ro apfs_ro remotezip udif_ro; do \
		install -Dm0644 $(REPO)/asahi_firmware/$$f.py $(DESTDIR)$(LIBDIR)/asahi_firmware/$$f.py; done
	install -Dm0644 $(REPO)/asahi_firmware/restore-images.json $(DESTDIR)$(LIBDIR)/asahi_firmware/restore-images.json
	install -d $(DESTDIR)$(PREFIX)/bin
	printf '#!/bin/sh\nexec %s -I %s/aurora_wifi_firmware.py "$$@"\n' '$(PYTHON)' '$(LIBDIR)' \
		> $(DESTDIR)$(PREFIX)/bin/aurora-wifi-firmware
	chmod 0755 $(DESTDIR)$(PREFIX)/bin/aurora-wifi-firmware
	install -Dm0644 aurora-wifi-firmware.service $(DESTDIR)$(UNITDIR)/aurora-wifi-firmware.service
	sed -i 's#/usr/bin/aurora-wifi-firmware#$(PREFIX)/bin/aurora-wifi-firmware#' \
		$(DESTDIR)$(UNITDIR)/aurora-wifi-firmware.service

check:
	cd $(REPO) && $(PYTHON) -I -m unittest discover -s tests -p 'test_wifi_firmware_*.py' -v

.PHONY: install check
