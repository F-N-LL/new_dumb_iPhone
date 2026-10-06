#!/usr/bin/env bash
# Turns a plugged-in iPhone (iOS 9.3+) into a dumb phone.
#   ./install.sh          install / update
#   ./install.sh --undo   remove the dumb profile (phone goes back to normal)
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
wait_enter() { read -r -p "  $* then press Enter. "; }

# --- 1. host tools ---------------------------------------------------------
if ! command -v usbmuxd >/dev/null; then
  say "Installing usbmuxd (asks for sudo)"
  if command -v dnf >/dev/null; then sudo dnf install -y usbmuxd
  elif command -v apt-get >/dev/null; then sudo apt-get install -y usbmuxd
  elif command -v pacman >/dev/null; then sudo pacman -S --noconfirm usbmuxd
  else die "Install usbmuxd with your package manager and run again."; fi
fi
if ! command -v uv >/dev/null && [ ! -x "$HOME/.local/bin/uv" ]; then
  say "Installing uv (Python runner)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
pmd() { uv tool run -q --python 3.12 pymobiledevice3@11.23.0 "$@"; }

# --- 2. find the phone -----------------------------------------------------
say "Plug the iPhone in with USB and unlock it."
[ -S /var/run/usbmuxd ] || sudo systemctl start usbmuxd
until pmd usbmux list 2>/dev/null | grep >/dev/null Identifier; do sleep 2; done

pair() {
  until pmd lockdown pair >/dev/null 2>&1; do
    echo "  Tap 'Trust' on the iPhone if it asks..."; sleep 3
  done
}
pair

if [ "${1:-}" = "--undo" ]; then
  pmd profile remove local.dumbiphone.profile
  say "Done. The phone is back to normal."; exit 0
fi

ver=$(pmd lockdown get --key ProductVersion | tr -dc '0-9.')
model=$(pmd lockdown get --key ProductType | tr -dc 'A-Za-z0-9,')
echo "  Found $model on iOS $ver"
python3 -c "import sys; v=tuple(map(int,'$ver'.split('.')));sys.exit(v<(9,3))" \
  || die "Needs iOS 9.3 or newer (hiding apps came in 9.3). On the phone: Settings > General > Software Update, then run again."

# --- 3. supervise (one time, erases the phone) ----------------------------
mkdir -p keys build
[ -f keys/supervisor.pem ] || pmd profile create-keybag keys/supervisor.pem "dumb iPhone"
chmod 600 keys/supervisor.pem   # supervisor private key: whoever has it can manage the phone

if ! pmd profile cloud-configuration 2>/dev/null | grep >/dev/null '"IsSupervised": true'; then
  # Only a phone still on its setup screens can be supervised; a set-up one must be erased first.
  if pmd lockdown get --domain com.apple.purplebuddy 2>/dev/null | grep >/dev/null '"SetupDone": true'; then
    say "One-time step: the phone must be ERASED so it can be locked down."
    echo "  Photos and voice memos get copied to backup/ first. Contacts/messages: use iCloud."
    read -r -p "  Type ERASE to wipe this iPhone: " ok
    [ "$ok" = "ERASE" ] || die "Stopped. Nothing changed."

    b="backup/$(date +%F)"; mkdir -p "$b"
    echo "  Copying photos and voice memos to $b ..."
    pmd afc pull /DCIM "$b" >/dev/null 2>&1 || true
    pmd afc pull /Recordings "$b" >/dev/null 2>&1 || true

    if ! pmd profile erase-device >/dev/null 2>&1; then   # not supported on older iOS
      say "On the phone: Settings > General > Reset > Erase All Content and Settings."
      echo "  Leave the cable in. This script continues by itself when the phone restarts."
    fi
    echo "  Erasing. This takes a few minutes..."
    while pmd usbmux list 2>/dev/null | grep >/dev/null Identifier; do sleep 3; done   # gone
    until pmd usbmux list 2>/dev/null | grep >/dev/null Identifier; do sleep 3; done   # back
    sleep 10; pair
  fi

  # The phone only accepts supervision once it is activated, so let it activate itself over Wi-Fi.
  if ! pmd activation state 2>/dev/null | grep -x >/dev/null 'Activated'; then
    say "On the phone: tap through Language and Country, join Wi-Fi."
    echo "  Stop at the screen right after Wi-Fi (no SIM is fine). Waiting for activation..."
    until pmd activation state 2>/dev/null | grep -x >/dev/null 'Activated'; do sleep 5; done
    sleep 5; pair
  fi

  python3 build_profile.py cloud build/cloud.plist keys/supervisor.pem >/dev/null
  pmd profile cloud-configuration --config build/cloud.plist || die "Could not supervise. The phone must still be on its setup screens."
  say "Supervised. Now finish setup on the phone: Wi-Fi, Apple ID (for iMessage), Location on."
  wait_enter "When you see the home screen,"
  pair
fi

# --- 4. the dumb profile --------------------------------------------------
python3 build_profile.py profile build/dumb.mobileconfig >/dev/null
python3 build_profile.py certs build/certs.mobileconfig >/dev/null
pmd profile install --keybag keys/supervisor.pem build/certs.mobileconfig >/dev/null 2>&1 || true
say "Installing the dumb profile"
pmd profile remove local.dumbiphone.profile >/dev/null 2>&1 || true
if ! pmd profile install --keybag keys/supervisor.pem build/dumb.mobileconfig 2>/dev/null; then
  pmd profile install build/dumb.mobileconfig
  wait_enter "On the phone tap Install (top right) and confirm,"
fi

say "Done."
cat <<'EOF'
  Home screen: the Light Phone set (calls, messages, camera, maps, music,
  podcasts, photos, alarm, calendar, notes, voice memo, calculator, web)
  Optional, on the phone: Settings > General > Accessibility >
    Display Accommodations > Grayscale (makes it calmer).
  Keep the keys/ folder: it's what lets this computer update the phone.
  Undo anytime: ./install.sh --undo
EOF
