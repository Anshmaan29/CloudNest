#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../mac"
action="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
flags=()
developer_dir="$(xcode-select -p)"
frameworks="$developer_dir/Library/Developer/Frameworks"
# Command Line Tools 6.4 needs explicit Testing search/plugin paths with the
# native SwiftPM builder. Full Xcode toolchains configure these themselves.
if [[ "$developer_dir" == *CommandLineTools ]] && [ -d "$frameworks/Testing.framework" ]; then
  flags+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
  plugin="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  if [ -f "$plugin" ]; then flags+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
  exec swift "$action" --build-system native "${flags[@]}" "$@"
fi
exec swift "$action" --build-system native "$@"
