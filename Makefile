# SPDX-FileCopyrightText: 2026 SergioZ3R0
# SPDX-License-Identifier: Apache-2.0

PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib/one-nhc
BINDIR ?= $(PREFIX)/bin
CONFDIR ?= /etc/one-nhc
ON_REMOTES ?= /var/lib/one/remotes/im/kvm-probes.d/host/system
SYSTEMD ?= /etc/systemd/system

.PHONY: test install probe install-probe install-systemd uninstall \
	lab-systemd-up lab-systemd-status lab-systemd-logs lab-systemd-down

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
	install -m 0755 probes/kvm-probes.d/host/system/one_nhc.rb \
		$(DESTDIR)$(ON_REMOTES)/one_nhc.rb

# Frontend only: timer that runs the controller every 2 minutes.
install-systemd:
	install -d $(DESTDIR)$(SYSTEMD)
	install -m 0644 systemd/one-nhc-controller.service $(DESTDIR)$(SYSTEMD)/
	install -m 0644 systemd/one-nhc-controller.timer $(DESTDIR)$(SYSTEMD)/
	@echo "Run: systemctl daemon-reload && systemctl enable --now one-nhc-controller.timer"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/one-nhc
	rm -rf $(DESTDIR)$(LIBDIR)
	rm -f $(DESTDIR)$(SYSTEMD)/one-nhc-controller.service
	rm -f $(DESTDIR)$(SYSTEMD)/one-nhc-controller.timer

# Optional: test the real systemd units against an opennebula-lab frontend.
lab-systemd-up:
	./scripts/lab-systemd.sh up

lab-systemd-status:
	./scripts/lab-systemd.sh status

lab-systemd-logs:
	./scripts/lab-systemd.sh logs

lab-systemd-down:
	./scripts/lab-systemd.sh down
