#!/bin/sh
# Installs the latest cave CLI release:
#   curl -fsSL https://raw.githubusercontent.com/namzug16/cave/master/install.sh | sh
# Set CAVE_INSTALL_DIR to install somewhere other than ~/.local/bin. CaveKit.swift and SKILL.md go
# to share/cave next to that directory, where cave looks for them.
set -eu

# Everything runs from main so a download cut off midway executes nothing.
main() {
    if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
        echo "error: cave supports Apple silicon Macs only" >&2
        exit 1
    fi

    install_directory="${CAVE_INSTALL_DIR:-$HOME/.local/bin}"
    share_directory="$(dirname "$install_directory")/share/cave"
    download_directory="$(mktemp -d)"
    trap 'rm -rf "$download_directory"' EXIT

    curl -fsSL -o "$download_directory/cave.tar.gz" \
        https://github.com/namzug16/cave/releases/latest/download/cave-macos-arm64.tar.gz
    tar -xzf "$download_directory/cave.tar.gz" -C "$download_directory"
    mkdir -p "$install_directory" "$share_directory"
    install -m 755 "$download_directory/bin/cave" "$install_directory/cave"
    install -m 644 "$download_directory/share/cave/CaveKit.swift" "$download_directory/share/cave/SKILL.md" "$share_directory/"

    echo "installed cave $("$install_directory/cave" version) to $install_directory/cave"
    case ":$PATH:" in
        *":$install_directory:"*) ;;
        *) echo "add $install_directory to your PATH to run cave" ;;
    esac
}

main
