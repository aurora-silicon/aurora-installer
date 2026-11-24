# aurora-restore: make install DESTDIR=... PREFIX=/usr
PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib/aurora-restore
PYTHON ?= /usr/bin/python3
REPO := ../..

install:
	install -Dm0644 aurora_restore.py $(DESTDIR)$(LIBDIR)/aurora_restore.py
	install -Dm0644 apple_remote.py $(DESTDIR)$(LIBDIR)/apple_remote.py
	install -Dm0644 $(REPO)/tools/whole-disk/aurora_whole_disk.py $(DESTDIR)$(LIBDIR)/aurora_whole_disk.py
	install -Dm0644 $(REPO)/tools/wifi-firmware/apfs_ro.py $(DESTDIR)$(LIBDIR)/apfs_ro.py
	install -d $(DESTDIR)$(PREFIX)/bin
	printf '#!/bin/sh\nexec %s -I %s/aurora_restore.py "$$@"\n' '$(PYTHON)' '$(LIBDIR)' \
		> $(DESTDIR)$(PREFIX)/bin/aurora-restore
	chmod 0755 $(DESTDIR)$(PREFIX)/bin/aurora-restore

check:
	cd $(REPO) && $(PYTHON) -I -m unittest discover -s tests -p 'test_restore.py' -v

# Root only: loop devices, mkfs, mount; reads Apple's catalog. A 110 GiB
# sparse image in DIR, removed afterwards.
image-test:
	./image-test.sh $(DIR) $(LOGS) $(VERSION)

.PHONY: install check image-test
