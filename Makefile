# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0

PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib/one-nhc
BINDIR ?= $(PREFIX)/bin
CONFDIR ?= /etc/one-nhc
ON_REMOTES ?= /var/lib/one/remotes/im/kvm-probes.d/host

.PHONY: test install probe install-probe uninstall

test:
	ruby -Ilib -Itests tests/run.rb

install:
	install -d $(DESTDIR)$(LIBDIR)
	cp -R lib checks.d $(DESTDIR)$(LIBDIR)/
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 bin/one-nhc $(DESTDIR)$(BINDIR)/one-nhc
	install -d $(DESTDIR)$(CONFDIR)
	test -f $(DESTDIR)$(CONFDIR)/one-nhc.conf || \
		install -m 0644 etc/one-nhc.conf $(DESTDIR)$(CONFDIR)/one-nhc.conf

probe: install
	install -d $(DESTDIR)$(ON_REMOTES)
	install -m 0755 probes/kvm-probes.d/host/one_nhc.rb \
		$(DESTDIR)$(ON_REMOTES)/one_nhc.rb

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/one-nhc
	rm -rf $(DESTDIR)$(LIBDIR)
