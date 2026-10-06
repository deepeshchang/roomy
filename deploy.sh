#!/bin/bash
# Build, install and launch on the connected iPhone.
#   ./deploy.sh           build, install, launch
#   ./deploy.sh --test    run tests first, abort if they fail
#   ./deploy.sh --watch   redeploy automatically whenever a source file changes
set -uo pipefail
cd "$(dirname "$0")"

# Your team and device come from Local.env (never committed). See Local.env.example.
[ -f Local.env ] || { echo "✗ Missing Local.env — copy Local.env.example and fill it in"; exit 1; }
set -a; . ./Local.env; set +a
: "${TEAM_ID:?set TEAM_ID in Local.env}" "${DEVICE_ID:?set DEVICE_ID in Local.env}" "${DEVICE_UDID:?set DEVICE_UDID in Local.env}"
DEVICE="$DEVICE_ID"
BUNDLE="com.deepeshchang.VideoCompressor"
APP="build/Build/Products/Debug-iphoneos/VideoCompressor.app"

deploy() {
  if [ "${RUN_TESTS:-0}" = 1 ]; then
    echo "→ tests"
    ./run-tests.sh >/tmp/vc-test.log 2>&1 || {
      echo "✗ tests failed — not deploying. See /tmp/vc-test.log"; return 1; }
    echo "✓ tests passed"
  fi

  echo "→ build"
  xcodegen generate >/dev/null
  xcodebuild build -project VideoCompressor.xcodeproj -scheme VideoCompressor \
    -destination "platform=iOS,id=$DEVICE_UDID" \
    -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" >/tmp/vc-build.log 2>&1 || {
      echo "✗ build failed:"; grep -E "error:" /tmp/vc-build.log | head -5; return 1; }
  echo "✓ built"

  echo "→ install"
  if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >/tmp/vc-install.log 2>&1; then
    echo "✗ install failed:"; grep -iE "error|unlock" /tmp/vc-install.log | head -3; return 1
  fi
  echo "✓ installed"

  # A locked phone refuses launch; the install above already succeeded, so this
  # is not a failure worth aborting on.
  if xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/tmp/vc-launch.log 2>&1; then
    echo "✓ launched"
  else
    if grep -q "unlocked" /tmp/vc-launch.log; then
      echo "• installed, but the phone is locked — unlock it and tap the app"
    else
      echo "• installed, but launch failed:"; grep -iE "error" /tmp/vc-launch.log | head -2
    fi
  fi
}

case "${1:-}" in
  --test)  RUN_TESTS=1 deploy ;;
  --watch)
    echo "watching VideoCompressor/ and Tests/ — ctrl-c to stop"
    deploy
    LAST=$(find VideoCompressor Tests project.yml -type f -newermt "-1 second" 2>/dev/null; date +%s)
    STAMP=/tmp/vc-watch-stamp; touch "$STAMP"
    while true; do
      sleep 2
      if [ -n "$(find VideoCompressor Tests project.yml -type f -newer "$STAMP" 2>/dev/null)" ]; then
        touch "$STAMP"
        echo; echo "--- change detected $(date +%H:%M:%S) ---"
        deploy
      fi
    done ;;
  *) deploy ;;
esac
