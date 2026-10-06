#!/usr/bin/env bash
# One command: plug in a 32-bit iPhone/iPad/iPod (4S, 5, 5c...) on iOS 8.2 - 9.3.6 and run
#   ./dumbify.sh
# It checks the phone, walks you through the two steps that must happen on the phone
# (Carbon jailbreak in Safari, OpenSSH in Cydia), then installs everything else by itself.
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m[%s]\033[0m \033[1m%s\033[0m\n' "$1" "$2"; }
die()  { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- computer side --------------------------------------------------------
step 1/4 "Tools on this computer"
need=()
for c in usbmuxd git curl make perl python3 ssh xz; do command -v $c >/dev/null || need+=($c); done
if [ ${#need[@]} -gt 0 ]; then
  echo "  Installing: ${need[*]} (asks for sudo)"
  pk=$(printf '%s\n' "${need[@]}" | sed 's/^ssh$/openssh-clients/; s/^xz$/xz-utils/' | sort -u | tr '\n' ' ')
  if command -v dnf >/dev/null; then sudo dnf install -y ${pk//xz-utils/xz}
  elif command -v apt-get >/dev/null; then sudo apt-get install -y ${pk//openssh-clients/openssh-client}
  elif command -v pacman >/dev/null; then pk=${pk//openssh-clients/openssh}; sudo pacman -S --noconfirm ${pk//xz-utils/xz}
  else die "Please install: ${need[*]}"; fi
fi
if ! command -v uv >/dev/null && [ ! -x "$HOME/.local/bin/uv" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
pmd() { uv tool run -q --python 3.12 pymobiledevice3@11.23.0 "$@"; }
echo "  ok"

# --- the phone ------------------------------------------------------------
step 2/4 "Finding the iPhone"
echo "  Plug it in with USB, unlock it, and set Settings > General > Auto-Lock > Never for now."
[ -S /var/run/usbmuxd ] || sudo systemctl start usbmuxd
until pmd usbmux list 2>/dev/null | grep >/dev/null Identifier; do sleep 2; done
until pmd lockdown pair >/dev/null 2>&1; do echo "  Tap 'Trust' on the iPhone..."; sleep 3; done
ver=$(pmd lockdown get --key ProductVersion | tr -dc '0-9.')
model=$(pmd lockdown get --key ProductType | tr -dc 'A-Za-z0-9,')
echo "  $model on iOS $ver"
# Carbon jailbreaks 32-bit iOS 8.0-9.3.6; LightHome needs 8.2+.
python3 -c "import sys; v=tuple(map(int,'$ver'.split('.')));sys.exit(not (8,2)<=v<=(9,3,6))" \
  || die "This needs iOS 8.2 - 9.3.6 (Carbon jailbreak). For a no-jailbreak setup on iOS 9.3+ use ./install.sh"
case "$model" in
  iPhone4,1|iPhone5,[1-4]|iPad2,*|iPad3,*|iPod5,1) ;;
  *) die "$model is not supported: Carbon only jailbreaks 32-bit devices (iPhone 4S/5/5c, iPad 2-4, iPad mini 1, iPod touch 5)." ;;
esac

# --- jailbreak (on the phone) ---------------------------------------------
step 3/4 "Jailbreak"
cydia() { pmd apps list 2>/dev/null | grep >/dev/null '"com.saurik.Cydia"'; }
if ! cydia; then
  cat <<'EOF'
  On the iPhone (connected to Wi-Fi):
    1. Open Safari and go to   http://carbon.sep.lol
    2. Tap "Run". The phone may restart; if no Cydia icon appears, tap Run again.
  Waiting for Cydia to appear...
EOF
  until cydia; do sleep 5; done
  echo "  Jailbroken."
fi

# OpenSSH is the one package that must come from Cydia (the computer needs it to reach the phone).
pmd usbmux forward 2222 22 >/dev/null 2>&1 &
fwd=$!; trap 'kill $fwd 2>/dev/null || true' EXIT; sleep 4
sshd_up() { timeout 90 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222; head -c 4 <&3' 2>/dev/null | grep >/dev/null SSH; }
if ! sshd_up; then
  cat <<'EOF'
  On the iPhone: open Cydia, let it finish loading, then
    Search > "OpenSSH" > Install > Confirm.
  Waiting for OpenSSH...
EOF
  until sshd_up; do sleep 5; done
fi
kill $fwd 2>/dev/null || true; trap - EXIT

# --- the rest, from this computer -----------------------------------------
step 4/4 "Installing LightHome"
./deploy.sh

say "All done."
cat <<'EOF'
  Home screen: big clock, date, and Phone, Messages, Camera, Directions, Music, Podcasts, Tools.
  No working Home button? Press volume-down twice quickly.
  Change the list: edit lighthome/Tweak.x, then ./deploy.sh
  Undo: ./deploy.sh --remove
  You can set Auto-Lock back to normal now.
EOF
