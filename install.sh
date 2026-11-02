#!/bin/bash
# Builds AirGap from this checkout, installs it into /Applications and opens it.
# Run it again after `git pull` to update.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "AirGap needs Apple's Command Line Tools to build. Installing them opens a dialog;"
  echo "run ./install.sh again once they're done."
  xcode-select --install || true
  exit 1
fi

echo "Building AirGap (the first build takes a minute)…"
scripts/build-app.sh

DEST=/Applications/AirGap.app
if [ -d "$DEST" ]; then
  # A rebuild gets a new ad-hoc signature, so macOS keeps the old browser permission but stops honouring it.
  # Clearing it lets AirGap ask again for each browser on first use.
  pkill -x AirGap 2>/dev/null || true
  tccutil reset AppleEvents com.arberiii.airgap >/dev/null 2>&1 || true
  rm -rf "$DEST"
fi

cp -R build/AirGap.app "$DEST"
open "$DEST"
echo "Installed $DEST. AirGap is in your menu bar."
