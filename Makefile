# TODOSH — development and installation tasks.
# User-local install by default; no root needed:  make install

PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
LIBDIR  ?= $(PREFIX)/lib/todosh

BATS       ?= bats
SHELLCHECK ?= shellcheck
SHFMT      ?= shfmt
SHFMT_OPTS := -i 2 -ci -bn

SOURCES := bin/todosh $(wildcard lib/*.sh)
TESTS   := $(wildcard tests/*.bats)

.PHONY: help test lint fmt fmt-check check install uninstall

help:
	@printf '%s\n' \
	  'make test        Run the test suite (bats)' \
	  'make lint        Static analysis (shellcheck)' \
	  'make fmt         Format sources (shfmt)' \
	  'make check       lint + fmt-check + test' \
	  'make install     Install to $(PREFIX) (override with PREFIX=...)' \
	  'make uninstall   Remove installed files (never touches task data)'

test:
	$(BATS) tests/

lint:
	$(SHELLCHECK) -x $(SOURCES) tests/test_helper.bash
	$(SHELLCHECK) -x -s bash $(TESTS)

fmt:
	$(SHFMT) $(SHFMT_OPTS) -w $(SOURCES) tests/test_helper.bash

fmt-check:
	$(SHFMT) $(SHFMT_OPTS) -d $(SOURCES) tests/test_helper.bash

check: lint fmt-check test

install:
	install -d -m 0755 "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(LIBDIR)"
	install -m 0755 bin/todosh "$(DESTDIR)$(BINDIR)/todosh"
	install -m 0644 lib/*.sh "$(DESTDIR)$(LIBDIR)/"
	ln -sfn todosh "$(DESTDIR)$(BINDIR)/tdsh"
	@printf 'Installed todosh (and tdsh) to %s\n' "$(DESTDIR)$(BINDIR)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/todosh"
	@if [ -L "$(DESTDIR)$(BINDIR)/tdsh" ]; then rm -f "$(DESTDIR)$(BINDIR)/tdsh"; fi
	rm -f $(patsubst lib/%,"$(DESTDIR)$(LIBDIR)/%",$(wildcard lib/*.sh))
	-rmdir "$(DESTDIR)$(LIBDIR)" 2>/dev/null
	@printf 'Removed program files. Your tasks and config were not touched:\n'
	@printf '  %s\n  %s\n' "$${XDG_DATA_HOME:-$$HOME/.local/share}/todosh" "$${XDG_CONFIG_HOME:-$$HOME/.config}/todosh"
