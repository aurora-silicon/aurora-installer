# aurora-whole-disk: make install DESTDIR=... PREFIX=/usr
PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib/aurora-whole-disk
UNITDIR ?= $(PREFIX)/lib/systemd/system
PYTHON ?= /usr/bin/python3
REPO := ../..

install:
	install -Dm0644 aurora_whole_disk.py $(DESTDIR)$(LIBDIR)/aurora_whole_disk.py
	install -Dm0644 $(REPO)/tools/wifi-firmware/apfs_ro.py $(DESTDIR)$(LIBDIR)/apfs_ro.py
	install -d $(DESTDIR)$(PREFIX)/bin
	printf '#!/bin/sh\nexec %s -I %s/aurora_whole_disk.py "$$@"\n' '$(PYTHON)' '$(LIBDIR)' \
		> $(DESTDIR)$(PREFIX)/bin/aurora-whole-disk
	chmod 0755 $(DESTDIR)$(PREFIX)/bin/aurora-whole-disk
	install -Dm0644 aurora-whole-disk-claim.service $(DESTDIR)$(UNITDIR)/aurora-whole-disk-claim.service
	sed -i 's#/usr/bin/aurora-whole-disk#$(PREFIX)/bin/aurora-whole-disk#' \
		$(DESTDIR)$(UNITDIR)/aurora-whole-disk-claim.service

check:
	cd $(REPO) && $(PYTHON) -I -m unittest discover -s tests -p 'test_whole_disk.py' -v

# Root only: loop devices, mkfs, mount. Writes a 15 GB sparse image to DIR.
image-test:
	./image-test.sh $(DIR)

.PHONY: install check image-test
