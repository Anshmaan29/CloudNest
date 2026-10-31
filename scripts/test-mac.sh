#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
deadline_test='googleTransportDeniesRedirectsAndEnforcesActualResourceDeadlineOnLoopback'

# Run the real-loopback wall-clock assertion alone so unrelated parallel file,
# database and compression tests cannot starve its executor. Keep its 0.1-second
# resource timeout and strict 2-second wall guard unchanged.
bash "$script_dir/swift.sh" test --skip "$deadline_test" "$@"
bash "$script_dir/swift.sh" test --skip-build --filter "$deadline_test" "$@"
