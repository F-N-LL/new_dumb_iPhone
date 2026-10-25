#!/usr/bin/env bash
# WhatsApp on the dumb iPhone, through a bridge that runs at home: on this computer, or on an
# always-on spare Android phone with Termux. The bridge links to your WhatsApp like WhatsApp Web
# (your main phone keeps the account) and serves a simple chat page; LightHome gets a "WhatsApp" row.
#   ./whatsapp.sh                     set up / update on this computer (iPhone plugged in)
#   ./whatsapp.sh --remote <ip>       set up / update on an Android phone running Termux + sshd
#   ./whatsapp.sh --remove            stop the bridge wherever it runs, unlink it, clean the iPhone
# Unofficial client: WhatsApp's terms don't allow it. Ban risk is low for personal use, not zero.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PORT=8443
UNIT=dumb-iphone-whatsapp.service
PREFS=/var/mobile/Library/Preferences/local.dumbiphone.lighthome.plist
RD=.local/share/dumb-iphone-whatsapp        # bridge data (session, messages, keys), relative to $HOME
mkdir -p keys

mode=local remote=""
case "${1:-}" in
  --remote) remote=${2:?usage: ./whatsapp.sh --remote <android-ip>}; mode=remote ;;
  --remove) mode=remove ;;
  "") [ -f keys/bridge_host ] && { remote=$(cat keys/bridge_host); mode=remote; } ;;
  *) die "usage: ./whatsapp.sh [--remote <ip> | --remove]" ;;
esac
[ "$mode" = remove ] && [ -f keys/bridge_host ] && remote=$(cat keys/bridge_host)

# --- where the bridge runs: h runs a shell command there, hput copies a file there ----------
if [ -n "$remote" ]; then
  # Termux's sshd: port 8022, any user name, a key of our own (password only the first time).
  [ -f keys/bridgehost_ssh ] || ssh-keygen -q -t ed25519 -N "" -C dumbiphone-bridgehost -f keys/bridgehost_ssh
  rssh() { ssh -p 8022 -i keys/bridgehost_ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile="$ROOT/keys/known_hosts_bridgehost" -o ConnectTimeout=10 "termux@$remote" "$@"; }
  h()    { rssh -o BatchMode=yes "$@"; }
  hput() { h "cat > '$2' && chmod ${3:-600} '$2'" < "$1"; }
else
  h()    { (cd "$HOME" && bash -c "$*"); }
  hput() { install -m "${3:-600}" "$1" "$HOME/$2"; }
fi

firewall() {  # firewall add|remove <subnet>: the bridge port, for the home network only (this computer)
  local rule="rule family=ipv4 source address=$2 port port=$PORT protocol=tcp accept"
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for p in "" --permanent; do sudo firewall-cmd -q $p --$1-rich-rule="$rule" || true; done
  elif command -v ufw >/dev/null && sudo ufw status | grep active >/dev/null; then
    if [ "$1" = add ]; then sudo ufw allow from "$2" to any port $PORT proto tcp
    else sudo ufw delete allow from "$2" to any port $PORT proto tcp || true; fi
  fi
}
home_subnet() {
  ip -4 -o addr show | awk -v ip="$1" '$4 ~ "^"ip"/" {print $4}' \
    | python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.stdin.read().strip()).network)"
}

stop_bridge() {
  if [ -n "$remote" ]; then
    h "[ -f $RD/loop.pid ] && kill \$(cat $RD/loop.pid) 2>/dev/null; pkill -x wabridge; true"
  else
    systemctl --user stop $UNIT 2>/dev/null || true
  fi
}

# --- remove ----------------------------------------------------------------------------------
if [ "$mode" = remove ]; then
  say "Stopping and unlinking the bridge"
  stop_bridge
  h "[ -x $RD/wabridge ] && $RD/wabridge -data \$HOME/$RD -logout; true" || true
  if [ -n "$remote" ]; then
    h "rm -rf $RD .termux/boot/dumb-iphone-whatsapp" || true
    rm -f keys/bridge_host
  else
    systemctl --user disable $UNIT 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$UNIT"
    rm -rf "${HOME:?}/$RD"
    say "Removing the port rule (asks for sudo)"
    firewall remove "$(home_subnet "$(ip -4 route get 1.1.1.1 | grep -oP 'src \K\S+')")" || true
  fi
  phone_ssh
  phr "rm -f $PREFS; cd ~/.ssh && grep -v dumbiphone-gallery authorized_keys > ak.tmp; cat ak.tmp > authorized_keys; rm -f ak.tmp; killall -9 SpringBoard" || true
  pmd profile remove local.dumbiphone.wabridge-ca >/dev/null 2>&1 || true
  say "Bridge removed and unlinked from WhatsApp."
  exit 0
fi

# --- first contact with the Android phone ------------------------------------------------------
if [ -n "$remote" ] && ! h true 2>/dev/null; then
  say "First time: type the Termux password you set with 'passwd' on the Android phone."
  rssh -o PubkeyAuthentication=no 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < keys/bridgehost_ssh.pub
  say "Turning off password logins on the Android phone (key only from now on)"
  h 'f=${PREFIX:-/data/data/com.termux/files/usr}/etc/ssh/sshd_config; grep -v "^PasswordAuthentication" $f > $f.tmp; echo "PasswordAuthentication no" >> $f.tmp; mv $f.tmp $f
     nohup sh -c "sleep 2; pkill -x sshd; sshd" >/dev/null 2>&1 &'
  sleep 5
  h true || die "Can't reach the Android phone again. In Termux, run: sshd"
fi
if [ -n "$remote" ]; then
  echo "$remote" > keys/bridge_host
  host_ip=$remote
  h 'command -v ssh-keygen >/dev/null && command -v termux-wake-lock >/dev/null' \
    || die "In Termux on the Android phone, run: pkg install -y openssh termux-tools"
else
  host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+') || die "No network connection on this computer."
fi

# --- build for the bridge's machine -----------------------------------------------------------
command -v go >/dev/null || die "Needs Go 1.24+ on this computer: sudo dnf install golang  (or apt install golang / pacman -S go)"
case "$(h uname -m)" in
  x86_64) goarch=amd64 ;; aarch64|arm64) goarch=arm64 ;; armv7*|armv8l) goarch=arm ;;
  *) die "Unsupported CPU: $(h uname -m)" ;;
esac
say "Building the bridge (linux/$goarch)"
mkdir -p build
(cd wabridge && CGO_ENABLED=0 GOOS=linux GOARCH=$goarch GOARM=7 go build -trimpath -o "$ROOT/build/wabridge-$goarch" .)
stop_bridge
h "mkdir -p $RD && chmod 700 $RD"
hput "build/wabridge-$goarch" "$RD/wabridge" 700
DATA=$(h "echo \$HOME/$RD")

# --- moving from this computer to the Android phone: unlink the old copy -----------------------
if [ -n "$remote" ] && [ -x "$HOME/$RD/wabridge" ]; then
  say "Retiring the bridge on this computer (now on $remote)"
  systemctl --user disable --now $UNIT 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/$UNIT"
  "$HOME/$RD/wabridge" -data "$HOME/$RD" -logout || true
  rm -rf "${HOME:?}/$RD"
fi

# --- link to WhatsApp (once; shows a QR code here) ---------------------------------------------
if [ -n "$remote" ]; then rssh -t -o BatchMode=yes "$DATA/wabridge -data $DATA -link"
else "$DATA/wabridge" -data "$DATA" -link; fi

# --- camera-roll access for photos: its own key, which the iPhone limits to list/read photos ---
h "[ -f $RD/gallery_ssh ] || ssh-keygen -q -t rsa -b 3072 -N '' -C dumbiphone-gallery -f $RD/gallery_ssh"
if [ -z "$remote" ] && [ -f keys/openssl-legacy.cnf ]; then hput keys/openssl-legacy.cnf "$RD/openssl-legacy.cnf"
else h "echo '# not needed here' > $RD/openssl-legacy.cnf"; fi
h "cat > $RD/ssh_config" <<EOF
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

# --- keep it running -------------------------------------------------------------------------
if [ -n "$remote" ]; then
  # Termux:Boot runs this at boot; the loop restarts the bridge if it ever exits.
  h "mkdir -p .termux/boot && cat > .termux/boot/dumb-iphone-whatsapp && chmod 700 .termux/boot/dumb-iphone-whatsapp" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
# WhatsApp bridge for the dumb iPhone (installed by whatsapp.sh)
termux-wake-lock
pgrep -x sshd >/dev/null || sshd
cd "$DATA" || exit 1
echo \$\$ > loop.pid
while true; do
  [ -f bridge.log ] && [ \$(wc -c < bridge.log) -gt 1000000 ] && mv bridge.log bridge.log.1
  ./wabridge -data "$DATA" -addr :$PORT -ip $host_ip >> bridge.log 2>&1
  sleep 10
done
EOF
  h "nohup sh .termux/boot/dumb-iphone-whatsapp >/dev/null 2>&1 &"
  sleep 4
  h "pgrep -x wabridge >/dev/null" || die "The bridge didn't start on the Android phone; see $DATA/bridge.log there."
else
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/$UNIT" <<EOF
[Unit]
Description=WhatsApp bridge for the dumb iPhone
After=network-online.target

[Service]
ExecStart=$DATA/wabridge -data $DATA -addr :$PORT -ip $host_ip
Restart=always
RestartSec=10
NoNewPrivileges=yes
UMask=0077
PrivateTmp=yes

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now $UNIT
  subnet=$(home_subnet "$host_ip")
  say "Opening port $PORT to your home network only ($subnet); may ask for sudo"
  firewall add "$subnet"
fi

# --- the iPhone: trust the bridge's certificate, add the row, allow photo reads ---------------
say "Setting up the iPhone"
./deploy.sh                       # LightHome 1.2+ reads the extra row
mkdir -p build
h "cat $RD/ca.pem" > build/wabridge-ca.pem
python3 build_profile.py ca build/wabridge-ca.mobileconfig build/wabridge-ca.pem >/dev/null
pmd profile remove local.dumbiphone.wabridge-ca >/dev/null 2>&1 || true
if [ -f keys/supervisor.pem ]; then
  pmd profile install --keybag keys/supervisor.pem build/wabridge-ca.mobileconfig
else
  pmd profile install build/wabridge-ca.mobileconfig
  read -r -p "  On the iPhone: Settings > General > Profiles, install 'WhatsApp bridge certificate', then press Enter. "
fi
token=$(h "cat $RD/token")
phone_ssh
phr "cat > $PREFS && chown mobile:mobile $PREFS && chmod 600 $PREFS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>rows</key><array>
<array><string>WhatsApp</string><string>https://$host_ip:$PORT/?k=$token</string></array>
</array></dict></plist>
EOF
unset token
push wabridge/phone/dumbiphone-gallery /usr/bin/dumbiphone-gallery
opts='command="/usr/bin/dumbiphone-gallery",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding'
phr "chown root:wheel /usr/bin/dumbiphone-gallery && chmod 755 /usr/bin/dumbiphone-gallery && cd ~/.ssh && grep -v dumbiphone-gallery authorized_keys > ak.tmp; echo '$opts $(h "cat $RD/gallery_ssh.pub")' >> ak.tmp && cat ak.tmp > authorized_keys && rm ak.tmp && killall -9 SpringBoard"

say "Done. LightHome's WhatsApp row now opens the bridge on ${remote:-this computer} ($host_ip)."
cat <<EOF
  Works on your home Wi-Fi while the bridge's machine is on.
  Give $host_ip a fixed address in your router (DHCP reservation) so the row keeps working;
  if it changes, run ./whatsapp.sh again.
  Undo: ./whatsapp.sh --remove
EOF
