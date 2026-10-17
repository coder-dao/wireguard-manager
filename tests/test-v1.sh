#!/usr/bin/env bash
# Non-root tests of v1 config generation and peer management (no VPS mutation).
set -euo pipefail
# Works as tests/test-v1.sh in the repository or as a standalone copy.
script_dir=$(cd "$(dirname "$0")" && pwd)
if [[ -f $script_dir/wireguard-manager.sh ]]; then
  cd "$script_dir"
else
  cd "$script_dir/.."
fi
bash -n wireguard-manager.sh
# shellcheck source=../wireguard-manager.sh
source ./wireguard-manager.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
WG_DIR=$tmp/wireguard
WG_CONF=$WG_DIR/wg0.conf
CLIENT_DIR=$WG_DIR/clients
mkdir -p "$CLIENT_DIR"
cat > "$WG_CONF" <<'EOF'
[Interface]
Address = 10.66.66.1/24, fd12:3456:789a::1/64
ListenPort = 443
PrivateKey = SAMPLE
EOF
printf 'SERVERPUBLIC\n' > "$WG_DIR/server.pub"
printf '198.51.100.10\n' > "$WG_DIR/public-ipv4"
printf '2001:db8::10\n' > "$WG_DIR/public-ipv6"
load_network
[[ $VPN4_NET == 10.66.66.0/24 && $VPN6_NET == fd12:3456:789a::/64 ]]
[[ $VPN6_SERVER == fd12:3456:789a::1 ]]
[[ $(next_host) == 2 ]]
validate_ipv4_subnet 10.66.66.0/24
if validate_ipv4_subnet 8.8.8.0/24 2>/dev/null; then echo 'Public subnet accepted!' >&2; exit 1; fi
if validate_ipv4_subnet 10.66.66.0/23 2>/dev/null; then echo 'Non-/24 accepted!' >&2; exit 1; fi
random_ula | python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.stdin.read().strip()); assert n.version==6 and n.prefixlen==64 and n.subnet_of(ipaddress.ip_network("fc00::/7"))'

blocky_defaults > "$tmp/blocky.yml"
grep -Fqx 'connectIPVersion: dual' "$tmp/blocky.yml"
grep -Fqx '    - "10.66.66.1:53"' "$tmp/blocky.yml"
grep -Fqx '    - "[fd12:3456:789a::1]:53"' "$tmp/blocky.yml"
grep -Fqx '  http: "127.0.0.1:4000"' "$tmp/blocky.yml"
grep -Fqx '  privacy: true' "$tmp/blocky.yml"
if grep -Eq '^filtering:|^[[:space:]]+- AAAA$' "$tmp/blocky.yml"; then echo 'AAAA DNS was disabled!' >&2; exit 1; fi
write_ufw_nat "$tmp/v4.rules" "$tmp/v6.rules" ens3 ens4
for proto in udp tcp; do
  grep -F -- "-i wg0 -s 10.66.66.0/24 -p $proto --dport 53 -j DNAT --to-destination 10.66.66.1" "$tmp/v4.rules" >/dev/null
  grep -F -- "-i wg0 -s fd12:3456:789a::/64 -p $proto --dport 53 -j DNAT --to-destination fd12:3456:789a::1" "$tmp/v6.rules" >/dev/null
done
grep -F -- '-s fd12:3456:789a::/64 -o ens4 -j MASQUERADE' "$tmp/v6.rules" >/dev/null

# Mock the live operations; add/remove should still produce correct v1 configs.
systemctl() { return 0; }
wg() {
  case $1 in
    genkey) printf 'MOCKPRIVATE\n' ;;
    pubkey) printf 'MOCKPUBLIC\n' ;;
    *) return 0 ;;
  esac
}
sync_peers() { return 0; }
add_device phone full ipv4 >/dev/null
[[ $(next_host) == 3 ]]
grep -Fqx 'Address = 10.66.66.2/32, fd12:3456:789a::2/128' "$CLIENT_DIR/phone.conf"
grep -Fqx 'AllowedIPs = 0.0.0.0/0, ::/0' "$CLIENT_DIR/phone.conf"
grep -Fqx 'DNS = 10.66.66.1, fd12:3456:789a::1' "$CLIENT_DIR/phone.conf"
grep -Fqx 'AllowedIPs = 10.66.66.2/32, fd12:3456:789a::2/128' "$WG_CONF"
add_device tablet private ipv6 >/dev/null
grep -Fqx 'Endpoint = [2001:db8::10]:443' "$CLIENT_DIR/tablet.conf"
grep -Fqx 'AllowedIPs = 10.66.66.0/24, fd12:3456:789a::/64' "$CLIENT_DIR/tablet.conf"
if grep -q '^DNS = ' "$CLIENT_DIR/tablet.conf"; then echo 'Private mode wrongly sets DNS' >&2; exit 1; fi
printf 'REMOVE\n' | remove_device tablet >/dev/null
[[ ! -e $CLIENT_DIR/tablet.conf ]]
[[ $(next_host) == 3 ]]
# Plain-text output must be byte-for-byte identical, with no banner or escape codes.
show_config phone > "$tmp/show.conf" 2> "$tmp/show.err"
cmp "$CLIENT_DIR/phone.conf" "$tmp/show.conf"
grep -q 'private key' "$tmp/show.err"
[[ $(stat -c %a "$CLIENT_DIR/phone.conf") == 600 ]]

# Export should retain client material, use mode 600, and never overwrite files.
export_profile phone "$tmp/exported.conf" >/dev/null 2> "$tmp/export.err"
cmp "$CLIENT_DIR/phone.conf" "$tmp/exported.conf"
[[ $(stat -c %a "$tmp/exported.conf") == 600 ]]
if (export_profile phone "$tmp/exported.conf" >/dev/null 2>&1); then
  echo 'Existing export was overwritten!' >&2; exit 1
fi
cmp "$CLIENT_DIR/phone.conf" "$tmp/exported.conf"
printf 'sentinel\n' > "$tmp/important"
ln -s "$tmp/important" "$tmp/symlink.conf"
if (export_profile phone "$tmp/symlink.conf" >/dev/null 2>&1); then
  echo 'Export followed a symlink!' >&2; exit 1
fi
[[ $(cat "$tmp/important") == sentinel ]]

# Check default destination is the current directory.
(cd "$tmp"; export_profile phone >/dev/null 2>&1)
cmp "$CLIENT_DIR/phone.conf" "$tmp/phone.conf"
[[ $(stat -c %a "$tmp/phone.conf") == 600 ]]

# Guided config retrieval can show text or QR without writing to the VPS.
config_view=$(printf '2\n' | get_device_config phone 2>/dev/null)
[[ $config_view == *'[Interface]'* && $config_view == *'[Peer]'* ]]
qrencode() { printf 'TEST_QR\n'; }
qr_view=$(printf '1\n' | get_device_config phone 2>/dev/null)
[[ $qr_view == *'TEST_QR'* ]]

# The guided add-device flow maps numbered options to modes and endpoints.
printf 'laptop\n1\n2\n0\n' | menu_add_device >/dev/null 2> "$tmp/add.err"
grep -Fqx 'Endpoint = [2001:db8::10]:443' "$CLIENT_DIR/laptop.conf"
grep -Fqx 'AllowedIPs = 0.0.0.0/0, ::/0' "$CLIENT_DIR/laptop.conf"

# The updater only replaces its own CLI. Exercise it against a fake install
# and a mocked network, without changing the real VPS or hitting GitHub.
MANAGER="$tmp/bin/wireguard-manager"
UPDATE_BACKUPS="$tmp/backups"
mkdir -p "$tmp/bin"
cp ./wireguard-manager.sh "$MANAGER"
chmod 700 "$MANAGER"
cp "$MANAGER" "$tmp/old-manager"
cp "$MANAGER" "$tmp/remote-manager"
sed -i 's/^VERSION=1\.2$/VERSION=1.3/' "$tmp/remote-manager"
[[ $(manager_script_version "$tmp/remote-manager") == 1.3 ]]
[[ $(manager_script_version "$MANAGER") == 1.2 ]]
curl() {
  local target='' arg
  while (( $# )); do
    arg=$1; shift
    case $arg in
      --output) target=$1; shift ;;
    esac
  done
  [[ -n $target ]] || return 1
  [[ ${MOCK_CURL_FAIL:-0} == 0 ]] || return 22
  cp -- "$tmp/remote-manager" "$target"
}

# An available update is detectable without modifying the installed CLI.
check_output=$(update_manager --check)
[[ $check_output == *'Available: v1.3'* && $check_output == *'An update is available'* ]]
cmp "$MANAGER" "$tmp/old-manager"
[[ ! -d $UPDATE_BACKUPS ]]

# Default is to reject an update unless the user explicitly consents.
answer_output=$(printf 'n\n' | update_manager)
[[ $answer_output == *'Update cancelled'* ]]
cmp "$MANAGER" "$tmp/old-manager"

# Noninteractive updates are explicitly opted into with --yes.
update_manager --yes > "$tmp/update.log"
[[ $(manager_script_version "$MANAGER") == 1.3 ]]
[[ $(stat -c %a "$MANAGER") == 700 ]]
cmp "$MANAGER" "$tmp/remote-manager"
shopt -s nullglob
backups=("$UPDATE_BACKUPS"/*.bak)
[[ ${#backups[@]} == 1 ]]
cmp "${backups[0]}" "$tmp/old-manager"
[[ $(stat -c %a "${backups[0]}") == 600 ]]

# Running update again against identical content is a no-op.
update_manager --yes > "$tmp/noop.log"
backups=("$UPDATE_BACKUPS"/*.bak)
[[ ${#backups[@]} == 1 ]]

# Reject older, broken, and failed downloads without touching the CLI.
sed -i 's/^VERSION=1\.3$/VERSION=1.1/' "$tmp/remote-manager"
if (update_manager --yes >/dev/null 2>&1); then
  echo 'Updater accepted a downgrade!' >&2; exit 1
fi
cmp "$MANAGER" "$tmp/bin/wireguard-manager"
sed -i 's/^VERSION=1\.1$/VERSION=1.4/' "$tmp/remote-manager"
printf '\nif false; then\n' >> "$tmp/remote-manager"
if (update_manager --yes >/dev/null 2>&1); then
  echo 'Updater accepted invalid Bash syntax!' >&2; exit 1
fi
MOCK_CURL_FAIL=1
if (update_manager --yes >/dev/null 2>&1); then
  echo 'Updater accepted a failed download!' >&2; exit 1
fi
unset MOCK_CURL_FAIL
[[ $(manager_script_version "$MANAGER") == 1.3 ]]
backups=("$UPDATE_BACKUPS"/*.bak)
[[ ${#backups[@]} == 1 ]]

# The menu and help should advertise config, export, and QR clearly.
menu_text=$(printf '0\n' | menu)
[[ $menu_text == *'Get device configuration  (QR / copy / file)'* ]]
[[ $menu_text == *'Update WireGuard Manager'* ]]
help_text=$(bash ./wireguard-manager.sh --help)
[[ $help_text == *'config NAME'* && $help_text == *'export NAME'* && $help_text == *'get [NAME]'* ]]
[[ $help_text == *'update --check'* && $help_text == *'update --yes'* ]]

printf 'All WireGuard Manager v1.2 local tests passed.\n' 
