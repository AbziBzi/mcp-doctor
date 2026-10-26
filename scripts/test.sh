#!/bin/zsh
# Runs the tests. With only the Command Line Tools installed, SwiftPM doesn't find the
# Swift Testing macro plugin or runtime on its own, so point it at them.
set -euo pipefail
cd "${0:A:h}/.."

clt=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p)" == "$clt" ]]; then
  swift test \
    -Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing" \
    -Xlinker -rpath -Xlinker "$clt/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$clt/Library/Developer/usr/lib" "$@"
else
  swift test "$@"
fi
