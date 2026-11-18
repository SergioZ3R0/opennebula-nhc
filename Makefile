# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0

PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib/one-nhc
BINDIR ?= $(PREFIX)/bin
CONFDIR ?= /etc/one-nhc
ON_REMOTES ?= /var/lib/one/remotes/im/kvm-probes.d/host/system
SYSTEMD ?= /etc/systemd/system
DISTDIR ?= dist
VERSION := $(shell ruby -Ilib -e 'require "one_nhc/version"; print OneNHC::VERSION')

.PHONY: test dist install probe install-probe install-systemd install-cache-systemd uninstall

test:
	ruby -Ilib -Itests tests/run.rb

# Release artifact. Requires a clean, committed tree and git.
dist:
	rm -rf $(DISTDIR)
	mkdir -p $(DISTDIR)
	git archive --format=tar.gz --prefix=opennebula-nhc-$(VERSION)/ \
		-o $(DISTDIR)/opennebula-nhc-$(VERSION).tar.gz HEAD
	cd $(DISTDIR) && sha256sum opennebula-nhc-$(VERSION).tar.gz \
		> opennebula-nhc-$(VERSION).tar.gz.sha256
	@echo "Built $(DISTDIR)/opennebula-nhc-$(VERSION).tar.gz"

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
	install -m 0755 probes/kvm-probes.d/host/system/one_nhc.rb \
		$(DESTDIR)$(ON_REMOTES)/one_nhc.rb

# Frontend only: timer that runs the controller every 2 minutes.
install-systemd:
	install -d $(DESTDIR)$(SYSTEMD)
	install -m 0644 systemd/one-nhc-controller.service $(DESTDIR)$(SYSTEMD)/
	install -m 0644 systemd/one-nhc-controller.timer $(DESTDIR)$(SYSTEMD)/
	@echo "Run: systemctl daemon-reload && systemctl enable --now one-nhc-controller.timer"

# Hypervisors: timer that refreshes the heavy-check cache (smart, gpu-fabric).
install-cache-systemd:
	install -d $(DESTDIR)$(SYSTEMD)
	install -m 0644 systemd/one-nhc-cache.service $(DESTDIR)$(SYSTEMD)/
	install -m 0644 systemd/one-nhc-cache.timer $(DESTDIR)$(SYSTEMD)/
	@echo "Run: systemctl daemon-reload && systemctl enable --now one-nhc-cache.timer"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/one-nhc
	rm -rf $(DESTDIR)$(LIBDIR)
	rm -f $(DESTDIR)$(SYSTEMD)/one-nhc-controller.service
	rm -f $(DESTDIR)$(SYSTEMD)/one-nhc-controller.timer
	rm -f $(DESTDIR)$(SYSTEMD)/one-nhc-cache.service
	rm -f $(DESTDIR)$(SYSTEMD)/one-nhc-cache.timer
