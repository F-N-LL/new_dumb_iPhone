#!/usr/bin/env bash
# Builds LightHome (the Light Phone style home screen) and installs it on a jailbroken iPhone over USB.
# Needs: jailbreak + OpenSSH from Cydia. First run asks once for the root password (default: alpine).
#   ./deploy.sh           build + install
#   ./deploy.sh --remove  uninstall LightHome
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
export PATH="$HOME/.local/bin:$PATH"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
pmd() { uv tool run -q --python 3.12 pymobiledevice3@11.23.0 "$@"; }

# Pinned downloads: change these together with their hashes.
THEOS_COMMIT=dd5c14bb9d91311e221d51b5bfb8c9e5948156db
SDKS_COMMIT=0222fd5413cf4b9af096f37b4621afa2688572f7
TOOLCHAIN_URL=https://github.com/L1ghtmann/llvm-project/releases/download/test-210562a
TOOLCHAIN_SHA_x86_64=a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e
TOOLCHAIN_SHA_aarch64=9051e9d531de5e511f0fab40d925d625bc6efe7ed9dce821d179c09de9bc690b
DEBS=(  # file  sha256  source
  "mobilesubstrate_0.9.6301_iphoneos-arm.deb 8dc91a066f088632409fecf65613831b8d6802e3b799f2dc87563c3ea2ed06ca http://apt.saurik.com/debs"
  "com.saurik.substrate.safemode_0.9.6001_iphoneos-arm.deb 86515cb9f6832247dbeae8427b996099dc8759bb1ef1d719c293123f2f531ee1 http://apt.saurik.com/debs"
  "com.staturnz.iocaste_1.0_iphoneos-arm.deb 82bed58236d1d3cebea9d849df4d11da36d5a3cc2c899acf05b985354fb20ad2 https://lukezgd.github.io/repo/debs"
)
fetch_deb() {  # fetch_deb <file>: download (once) and verify a pinned .deb into tools/debs
  local line f sha src; mkdir -p tools/debs
  for line in "${DEBS[@]}"; do
    read -r f sha src <<<"$line"; [ "$f" = "$1" ] || continue
    [ -f "tools/debs/$f" ] || curl -fsSL "$src/$f" -o "tools/debs/$f"
    echo "$sha  tools/debs/$f" | sha256sum -c --quiet || { rm -f "tools/debs/$f"; die "Checksum mismatch: $f"; }
    return
  done
  die "Unknown package $1"
}

# --- ssh to the phone over USB --------------------------------------------
# Per clone, in keys/ (git-ignored): a key for this computer and settings for iOS 9's old sshd (OpenSSH 6.7).
mkdir -p keys
[ -f keys/phone_ssh ] || ssh-keygen -q -t rsa -b 3072 -N "" -C dumbiphone -f keys/phone_ssh
cat > keys/ssh_config <<EOF
Host phone
    IgnoreUnknown PubkeyAcceptedAlgorithms,PubkeyAcceptedKeyTypes,WarnWeakCrypto
    WarnWeakCrypto no
    HostName 127.0.0.1
    Port 2222
    User root
    IdentityFile $ROOT/keys/phone_ssh
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile $ROOT/keys/known_hosts
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    PubkeyAcceptedKeyTypes +ssh-rsa
EOF
# Fedora/RHEL crypto policies block the SHA-1 signatures iOS 9's sshd uses. Allowed for this script only.
if [ -d /etc/crypto-policies ]; then
  printf '%s\n' 'openssl_conf = openssl_init' '[openssl_init]' 'alg_section = evp_properties' \
    '[evp_properties]' 'rh-allow-sha1-signatures = yes' > keys/openssl-legacy.cnf
  export OPENSSL_CONF=$ROOT/keys/openssl-legacy.cnf
fi

if ! (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null; then   # tunnel localhost:2222 -> phone:22
  pmd usbmux forward 2222 22 >/dev/null 2>&1 &
  fwd=$!; trap 'kill $fwd 2>/dev/null || true' EXIT
  sleep 4
fi
ph()   { ssh -F keys/ssh_config -o ConnectTimeout=60 phone "$@"; }
phr()  { ph -o BatchMode=yes "export PATH=/usr/bin:/bin:/usr/sbin:/sbin; $*"; }  # root shell on the phone
push() { phr "cat > '$2'" < "$1"; }                                              # push <local> <remote>

if ! ph -o BatchMode=yes true 2>/dev/null; then
  say "First time: type the phone's root password (default is alpine)."
  ph 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < keys/phone_ssh.pub
  say "Turning off password logins on the phone (key only from now on)."
  phr "sed -i.bak -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' -e 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config && grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config"
fi

if [ "${1:-}" = "--remove" ]; then
  phr 'dpkg -r local.dumbiphone.lighthome && killall -9 SpringBoard'
  say "LightHome removed."; exit 0
fi

# --- build ----------------------------------------------------------------
export THEOS=$ROOT/tools/theos
[ -d tools/perl5 ] && export PERL5LIB=$ROOT/tools/perl5   # modules fetched by older versions of this script
# Theos needs perl's core modules; minimal installs (e.g. Fedora's perl-interpreter) lack some.
if ! perl -MFindBin -MModule::Load::Conditional -MArchive::Tar -MIO::Zlib -MEnglish -e1 2>/dev/null; then
  say "Installing full perl (asks for sudo)"
  if command -v dnf >/dev/null; then sudo dnf install -y perl
  elif command -v apt-get >/dev/null; then sudo apt-get install -y perl
  elif command -v pacman >/dev/null; then sudo pacman -S --noconfirm perl
  else die "Install perl with its core modules and run again."; fi
fi
if [ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]; then
  say "One-time: setting up the iOS build tools in tools/ (~300 MB)"
  arch=$(uname -m); sha_var=TOOLCHAIN_SHA_$arch
  [ -n "${!sha_var:-}" ] || die "No iOS toolchain for $arch Linux (x86_64 and aarch64 only)."
  rm -rf "$THEOS" tools/sdks; mkdir -p "$THEOS" tools/sdks
  git -C "$THEOS" init -q && git -C "$THEOS" fetch -q --depth 1 https://github.com/theos/theos.git $THEOS_COMMIT
  git -C "$THEOS" checkout -q FETCH_HEAD && git -C "$THEOS" submodule -q update --init --recursive --depth 1
  curl -fsSL "$TOOLCHAIN_URL/iOSToolchain-$arch.tar.xz" -o tools/toolchain.tar.xz
  echo "${!sha_var}  tools/toolchain.tar.xz" | sha256sum -c --quiet || die "Toolchain checksum mismatch"
  mkdir -p "$THEOS/toolchain/linux/iphone"
  tar -xJf tools/toolchain.tar.xz -C "$THEOS/toolchain/linux/iphone" --strip-components=2 && rm tools/toolchain.tar.xz
  git -C tools/sdks init -q && git -C tools/sdks fetch -q --depth 1 https://github.com/theos/sdks.git $SDKS_COMMIT
  git -C tools/sdks checkout -q FETCH_HEAD -- iPhoneOS10.3.sdk
  mv tools/sdks/iPhoneOS10.3.sdk "$THEOS/sdks/" && rm -rf tools/sdks
fi

say "Building LightHome"
make -C lighthome package FINALPACKAGE=1 THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip >/dev/null
deb=$(ls -t lighthome/packages/*.deb | head -1)

# --- install --------------------------------------------------------------
say "Installing on the phone"
ver=$(pmd lockdown get --key ProductVersion | tr -dc '0-9.')
# iocaste untether keeps the jailbreak after a reboot on 9.3.5/9.3.6 (Carbon is untethered by itself below).
if [[ $ver == 9.3.5 || $ver == 9.3.6 ]] && ! phr 'dpkg -s com.staturnz.iocaste' >/dev/null 2>&1; then
  say "Installing the iocaste untether (jailbreak survives reboots)"
  fetch_deb com.staturnz.iocaste_1.0_iphoneos-arm.deb
  push tools/debs/com.staturnz.iocaste_1.0_iphoneos-arm.deb /tmp/iocaste.deb
  phr 'dpkg -i /tmp/iocaste.deb; rm -f /tmp/iocaste.deb'
fi
# Carbon doesn't ship Cydia Substrate (what loads tweaks).
if ! phr 'dpkg -s mobilesubstrate' >/dev/null 2>&1; then
  for f in mobilesubstrate_0.9.6301_iphoneos-arm.deb com.saurik.substrate.safemode_0.9.6001_iphoneos-arm.deb; do
    fetch_deb $f; push tools/debs/$f /tmp/$f
  done
  phr 'dpkg -i /tmp/mobilesubstrate_*.deb /tmp/com.saurik.substrate.safemode_*.deb; rm -f /tmp/*.deb'
fi
push "$deb" /tmp/lighthome.deb
phr 'dpkg -i /tmp/lighthome.deb && rm /tmp/lighthome.deb && killall -9 SpringBoard'
say "Done. The home screen restarts with the new look."
