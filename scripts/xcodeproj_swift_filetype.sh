#!/bin/bash
# qmake's Xcode generator has no notion of Swift: a .swift file only lands in "Compile Sources"
# when its extension is registered as a C++ source (QMAKE_EXT_CPP in DroidStar.pro), and then
# the file reference is typed "sourcecode.cpp.cpp", so clang tries to compile it. This retypes
# every .swift file reference as "sourcecode.swift" so Xcode uses swiftc.
#
# Runs automatically from qt_preprocess.mak (extra compiler "swift_filetype" in DroidStar.pro).
# Idempotent: the project file is only rewritten when something changes.
#
# Usage: xcodeproj_swift_filetype.sh <path/to/DroidStar.xcodeproj>

set -euo pipefail

PBX="${1:?usage: $0 <project.xcodeproj>}/project.pbxproj"
[ -f "$PBX" ] || { echo "error: $PBX not found" >&2; exit 1; }

TMP="$(mktemp -t swift-filetype)"
perl -0pe 's/(path = "[^"]*\.swift";[^}]*?lastKnownFileType = )"sourcecode\.cpp\.cpp"/$1"sourcecode.swift"/g' "$PBX" > "$TMP"

if cmp -s "$PBX" "$TMP"; then
    rm -f "$TMP"
else
    cat "$TMP" > "$PBX"
    rm -f "$TMP"
    echo "[LiveActivity] retyped .swift files as sourcecode.swift in $PBX"
fi
