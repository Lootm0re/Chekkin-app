#!/usr/bin/env bash
# One command for the local test setup: builds the emulator web app, starts
# the Auth, Firestore and Functions emulators under a demo- project, seeds
# them (scripts/emulator-seed.js) and serves the app on port 5050
# (scripts/emulator-proxy.js). Ctrl+C stops everything and throws the data
# away. Nothing here touches the real project.
#
#   npm run emulators               (from functions/)
#   npm run emulators -- --no-build (reuse the last emulator build)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT=demo-chekkin-dev # keep in sync with emulatorProjectId in checkin_app/lib/emulators.dart
# Its own folder, so it can't be deployed to Hosting by mistake (which
# serves checkin_app/build/web).
OUT="$REPO/checkin_app/build/web-emulators"

FLUTTER="$REPO/flutter/bin/flutter"
[[ -x "$FLUTTER" ]] || FLUTTER=flutter

if [[ "${1:-}" != "--no-build" ]]; then
  echo "Building the emulator web app..."
  (cd "$REPO/checkin_app" && "$FLUTTER" build web --release \
    --dart-define=USE_EMULATORS=true --dart-define=DEV_TOOLS=true --output "$OUT")
fi

cd "$REPO"
firebase emulators:exec --project "$PROJECT" --only auth,firestore,functions \
  "node functions/scripts/emulator-seed.js && node functions/scripts/emulator-proxy.js '$OUT'"
