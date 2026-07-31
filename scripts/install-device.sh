#!/usr/bin/env bash
# Builds and installs on the iPhone, seeding development keys so a reinstall
# never means typing them again.
#
# Keys live outside the repository in ~/.halo-dev-keys.env, which this script
# sources. That file is yours: it is never printed or committed here.
#   HALO_DOUBAO_SPEECH=<access token>
#   HALO_DOUBAO_REALTIME=<appId:appKey:accessToken>
#   HALO_VIDU=<vda_...>
set -euo pipefail

DEVICE="${HALO_DEVICE:-00008110-0002504C3663801E}"
KEYS="${HALO_DEV_KEYS:-}"
if [[ -z "$KEYS" ]]; then
  # An editor that insists on an extension should not cost an evening.
  for candidate in "$HOME/.halo-dev-keys.env" "$HOME/.halo-dev-keys.env.md"; do
    [[ -f "$candidate" ]] && KEYS="$candidate" && break
  done
  KEYS="${KEYS:-$HOME/.halo-dev-keys.env}"
fi
cd "$(dirname "$0")/../apps/mobile"

defines=()
if [[ -f "$KEYS" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$KEYS"; set +a
  for name in HALO_DOUBAO_SPEECH HALO_DOUBAO_REALTIME HALO_VIDU; do
    value="${!name:-}"
    [[ -n "$value" ]] && defines+=("--dart-define=$name=$value")
  done
  echo "seeding ${#defines[@]} development key(s) from $KEYS"
else
  echo "no $KEYS found; building without seeded keys"
fi

flutter build ios --release --no-tree-shake-icons "${defines[@]}"
xcrun devicectl device install app --device "$DEVICE" build/ios/iphoneos/Runner.app
