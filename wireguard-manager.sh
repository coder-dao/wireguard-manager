#!/usr/bin/env bash
# WireGuard Manager v1 -- dual-stack WireGuard and private Blocky DNS.
# Fresh Ubuntu 26.04 LTS installs only. No embedded credentials.
set -euo pipefail
umask 077

VERSION=1
PORT=443
WG_DIR=/etc/wireguard
WG_CONF=$WG_DIR/wg0.conf
CLIENT_DIR=$WG_DIR/clients
MANAGER=/usr/local/sbin/wireguard-manager
BLOCKY_BIN=/usr/local/bin/blocky
BLOCKY_CONF=/etc/blocky/config.yml
BLOCKY_UNIT=/etc/systemd/system/blocky.service
BLOCKY_VERSION=v0.35.0
API=127.0.0.1:4000

VPN4_NET='' VPN4_SERVER='' VPN4_PREFIX=''
VPN6_NET='' VPN6_SERVER='' VPN6_PREFIX=''
WAN4='' WAN6=''

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
root_only() { (( EUID == 0 )) || fail 'Run with sudo.'; }
valid_name() { [[ ${1:-} =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }

# Parse only the two addresses placed in wg0.conf by this version.
load_network() {
  [[ -r $WG_CONF && -r $WG_DIR/server.pub && -d $CLIENT_DIR &&
     -r $WG_DIR/public-ipv4 && -r $WG_DIR/public-ipv6 ]] ||
    fail 'No complete v1 installation found (fresh install required).'
  local addresses v4 v6
  addresses=$(sed -nE 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*([^#]+).*$/\1/p' "$WG_CONF" | head -n 1)
  v4=${addresses%%,*}; v4=${v4//[[:space:]]/}
  v6=${addresses#*,}; v6=${v6//[[:space:]]/}
  [[ $v4 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/24$ &&
     $v6 =~ ^fd[0-9a-f]{2}:[0-9a-f]{4}:[0-9a-f]{4}::1/64$ ]] ||
    fail 'Invalid v1 dual-stack network in wg0.conf.'
  VPN4_SERVER=${v4%/*}
  VPN4_PREFIX=${VPN4_SERVER%.*}
  VPN4_NET=$VPN4_PREFIX.0/24
  VPN6_SERVER=${v6%/*}
  VPN6_PREFIX=${VPN6_SERVER%::1}
  VPN6_NET=$VPN6_PREFIX::/64
}

validate_ipv4_subnet() {
  python3 - "$1" <<'PY'
import ipaddress,sys
try:
    n=ipaddress.ip_network(sys.argv[1],strict=True)
    if n.version != 4 or n.prefixlen != 24 or not n.is_private or not any(
        n.subnet_of(ipaddress.ip_network(s)) for s in
        ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')):
        raise ValueError('Use an RFC1918 /24, for example 10.66.66.0/24')
except ValueError as e: sys.exit(str(e))
PY
}

check_route_overlap() {
  local family=$1 subnet=$2 overlap
  overlap=$(ip "-$family" route show table all | python3 -c '
import ipaddress,sys
vpn=ipaddress.ip_network(sys.argv[1]); matches=set()
for line in sys.stdin:
    word=line.split()
    if not word: continue
    target=word[0]
    if target in ("default", "local", "broadcast", "unreachable", "prohibit", "throw"):
        continue
    try: route=ipaddress.ip_network(target,strict=False)
    except ValueError: continue
    if route.version==vpn.version and route.overlaps(vpn): matches.add(str(route))
print(", ".join(sorted(matches)))
' "$subnet")
  [[ -z $overlap ]] || fail "$subnet overlaps an existing VPS route: $overlap"
}

# ULA /64 with a randomly generated 40-bit Global ID (RFC4193).
random_ula() {
  python3 - <<'PY'
import secrets
s=secrets.token_hex(5)
print(f'fd{s[:2]}:{s[2:6]}:{s[6:]}::/64')
PY
}

# A public, working IPv6 uplink is mandatory: don't silently downgrade to IPv4.
check_ipv6() {
  [[ -d /proc/sys/net/ipv6/conf ]] || fail 'IPv6 kernel support is not available.'
  local iface value
  for iface in all default lo; do
    [[ -r /proc/sys/net/ipv6/conf/$iface/disable_ipv6 ]] || fail 'Cannot inspect IPv6 state.'
    value=$(< "/proc/sys/net/ipv6/conf/$iface/disable_ipv6")
    [[ $value == 0 ]] || fail 'IPv6 is disabled. Remove old disable-ipv6 sysctls, restore IPv6 and reboot before installing.'
  done
  ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1 ||
    fail 'VPS has no working IPv6 route. Enable provider IPv6 and a default gateway.'
}

public_ip() {
  local version=$1 host output
  if [[ $version == 4 ]]; then host=https://api.ipify.org; else host=https://api6.ipify.org; fi
  output=$(curl "-$version" --noproxy '*' -fsS --retry 2 --connect-timeout 10 --max-time 20 "$host") ||
    fail "Cannot reach public IPv$version internet. Check your provider/network settings."
  python3 - "$version" "$output" <<'PY'
import ipaddress,sys
try:
    ip=ipaddress.ip_address(sys.argv[2])
    if ip.version!=int(sys.argv[1]) or not ip.is_global: raise ValueError()
except ValueError: sys.exit('No globally routable public IP detected')
print(ip)
PY
}

wan_for() {
  local version=$1 target
  if [[ $version == 4 ]]; then target=1.1.1.1; else target=2606:4700:4700::1111; fi
  ip "-$version" route get "$target" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

check_listeners() {
  local sockets
  sockets=$( { ss -H -lnt 2>/dev/null; ss -H -lnu 2>/dev/null; } || true)
  # Fail for occupied wildcard, all expected VPN DNS endpoints, or local API.
  if printf '%s\n' "$sockets" | awk '{print $4}' | grep -Eq '(^|:|\]):53$'; then
    # resolved's 127.0.0.53:53 stub is safe (all other DNS listeners require review).
    local dns
    dns=$(printf '%s\n' "$sockets" | awk '{print $4}' | grep -E '(^|:|\]):53$' | grep -Ev '^127\.0\.0\.(53|54):53$' || true)
    [[ -z $dns ]] || fail "DNS :53 already in use: $dns"
  fi
  if printf '%s\n' "$sockets" | awk '{print $4}' | grep -Eq '(^|:|\]):4000$'; then
    fail 'Blocky API port 4000 is occupied.'
  fi
  if ss -H -lnu "( sport = :$PORT )" 2>/dev/null | grep -q .; then
    fail "WireGuard UDP port $PORT is already occupied."
  fi
}

blocky_sha() {
  case $(uname -m) in
    x86_64|amd64) BLOCKY_ARCH=x86_64; BLOCKY_SHA=97ae4257e4f2ea7ee4e0622fca152019eb92224d81b41b2549f064e4cef5584e ;;
    aarch64|arm64) BLOCKY_ARCH=arm64; BLOCKY_SHA=9ac70e846f7919632e340607fb73d80a1fe280c9ceb876430d2a7d79743b4aae ;;
    *) fail 'Supported CPU architectures: x86_64 and arm64.' ;;
  esac
}

install_blocky() {
  local tmp archive url entry
  blocky_sha
  tmp=$(mktemp -d /run/wireguard-blocky.XXXXXXXX)
  archive=$tmp/blocky.tar.gz
  url="https://github.com/0xERR0R/blocky/releases/download/$BLOCKY_VERSION/blocky_${BLOCKY_VERSION}_Linux_${BLOCKY_ARCH}.tar.gz"
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$archive" ||
     ! printf '%s  %s\n' "$BLOCKY_SHA" "$archive" | sha256sum -c - >/dev/null; then
    rm -rf -- "$tmp"
    fail 'Pinned Blocky release download/checksum verification failed.'
  fi
  entry=$(tar -tzf "$archive" | grep -Ex '(\./)?blocky' || true)
  [[ -n $entry && $entry != *$'\n'* ]] || { rm -rf -- "$tmp"; fail 'Unexpected Blocky archive layout.'; }
  tar -xOf "$archive" "$entry" > "$tmp/blocky"
  [[ -s $tmp/blocky ]] || { rm -rf -- "$tmp"; fail 'Empty Blocky binary.'; }
  install -o root -g root -m 755 "$tmp/blocky" "$BLOCKY_BIN"
  rm -rf -- "$tmp"
}

install_blocky_unit() {
  getent group blocky >/dev/null || groupadd --system blocky
  id -u blocky >/dev/null 2>&1 || useradd --system --gid blocky --home-dir /nonexistent --shell /usr/sbin/nologin blocky
  install -d -o root -g blocky -m 750 /etc/blocky
  cat > "$BLOCKY_UNIT" <<'UNIT'
[Unit]
Description=Blocky DNS for WireGuard Manager
Wants=network-online.target
After=network-online.target wg-quick@wg0.service
Requires=wg-quick@wg0.service

[Service]
Type=simple
User=blocky
Group=blocky
ExecStartPre=/usr/local/bin/blocky validate --config /etc/blocky/config.yml
ExecStart=/usr/local/bin/blocky --config /etc/blocky/config.yml
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 "$BLOCKY_UNIT"
  systemctl daemon-reload
  systemctl enable blocky.service >/dev/null
}

blocky_defaults() {
  cat <<EOF
# WireGuard Manager v1: private dual-stack DNS. A and AAAA are both enabled.
upstreams:
  groups:
    default:
      - https://cloudflare-dns.com/dns-query
      - https://dns.google/dns-query
  strategy: random
# HTTPS bootstrap: avoid cleartext lookups for DoH upstream/list hosts.
bootstrapDns:
  - upstream: https://cloudflare-dns.com/dns-query
    ips:
      - 1.1.1.1
      - 2606:4700:4700::1111
  - upstream: https://dns.google/dns-query
    ips:
      - 8.8.8.8
      - 2001:4860:4860::8888
connectIPVersion: dual
blocking:
  denylists:
    ads:
      - https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
  clientGroupsBlock:
    default:
      - ads
  loading:
    refreshPeriod: 4h
caching:
  maxItemsCount: 10000
ports:
  dns:
    - "$VPN4_SERVER:53"
    - "[$VPN6_SERVER]:53"
  http: "$API"
statistics:
  enable: true
log:
  level: info
  privacy: true
EOF
}

check_dns() {
  local i
  for (( i=0; i<80; i++ )); do
    if systemctl is-active --quiet blocky.service &&
       dig +time=2 +tries=1 +short @"$VPN4_SERVER" example.com A | grep -Eq '^[0-9]+\.' &&
       dig -6 +time=2 +tries=1 +short @"$VPN6_SERVER" example.com AAAA | grep -Eq '^[0-9a-fA-F:]+$'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

reset_dns() {
  load_network
  [[ -x $BLOCKY_BIN && -f $BLOCKY_UNIT ]] || fail 'Blocky is not installed.'
  local temp backup='' previous=0
  temp=$(mktemp /etc/blocky/.config.XXXXXXXX)
  blocky_defaults > "$temp"
  chown root:blocky "$temp"
  chmod 640 "$temp"
  if ! "$BLOCKY_BIN" validate --config "$temp"; then
    rm -f "$temp"; fail 'Blocky YAML validation failed; existing config preserved.'
  fi
  if [[ -f $BLOCKY_CONF ]]; then
    backup=$(mktemp /etc/blocky/.backup.XXXXXXXX)
    cp -p -- "$BLOCKY_CONF" "$backup"
    systemctl is-active --quiet blocky.service && previous=1 || true
  fi
  mv -f -- "$temp" "$BLOCKY_CONF"
  if ! systemctl restart blocky.service || ! check_dns; then
    warn 'Blocky did not pass IPv4 + IPv6 DNS tests. Rolling back DNS settings.'
    journalctl -u blocky.service --no-pager -n 20 || true
    if [[ -n $backup ]]; then cp -p -- "$backup" "$BLOCKY_CONF"; else rm -f -- "$BLOCKY_CONF"; fi
    if (( previous )); then systemctl restart blocky.service || true; else systemctl stop blocky.service || true; fi
    [[ -z $backup ]] || rm -f "$backup"
    fail 'DNS config was not applied.'
  fi
  [[ -z $backup ]] || rm -f "$backup"
  say "Blocky is resolving A and AAAA over both WireGuard DNS addresses"
}

# IPv4 and IPv6 NAT/port-53 DNS redirection are loaded on boot by UFW.
write_ufw_nat() {
  local rules4=$1 rules6=$2 out4=$3 out6=$4
  {
    printf '# WireGuard Manager v1 IPv4 NAT + DNS enforcement\n'
    printf '*nat\n:PREROUTING ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\n'
    for proto in udp tcp; do
      printf -- '-A PREROUTING -i wg0 -s %s -p %s --dport 53 -j DNAT --to-destination %s\n' "$VPN4_NET" "$proto" "$VPN4_SERVER"
    done
    printf -- '-A POSTROUTING -s %s -o %s -j MASQUERADE\nCOMMIT\n\n' "$VPN4_NET" "$out4"
  } > "$rules4"
  {
    printf '# WireGuard Manager v1 IPv6 NAT66 + DNS enforcement\n'
    printf '*nat\n:PREROUTING ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\n'
    for proto in udp tcp; do
      printf -- '-A PREROUTING -i wg0 -s %s -p %s --dport 53 -j DNAT --to-destination %s\n' "$VPN6_NET" "$proto" "$VPN6_SERVER"
    done
    printf -- '-A POSTROUTING -s %s -o %s -j MASQUERADE\nCOMMIT\n\n' "$VPN6_NET" "$out6"
  } > "$rules6"
}

prepare_ufw() {
  local tmp4 tmp6
  [[ -f /etc/ufw/before.rules && -f /etc/ufw/before6.rules ]] || fail 'Missing UFW base rules.'
  [[ -f /etc/default/ufw ]] || fail 'Missing /etc/default/ufw.'
  grep -q '^IPV6=' /etc/default/ufw || fail 'Missing UFW IPV6 option.'
  if grep -qE '^\*(nat|mangle|raw)' /etc/ufw/before.rules /etc/ufw/before6.rules; then
    fail 'Custom UFW NAT/mangle/raw table detected; refusing to overwrite.'
  fi
  tmp4=$(mktemp /etc/ufw/.rules4.XXXXXXXX)
  tmp6=$(mktemp /etc/ufw/.rules6.XXXXXXXX)
  write_ufw_nat "$tmp4" "$tmp6" "$WAN4" "$WAN6"
  # Syntax-test both family NAT fragments before changing the host firewall.
  if ! iptables-restore --test < "$tmp4" || ! ip6tables-restore --test < "$tmp6"; then
    rm -f "$tmp4" "$tmp6"; fail 'IPv4/IPv6 NAT rules unsupported by kernel; firewall untouched.'
  fi
  cat /etc/ufw/before.rules >> "$tmp4"
  cat /etc/ufw/before6.rules >> "$tmp6"
  cp -p /etc/ufw/before.rules /etc/ufw/before.rules.wgm-v1.bak
  cp -p /etc/ufw/before6.rules /etc/ufw/before6.rules.wgm-v1.bak
  cp -p /etc/default/ufw /etc/default/ufw.wgm-v1.bak
  chmod 644 "$tmp4" "$tmp6"
  mv -f "$tmp4" /etc/ufw/before.rules
  mv -f "$tmp6" /etc/ufw/before6.rules
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
}

configure_ufw() {
  local sshport=$1
  prepare_ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed
  ufw allow "$sshport/tcp" comment 'SSH'
  ufw allow "$PORT/udp" comment 'WireGuard dual-stack'
  ufw allow in on wg0 from "$VPN4_NET" to "$VPN4_SERVER" port 53 proto udp comment 'Blocky IPv4'
  ufw allow in on wg0 from "$VPN4_NET" to "$VPN4_SERVER" port 53 proto tcp comment 'Blocky IPv4'
  ufw allow in on wg0 from "$VPN6_NET" to "$VPN6_SERVER" port 53 proto udp comment 'Blocky IPv6'
  ufw allow in on wg0 from "$VPN6_NET" to "$VPN6_SERVER" port 53 proto tcp comment 'Blocky IPv6'
  ufw route allow in on wg0 out on wg0 from "$VPN4_NET" to "$VPN4_NET" comment 'VPN IPv4 peers'
  ufw route allow in on wg0 out on wg0 from "$VPN6_NET" to "$VPN6_NET" comment 'VPN IPv6 peers'
  # These deny rules MUST precede broad routed internet allows (UFW first-match).
  # Clients can still use custom DoH over TCP/443 inside the encrypted tunnel.
  ufw route deny in on wg0 out on "$WAN4" from "$VPN4_NET" to any port 853 proto tcp comment 'Block external DoT IPv4'
  ufw route deny in on wg0 out on "$WAN4" from "$VPN4_NET" to any port 853 proto udp comment 'Block external DoQ IPv4'
  ufw route deny in on wg0 out on "$WAN6" from "$VPN6_NET" to any port 853 proto tcp comment 'Block external DoT IPv6'
  ufw route deny in on wg0 out on "$WAN6" from "$VPN6_NET" to any port 853 proto udp comment 'Block external DoQ IPv6'
  ufw route allow in on wg0 out on "$WAN4" from "$VPN4_NET" comment 'VPN IPv4 internet'
  ufw route allow in on wg0 out on "$WAN6" from "$VPN6_NET" comment 'VPN IPv6 internet'
  ufw --force enable
  [[ $(ufw status | head -n 1) == 'Status: active' ]] || fail 'UFW is not active.'
  [[ $(sysctl -n net.ipv4.ip_forward) == 1 && $(sysctl -n net.ipv6.conf.all.forwarding) == 1 ]] ||
    fail 'UFW changed IP forwarding state; review /etc/ufw/sysctl.conf.'
}

# Preserve provider router advertisements if the IPv6 default route comes from RA.
set_forwarding() {
  local ra=0
  if ip -6 route show default | grep -q 'proto ra'; then ra=1; fi
  {
    printf '# WireGuard Manager v1: IPv4 + IPv6 forwarding\n'
    printf 'net.ipv4.ip_forward = 1\n'
    printf 'net.ipv6.conf.all.forwarding = 1\n'
    printf 'net.ipv6.conf.default.forwarding = 1\n'
    if (( ra )); then
      printf 'net.ipv6.conf.%s.accept_ra = 2\n' "$WAN6"
    fi
  } > /etc/sysctl.d/99-wireguard-manager.conf
  if (( ra )); then sysctl -w "net.ipv6.conf.$WAN6.accept_ra=2" >/dev/null; fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
  sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null
  [[ $(sysctl -n net.ipv6.conf.all.forwarding) == 1 ]] || fail 'IPv6 forwarding not enabled.'
  check_ipv6
  public_ip 6 >/dev/null || fail 'IPv6 connectivity failed after enabling forwarding.'
}

# Ubuntu 26.04 may confine wg-quick's ip(8) child; adjust that one permission only.
fix_wg_apparmor() {
  local profile=/etc/apparmor.d/wg-quick original result
  [[ -f $profile ]] && command -v apparmor_parser >/dev/null 2>&1 || return 0
  original=$(mktemp /etc/apparmor.d/.wg-quick-v1.XXXXXXXX)
  cp -p "$profile" "$original"
  if ! result=$(python3 - "$profile" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); txt=p.read_text()
ms=list(re.finditer(r'(?m)^([ \t]*)profile[ \t]+ip\b[^\n{]*\{',txt))
if len(ms)!=1: sys.exit('Cannot safely locate wg-quick ip child profile')
m=ms[0]; depth=1
for i in range(m.end(),len(txt)):
    if txt[i]=='{': depth+=1
    elif txt[i]=='}': depth-=1
    if depth==0: break
else: sys.exit('Unclosed child profile')
if re.search(r'(?m)^\s*capability\s+net_bind_service\s*,',txt[m.end():i]):
    print('unchanged');sys.exit(0)
p.write_text(txt[:m.end()]+'\n'+m.group(1)+'  capability net_bind_service,\n'+txt[m.end():])
print('changed')
PY
); then
    cp -p "$original" "$profile"; rm -f "$original"
    warn 'Unable to safely adjust wg-quick AppArmor profile.'; return 1
  fi
  if [[ $result == changed ]]; then
    if ! apparmor_parser -r "$profile"; then
      cp -p "$original" "$profile"; apparmor_parser -r "$profile" || true
      rm -f "$original"; warn 'AppArmor reload failed; profile restored.'; return 1
    fi
    cp -p "$original" "${profile}.wgm-v1.bak" || true
  fi
  rm -f "$original"
}

install_server() {
  [[ -r /etc/os-release ]] || fail 'Cannot identify this OS.'
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.04 ]] || fail 'Requires fresh Ubuntu Server 26.04 LTS.'
  check_ipv6
  [[ ! -e $WG_CONF && ! -e $MANAGER && ! -e $BLOCKY_CONF && ! -e $BLOCKY_BIN &&
     ! -e $BLOCKY_UNIT && ! -e /etc/sysctl.d/99-wireguard-manager.conf ]] ||
    fail 'An existing VPN/Blocky/manager is detected; v1 installs on a fresh VPS only.'
  if compgen -G '/etc/wireguard/*.conf' >/dev/null; then fail 'Existing WireGuard config detected.'; fi
  if command -v wg >/dev/null && [[ -n $(wg show interfaces 2>/dev/null) ]]; then fail 'Active WireGuard interface detected.'; fi
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    fail 'UFW is already active. This installer does not replace existing firewalls.'
  fi
  local sshport=22 input ipv4net=10.66.66.0/24 v6net ipv4pub ipv6pub
  if [[ -n ${SSH_CONNECTION:-} ]]; then sshport=${SSH_CONNECTION##* }; fi
  printf 'SSH port to preserve [%s]: ' "$sshport"
  read -r input
  sshport=${input:-$sshport}
  [[ $sshport =~ ^[0-9]+$ ]] && (( 10#$sshport >= 1 && 10#$sshport <= 65535 )) || fail 'Invalid SSH port.'
  printf 'VPN IPv4 subnet [10.66.66.0/24]: '
  read -r input
  ipv4net=${input:-$ipv4net}
  validate_ipv4_subnet "$ipv4net"
  check_route_overlap 4 "$ipv4net"
  v6net=$(random_ula)
  check_route_overlap 6 "$v6net"
  VPN4_NET=$ipv4net
  VPN4_PREFIX=${ipv4net%.0/24}
  VPN4_SERVER=$VPN4_PREFIX.1
  VPN6_NET=$v6net
  VPN6_PREFIX=${v6net%::/64}
  VPN6_SERVER=$VPN6_PREFIX::1
  WAN4=$(wan_for 4)
  WAN6=$(wan_for 6)
  [[ $WAN4 =~ ^[a-zA-Z0-9_-]{1,15}$ && -d /sys/class/net/$WAN4 ]] || fail 'Cannot detect IPv4 WAN interface.'
  [[ $WAN6 =~ ^[a-zA-Z0-9_-]{1,15}$ && -d /sys/class/net/$WAN6 ]] || fail 'Cannot detect IPv6 WAN interface.'
  ipv4pub=$(public_ip 4)
  ipv6pub=$(public_ip 6)
  cat <<INFO

WireGuard Manager v1 -- fresh dual-stack installation
  IPv4 VPN:       $VPN4_NET (DNS: $VPN4_SERVER)
  IPv6 VPN:       $VPN6_NET (DNS: $VPN6_SERVER)
  Public IPv4:    $ipv4pub (WAN $WAN4)
  Public IPv6:    $ipv6pub (WAN $WAN6)
  SSH:            TCP $sshport
  WireGuard:      UDP $PORT (IPv4 and IPv6)
  Firewall:       UFW IPv4+IPv6 with IPv4 NAT and IPv6 NAT66
  DNS:            Private Blocky A+AAAA with DoH upstreams

Open TCP $sshport and UDP $PORT in the VPS provider firewall for both
IP families. Keep an SSH session and provider console open.
INFO
  printf 'Type INSTALL to continue: '
  read -r input
  [[ $input == INSTALL ]] || { printf 'Cancelled.\n'; return 0; }

  say 'Installing packages'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y wireguard-tools ufw iptables curl ca-certificates python3 qrencode dnsutils apparmor-utils util-linux
  check_listeners
  say 'Downloading checksum-pinned Blocky'
  install_blocky

  say 'Creating dual-stack WireGuard interface'
  install -d -m 700 "$WG_DIR" "$CLIENT_DIR"
  printf '%s\n' "$ipv4pub" > "$WG_DIR/public-ipv4"
  printf '%s\n' "$ipv6pub" > "$WG_DIR/public-ipv6"
  wg genkey > "$WG_DIR/server.key"
  wg pubkey < "$WG_DIR/server.key" > "$WG_DIR/server.pub"
  cat > "$WG_CONF" <<EOF
# WireGuard Manager v1 -- use this manager to add/remove peers.
[Interface]
Address = $VPN4_SERVER/24, $VPN6_SERVER/64
ListenPort = $PORT
PrivateKey = $(cat "$WG_DIR/server.key")
EOF
  chmod 600 "$WG_CONF" "$WG_DIR/server.key" "$WG_DIR/server.pub" "$WG_DIR/public-ipv4" "$WG_DIR/public-ipv6"
  say 'Enabling IPv4 and IPv6 forwarding'
  set_forwarding
  say 'Configuring dual-stack UFW and DNS enforcement'
  configure_ufw "$sshport"

  say 'Starting WireGuard'
  fix_wg_apparmor || warn 'AppArmor preflight could not be applied; trying normal WireGuard startup.'
  systemctl enable wg-quick@wg0.service >/dev/null
  if ! systemctl start wg-quick@wg0.service; then
    journalctl -u wg-quick@wg0.service -n 25 --no-pager || true
    fail 'WireGuard failed to start. Inspect AppArmor and wg-quick logs.'
  fi
  install_blocky_unit
  reset_dns
  install -m 700 "${BASH_SOURCE[0]}" "$MANAGER"
  say 'Dual-stack WireGuard Manager v1 installed'
  printf 'Add a device: sudo wireguard-manager add phone full\n'
  printf 'Check: sudo wireguard-manager status\n'
}

sync_peers() {
  local tmp
  tmp=$(mktemp "$WG_DIR/.sync.XXXXXXXX")
  if wg-quick strip wg0 > "$tmp" && wg syncconf wg0 "$tmp"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

next_host() {
  local n addr
  local -A used=()
  while IFS= read -r addr; do
    if [[ $addr =~ ^AllowedIPs[[:space:]]*=[[:space:]]*([^,[:space:]]+)/32, ]]; then
      used[${BASH_REMATCH[1]}]=1
    fi
  done < "$WG_CONF"
  for ((n=2;n<=254;n++)); do
    [[ -n ${used[$VPN4_PREFIX.$n]:-} ]] || { printf '%s' "$n"; return 0; }
  done
  return 1
}

add_device() {
  load_network
  systemctl is-active --quiet wg-quick@wg0 || fail 'WireGuard is not running.'
  local name=${1:-} mode=${2:-} family=${3:-ipv4} n ip4 ip6 routes dns endpoint pub backup
  if [[ -z $name ]]; then printf 'Device name: '; read -r name; fi
  valid_name "$name" || fail 'Use a lowercase device name (letters, digits, - or _; max 32).'
  [[ ! -e $CLIENT_DIR/$name.conf && ! -e $CLIENT_DIR/$name.key && ! -e $CLIENT_DIR/$name.pub ]] || fail 'Device already exists.'
  if [[ -z $mode ]]; then printf 'Mode [full/private]: '; read -r mode; fi
  case $mode in
    full) routes='0.0.0.0/0, ::/0'; dns="DNS = $VPN4_SERVER, $VPN6_SERVER" ;;
    private) routes="$VPN4_NET, $VPN6_NET"; dns='' ;;
    *) fail 'Mode must be full or private.' ;;
  esac
  case $family in
    ipv4) endpoint="$(< "$WG_DIR/public-ipv4"):$PORT" ;;
    ipv6) endpoint="[$(< "$WG_DIR/public-ipv6")]:$PORT" ;;
    *) fail 'Endpoint family must be ipv4 or ipv6.' ;;
  esac
  n=$(next_host) || fail 'VPN is full (253 devices maximum).'
  ip4=$VPN4_PREFIX.$n
  ip6=$VPN6_PREFIX::$n
  if ! wg genkey > "$CLIENT_DIR/$name.key" ||
     ! wg pubkey < "$CLIENT_DIR/$name.key" > "$CLIENT_DIR/$name.pub"; then
    rm -f "$CLIENT_DIR/$name.key" "$CLIENT_DIR/$name.pub"
    fail 'Could not create peer keys.'
  fi
  pub=$(< "$CLIENT_DIR/$name.pub")
  cat > "$CLIENT_DIR/$name.conf" <<EOF
# WireGuard Manager v1
# Device: $name
# Mode: $mode
[Interface]
PrivateKey = $(< "$CLIENT_DIR/$name.key")
Address = $ip4/32, $ip6/128
EOF
  [[ -z $dns ]] || printf '%s\n' "$dns" >> "$CLIENT_DIR/$name.conf"
  cat >> "$CLIENT_DIR/$name.conf" <<EOF

[Peer]
PublicKey = $(< "$WG_DIR/server.pub")
Endpoint = $endpoint
AllowedIPs = $routes
PersistentKeepalive = 25
EOF
  chmod 600 "$CLIENT_DIR/$name.conf" "$CLIENT_DIR/$name.key" "$CLIENT_DIR/$name.pub"
  backup=$(mktemp "$WG_DIR/.backup.XXXXXXXX")
  cp -p "$WG_CONF" "$backup"
  cat >> "$WG_CONF" <<EOF

# BEGIN_DEVICE $name
[Peer]
PublicKey = $pub
AllowedIPs = $ip4/32, $ip6/128
# END_DEVICE $name
EOF
  if ! sync_peers; then
    cp -p "$backup" "$WG_CONF"
    sync_peers || true
    rm -f "$backup" "$CLIENT_DIR/$name.conf" "$CLIENT_DIR/$name.key" "$CLIENT_DIR/$name.pub"
    fail 'Live peer update failed and was rolled back.'
  fi
  rm -f "$backup"
  say "Added $name ($mode, $ip4 + $ip6, $family endpoint)"
  printf 'Profile: %s\nQR code: sudo wireguard-manager qr %s\n' "$CLIENT_DIR/$name.conf" "$name"
  warn 'Protect the profile/QR: it contains a private key.'
  [[ $mode != full ]] || warn 'Enable the OS always-on VPN / block-without-VPN setting to stop traffic if the tunnel disconnects.'
}

list_devices() {
  load_network
  local file name address mode found=0
  printf '\n%-20s %-48s %s\n' DEVICE 'IPv4, IPv6' MODE
  for file in "$CLIENT_DIR"/*.conf; do
    [[ -f $file ]] || continue
    name=${file##*/}; name=${name%.conf}
    address=$(sed -n 's/^Address = //p' "$file" | head -n 1)
    mode=$(sed -n 's/^# Mode: //p' "$file" | head -n 1)
    printf '%-20s %-48s %s\n' "$name" "$address" "$mode"
    ((found+=1))
  done
  (( found )) || printf '(no devices)\n'
}

remove_device() {
  load_network
  systemctl is-active --quiet wg-quick@wg0 || fail 'WireGuard is not running.'
  local name=${1:-} answer backup staged
  if [[ -z $name ]]; then list_devices; printf 'Device to remove: '; read -r name; fi
  valid_name "$name" || fail 'Invalid device name.'
  [[ -f $CLIENT_DIR/$name.conf ]] || fail 'Device not found.'
  grep -Fqx "# BEGIN_DEVICE $name" "$WG_CONF" &&
    grep -Fqx "# END_DEVICE $name" "$WG_CONF" || fail 'Peer marker missing; refusing unsafe edit.'
  printf 'Type REMOVE to revoke %s: ' "$name"; read -r answer
  [[ $answer == REMOVE ]] || { printf 'Cancelled.\n'; return 0; }
  backup=$(mktemp "$WG_DIR/.backup.XXXXXXXX")
  staged=$(mktemp "$WG_DIR/.edit.XXXXXXXX")
  cp -p "$WG_CONF" "$backup"
  awk -v b="# BEGIN_DEVICE $name" -v e="# END_DEVICE $name" '
    $0==b {skip=1;next} $0==e && skip {skip=0;next} !skip{print}
  ' "$WG_CONF" > "$staged"
  chmod 600 "$staged"
  mv "$staged" "$WG_CONF"
  if ! sync_peers; then
    cp -p "$backup" "$WG_CONF"
    sync_peers || true
    rm -f "$backup"; fail 'Live peer revoke failed; restored previous config.'
  fi
  rm -f "$backup" "$CLIENT_DIR/$name.conf" "$CLIENT_DIR/$name.key" "$CLIENT_DIR/$name.pub"
  say "Revoked $name"
}

show_qr() {
  load_network
  local name=${1:-}
  if [[ -z $name ]]; then list_devices; printf 'Device: '; read -r name; fi
  valid_name "$name" || fail 'Invalid name.'
  [[ -f $CLIENT_DIR/$name.conf ]] || fail 'No such device.'
  warn 'This QR code reveals the private WireGuard key. Do not publish or screenshot it.'
  qrencode -t ansiutf8 < "$CLIENT_DIR/$name.conf"
}

status() {
  load_network
  say 'Dual-stack WireGuard Manager v1'
  printf 'VPN IPv4: %s | VPN IPv6: %s\n' "$VPN4_NET" "$VPN6_NET"
  printf 'Public IPv4 endpoint: %s:%s\n' "$(< "$WG_DIR/public-ipv4")" "$PORT"
  printf 'Public IPv6 endpoint: [%s]:%s\n' "$(< "$WG_DIR/public-ipv6")" "$PORT"
  printf 'IPv4 forwarding: %s | IPv6 forwarding: %s\n' "$(sysctl -n net.ipv4.ip_forward)" "$(sysctl -n net.ipv6.conf.all.forwarding)"
  systemctl --no-pager --plain is-active wg-quick@wg0 blocky.service || true
  if [[ $(< /proc/sys/net/ipv6/conf/all/disable_ipv6) != 0 ]]; then warn 'IPv6 is disabled; this is not a working dual-stack VPN.'; fi
  wg show || true
  say 'DNS via private IPv4 and IPv6 listeners'
  if dig +time=3 +tries=1 +short @"$VPN4_SERVER" example.com A | grep -Eq '^[0-9]+\.'; then
    printf 'IPv4 DNS A: OK\n'; else warn 'IPv4 Blocky DNS failed.'; fi
  if dig -6 +time=3 +tries=1 +short @"$VPN6_SERVER" example.com AAAA | grep -Eq '^[0-9a-fA-F:]+$'; then
    printf 'IPv6 DNS AAAA: OK\n'; else warn 'IPv6 Blocky DNS failed.'; fi
  if curl -4 --noproxy '*' -fsS --max-time 3 "http://$API/api/blocking/status" >/dev/null; then
    printf 'Blocky management API: local-only OK\n'; else warn 'Blocky local API failed.'; fi
  say 'Firewall'
  ufw status verbose || true
  printf '\nNAT is in /etc/ufw/before.rules and before6.rules; UFW status does not show it.\n'
  iptables -t nat -S POSTROUTING | grep -F "$VPN4_NET" || warn 'IPv4 NAT rule missing.'
  ip6tables -t nat -S POSTROUTING | grep -F "$VPN6_NET" || warn 'IPv6 NAT66 rule missing.'
  printf 'Client IP/DNS leak tests are required; see README.md.\n'
}

menu() {
  local opt name mode family
  while true; do
    printf '\n=== WireGuard Manager v1 (IPv4 + IPv6) ===\n'
    printf '1) Install  2) Add device  3) Remove device  4) List devices\n'
    printf '5) Device QR  6) Status  7) Reset Blocky DNS  8) Exit\nChoice: '
    read -r opt || break
    case $opt in
      1) install_server ;;
      2) printf 'Device name: '; read -r name; printf 'Mode [full/private]: '; read -r mode
         printf 'Endpoint family [ipv4/ipv6, default ipv4]: '; read -r family
         add_device "$name" "$mode" "${family:-ipv4}" ;;
      3) remove_device ;;
      4) list_devices ;;
      5) show_qr ;;
      6) status ;;
      7) reset_dns ;;
      8) break ;;
      *) warn 'Select 1-8.' ;;
    esac
  done
}

main() {
  case ${1:-} in
    version|--version) printf 'wireguard-manager %s (IPv4 + IPv6; Blocky %s)\n' "$VERSION" "$BLOCKY_VERSION"; return 0 ;;
    help|--help) printf 'Usage: sudo wireguard-manager [install|add NAME full|private [ipv4|ipv6]|remove NAME|list|qr NAME|status|dns|version]\n'; return 0 ;;
  esac
  root_only
  exec 9>/run/lock/wireguard-manager.lock
  flock -n 9 || fail 'Another manager process is running.'
  case ${1:-menu} in
    install) install_server ;;
    add) add_device "${2:-}" "${3:-}" "${4:-ipv4}" ;;
    remove) remove_device "${2:-}" ;;
    list) list_devices ;;
    qr) show_qr "${2:-}" ;;
    status) status ;;
    dns) reset_dns ;;
    menu) menu ;;
    *) fail 'Unknown command. Run wireguard-manager --help.' ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
