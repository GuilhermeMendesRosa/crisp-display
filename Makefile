PREFIX     ?= $(HOME)/.local
BIN        := $(PREFIX)/bin/crisp-display
LABEL      := com.github.crisp-display
PLIST      := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG        := $(HOME)/Library/Logs/crisp-display.log
DOMAIN     := gui/$(shell id -u)

# Monitor que ganha HiDPI (veja `make list`) e tamanho da interface nele.
# DISPLAY_ID vazio deixa só a trava da Dock.
DISPLAY_ID ?=
LOOKS_LIKE ?= 1344x756
DOCK_GUARD ?= 1

SOURCES := $(wildcard Sources/*.swift)
HEADER  := Sources/CGVirtualDisplay.h

ARGS := run
ifneq ($(DISPLAY_ID),)
ARGS += --display $(DISPLAY_ID) --looks-like $(LOOKS_LIKE)
endif
ifeq ($(DOCK_GUARD),0)
ARGS += --no-dock-guard
endif

.PHONY: build list install uninstall restart logs clean

build: build/crisp-display

build/crisp-display: $(SOURCES) $(HEADER)
	@mkdir -p build
	swiftc -O -import-objc-header $(HEADER) $(SOURCES) -o $@

list: build
	@build/crisp-display list

install: build
	@mkdir -p $(dir $(BIN)) $(dir $(PLIST))
	install -m 755 build/crisp-display $(BIN)
	@printf '%s\n' $(ARGS) | sed 's|.*|    <string>&</string>|' > build/args.xml
	@sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BIN@|$(BIN)|' -e 's|@LOG@|$(LOG)|' \
		-e '/@ARGS@/{r build/args.xml' -e 'd;}' launchd/agent.plist.in > $(PLIST)
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@echo "instalado: $(BIN) $(ARGS)"

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL)
	rm -f $(PLIST) $(BIN)

restart:
	launchctl kickstart -k $(DOMAIN)/$(LABEL)

logs:
	@tail -n 50 -f $(LOG)

clean:
	rm -rf build
