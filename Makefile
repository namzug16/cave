PREFIX ?= $(HOME)/.local
BIN_DIR := $(PREFIX)/bin
SHARE_DIR := $(PREFIX)/share/cave

.PHONY: build install uninstall test bench release-artifacts

build:
	swift build -c release --product cave

# Installs the cave binary, plus CaveKit.swift and SKILL.md for setting up other apps.
install: build
	install -d "$(BIN_DIR)" "$(SHARE_DIR)"
	install -m 755 .build/release/cave "$(BIN_DIR)/cave"
	install -m 644 Templates/CaveKit.swift Templates/SKILL.md "$(SHARE_DIR)/"
	@echo "installed $(BIN_DIR)/cave"
	@case ":$$PATH:" in *":$(BIN_DIR):"*) ;; *) echo "warning: $(BIN_DIR) is not on your PATH";; esac

uninstall:
	rm -f "$(BIN_DIR)/cave"
	rm -rf "$(SHARE_DIR)"

# The archive the GitHub release, Homebrew and install.sh ship: bin/ and share/ as install lays them out.
release-artifacts: build
	rm -rf .build/dist
	install -d .build/dist/cave/bin .build/dist/cave/share/cave .build/dist/cave/LICENSES
	install -m 755 .build/release/cave .build/dist/cave/bin/cave
	install -m 644 Templates/CaveKit.swift Templates/SKILL.md .build/dist/cave/share/cave/
	install -m 644 LICENSE NOTICE .build/dist/cave/
	install -m 644 LICENSES/Apache-2.0.txt .build/dist/cave/LICENSES/
	tar -czf .build/dist/cave-macos-arm64.tar.gz -C .build/dist/cave .

test:
	swift test

bench:
	python3 bench/edit_to_png.py
