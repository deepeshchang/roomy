#!/bin/bash
# Runs the suite on the simulator. Takes a machine-wide lock first: two test
# runs on one simulator corrupt each other, which happened repeatedly when
# several engineers ran tests at once.
set -uo pipefail
cd "$(dirname "$0")"
LOCK=/tmp/roomy-tests.lock
until mkdir "$LOCK" 2>/dev/null; do echo "waiting for another test run…"; sleep 5; done
trap 'rmdir "$LOCK"' EXIT
xcodegen generate
xcodebuild test \
  -project VideoCompressor.xcodeproj \
  -scheme VideoCompressor \
  -destination 'platform=iOS Simulator,name=Doctaz-iPhone17' \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180
