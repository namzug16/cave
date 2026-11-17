#!/bin/sh
# Prints the Homebrew formula for a released version.
# Usage: homebrew-formula.sh VERSION SHA256_OF_CLI_ARCHIVE
set -eu

version="$1"
archive_sha256="$2"

cat <<FORMULA
class Cave < Formula
  desc "Agent-first CLI that renders native macOS SwiftUI screens to PNG"
  homepage "https://github.com/namzug16/cave"
  url "https://github.com/namzug16/cave/releases/download/v${version}/cave-macos-arm64.tar.gz"
  version "${version}"
  sha256 "${archive_sha256}"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    bin.install "bin/cave"
    (share/"cave").install "share/cave/CaveKit.swift", "share/cave/SKILL.md"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/cave version").strip
  end
end
FORMULA
