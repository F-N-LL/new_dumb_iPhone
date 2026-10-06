# shellcheck shell=bash
# Shared by deploy.sh and whatsapp.sh. Source it; then call phone_ssh to get ph/phr/push.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT" || exit 1
export PATH="$HOME/.local/bin:$PATH"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
pmd() { uv tool run -q --python 3.12 pymobiledevice3@11.23.0 "$@"; }

phone_ssh() {
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
}
