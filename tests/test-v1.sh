#!/usr/bin/env bash
# Non-root tests of v1 config generation and peer management (no VPS mutation).
set -euo pipefail
cd "$(dirname "$0")/.."
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
printf 'All WireGuard Manager v1 local tests passed.\n'
