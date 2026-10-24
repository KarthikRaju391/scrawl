#!/bin/sh
# Builds the Phase 1 probe with the Command Line Tools toolchain (no Xcode needed).
set -e
cd "$(dirname "$0")"
swiftc -O -o probe-bin main.swift -framework AppKit
