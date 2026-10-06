#!/usr/bin/env bash
# WhatsApp on the dumb iPhone, through a bridge that runs on this computer.
# The bridge links to your WhatsApp like WhatsApp Web (your main phone keeps the account)
# and serves a simple chat page; LightHome gets a "WhatsApp" row that opens it.
#   ./whatsapp.sh            set up / update (phone plugged in, LightHome installed)
#   ./whatsapp.sh --remove   stop the bridge, unlink it, remove the row and certificate
# Unofficial client: WhatsApp's terms don't allow it. Ban risk is low for personal use, not zero.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

DATA=$HOME/.local/share/dumb-iphone-whatsapp   # session + messages: outside the repo, private
PORT=8443
UNIT=dumb-iphone-whatsapp.service
PREFS=/var/mobile/Library/Preferences/local.dumbiphone.lighthome.plist
mkdir -p "$DATA" && chmod 700 "$DATA"

# This computer's address on the home network (the phone connects to it over Wi-Fi).
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+') || die "No network connection on this computer."
subnet=$(ip -4 -o addr show | awk -v ip="$ip" '$4 ~ "^"ip"/" {print $4}' | python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.stdin.read().strip()).network)")

firewall() {  # firewall add|remove: allow the bridge port only from the home network
  local rule="rule family=ipv4 source address=$subnet port port=$PORT protocol=tcp accept"
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for p in "" --permanent; do sudo firewall-cmd -q $p --$1-rich-rule="$rule" || true; done
  elif command -v ufw >/dev/null && sudo ufw status | grep active >/dev/null; then
    if [ "$1" = add ]; then sudo ufw allow from "$subnet" to any port $PORT proto tcp
    else sudo ufw delete allow from "$subnet" to any port $PORT proto tcp || true; fi
  fi
}

if [ "${1:-}" = "--remove" ]; then
  systemctl --user disable --now $UNIT 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$UNIT"
  say "Removing the port rule (asks for sudo)"; firewall remove
  phone_ssh
  phr "rm -f $PREFS; killall -9 SpringBoard" || true
  pmd profile remove local.dumbiphone.wabridge-ca >/dev/null 2>&1 || true
  rm -rf "$DATA"
  say "Bridge removed. Also remove it on your main phone: WhatsApp > Linked devices."
  exit 0
fi

# --- build -----------------------------------------------------------------
command -v go >/dev/null || die "Needs Go 1.24+: sudo dnf install golang  (or apt install golang / pacman -S go)"
say "Building the bridge"
(cd wabridge && CGO_ENABLED=0 go build -trimpath -o wabridge .)
install -m 755 wabridge/wabridge "$DATA/wabridge"

# --- link to WhatsApp (once) -----------------------------------------------
systemctl --user stop $UNIT 2>/dev/null || true   # the session db can only be open once
"$DATA/wabridge" -data "$DATA" -link

# --- run it in the background, start with the computer -----------------------
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/$UNIT" <<EOF
[Unit]
Description=WhatsApp bridge for the dumb iPhone
After=network-online.target

[Service]
ExecStart=$DATA/wabridge -data $DATA -addr :$PORT
Restart=always
RestartSec=10
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now $UNIT
say "Opening port $PORT to your home network only ($subnet), asks for sudo"
firewall add

# --- the phone: trust the bridge's certificate, add the row ----------------
say "Setting up the phone"
./deploy.sh                       # LightHome 1.2+ reads the extra row
mkdir -p build && python3 build_profile.py ca build/wabridge-ca.mobileconfig "$DATA/ca.pem" >/dev/null
if [ -f keys/supervisor.pem ]; then
  pmd profile install --keybag keys/supervisor.pem build/wabridge-ca.mobileconfig
else
  pmd profile install build/wabridge-ca.mobileconfig
  read -r -p "  On the phone: Settings > General > Profiles, install 'WhatsApp bridge certificate', then press Enter. "
fi
url="https://$ip:$PORT/?k=$(cat "$DATA/token")"
phone_ssh
phr "cat > $PREFS && chown mobile:mobile $PREFS && chmod 600 $PREFS && killall -9 SpringBoard" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>rows</key><array>
<array><string>WhatsApp</string><string>$url</string></array>
</array></dict></plist>
EOF

# Camera-roll access for sending photos (Safari's own picker crashes on jailbroken iOS 9).
# A separate key that the phone only accepts for phone/dumbiphone-gallery: list photos, read one.
say "Letting the bridge read the phone's camera roll (list and read photos only)"
[ -f "$DATA/gallery_ssh" ] || ssh-keygen -q -t rsa -b 3072 -N "" -C dumbiphone-gallery -f "$DATA/gallery_ssh"
if [ -f keys/openssl-legacy.cnf ]; then cp keys/openssl-legacy.cnf "$DATA/"; else echo "# not needed here" > "$DATA/openssl-legacy.cnf"; fi
cat > "$DATA/ssh_config" <<EOF
Host gallery
    IgnoreUnknown PubkeyAcceptedAlgorithms,PubkeyAcceptedKeyTypes,WarnWeakCrypto
    WarnWeakCrypto no
    Port 22
    User root
    IdentityFile $DATA/gallery_ssh
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 8
    StrictHostKeyChecking accept-new
    UserKnownHostsFile $DATA/known_hosts
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    PubkeyAcceptedKeyTypes +ssh-rsa
EOF
push wabridge/phone/dumbiphone-gallery /usr/bin/dumbiphone-gallery
opts='command="/usr/bin/dumbiphone-gallery",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding'
phr "chown root:wheel /usr/bin/dumbiphone-gallery && chmod 755 /usr/bin/dumbiphone-gallery && cd ~/.ssh && grep -v dumbiphone-gallery authorized_keys > ak.tmp; echo '$opts $(cat "$DATA/gallery_ssh.pub")' >> ak.tmp && cat ak.tmp > authorized_keys && rm ak.tmp"

say "Done. LightHome now has a WhatsApp row."
cat <<EOF
  Works on your home Wi-Fi while this computer is on (the bridge starts with it).
  If this computer's address changes from $ip, run ./whatsapp.sh again.
  Undo: ./whatsapp.sh --remove
EOF
