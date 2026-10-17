# WireGuard Manager v1

**A private IPv4 + IPv6 VPN with ad-blocking DNS for Ubuntu Server 26.04 LTS.**

WireGuard protects both IP families; Blocky handles DNS over the VPN. Includes a firewall, device profiles, QR codes, and health checks. **Fresh VPS installations only.**

## 1. Before you start

You need:

- A **fresh Ubuntu 26.04 LTS VPS** (x86_64 or arm64) with **working public IPv4 and IPv6**.
- SSH access with `sudo` and access to your VPS provider's rescue/console screen.
- Provider firewall rules allowing **your SSH TCP port** and **UDP 443**, for **IPv4 and IPv6**. Keep public TCP/UDP **53 closed**.
- No existing WireGuard, Blocky, active UFW, or custom UFW NAT setup. **No upgrade/migration is supported.**

**Do not disable IPv6.** On the VPS, check both connections before installing:

```bash
ip -6 route
curl -4fsS https://api.ipify.org; echo
curl -6fsS https://api6.ipify.org; echo
```

Both `curl` commands must return public IP addresses. If IPv6 fails, enable its public address and default route through your VPS provider first. The installer will refuse an IPv4-only VPS.

## 2. Install

**Option A — download on your VPS** (only after `main` on GitHub contains this new v1 script):

```bash
ssh ubuntu@YOUR_VPS_IP
curl -fsSLo wireguard-manager.sh https://raw.githubusercontent.com/coder-dao/wireguard-manager/main/wireguard-manager.sh
sudo bash wireguard-manager.sh install
```

**Option B — upload the v1 script from your computer:**

```bash
scp wireguard-manager.sh ubuntu@YOUR_VPS_IP:~/
ssh ubuntu@YOUR_VPS_IP
sudo bash ~/wireguard-manager.sh install
```

Replace `ubuntu` and `YOUR_VPS_IP` as needed. Confirm the **SSH port** and **VPN IPv4 subnet** (default `10.66.66.0/24`), then type `INSTALL`.

The installer configures WireGuard on UDP 443, a private IPv6 `/64`, IPv4 NAT and IPv6 NAT66, UFW, and Blocky DNS for both IP families. **Keep your SSH session and provider console available** while UFW is enabled. If installation fails after firewall changes, inspect the VPS from the provider console; do not blindly rerun the installer.

## 3. Add a device

For a phone or computer that routes **all IPv4, IPv6, and normal DNS traffic** through the VPN:

```bash
sudo wireguard-manager add phone full
sudo wireguard-manager qr phone
```

Scan the QR code privately with the official WireGuard app. The generated full profile uses:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

The **default endpoint uses the VPS's public IPv4**, but _both_ IP families travel inside the tunnel. To connect to the VPS over IPv6 instead:

```bash
sudo wireguard-manager add tablet full ipv6
```

For **VPN-device access only**, without tunneling regular internet or DNS:

```bash
sudo wireguard-manager add pi private
```

**Android:** In system VPN settings, enable **Always-on VPN** and **Block connections without VPN** for protection when the tunnel disconnects. To use Blocky rather than another DNS provider, turn off Android **Private DNS** overrides and browser **Secure DNS** overrides. Other operating systems need an equivalent tested kill switch.

## 4. Manage and monitor

| Task                                   | Command                                       |
| -------------------------------------- | --------------------------------------------- |
| Open menu                              | `sudo wireguard-manager`                      |
| Add full-tunnel device                 | `sudo wireguard-manager add phone full`       |
| Add private-only device                | `sudo wireguard-manager add pi private`       |
| Choose IPv6 endpoint                   | `sudo wireguard-manager add tablet full ipv6` |
| List devices and addresses             | `sudo wireguard-manager list`                 |
| Show private QR code                   | `sudo wireguard-manager qr phone`             |
| Remove a device                        | `sudo wireguard-manager remove phone`         |
| Check VPN, IPv4/IPv6 DNS, and firewall | `sudo wireguard-manager status`               |
| Reset Blocky to default settings       | `sudo wireguard-manager dns`                  |
| Show version                           | `wireguard-manager --version`                 |

For a deeper check **on the VPS**:

```bash
sudo wg show                                   # Peers, handshakes, traffic
sudo systemctl is-active wg-quick@wg0 blocky  # Both should be active
sudo journalctl -u wg-quick@wg0 -u blocky -n 50 --no-pager
sudo ufw status verbose
sudo iptables -t nat -S POSTROUTING           # IPv4 NAT
sudo ip6tables -t nat -S POSTROUTING          # IPv6 NAT66
```

UFW's `status` does **not** display custom NAT rules. To inspect DNS redirection, also check `PREROUTING` in the IPv4 and IPv6 NAT tables. `dns` resets `/etc/blocky/config.yml` (including custom edits), not client profiles or the VPS system resolver.

## 5. Check for IP and DNS leaks

**Run these tests on a connected `full` VPN device, not on the VPS:**

1. Open [IPLeak.net](https://ipleak.net/) or [Test-IPv6.com](https://test-ipv6.com/). **Both public IPv4 and IPv6 should belong to your VPS, not your mobile/Wi-Fi ISP.**
2. Run the **Extended test** at [DNSLeakTest.com](https://www.dnsleaktest.com/) (or [BrowserLeaks DNS](https://browserleaks.com/dns)). **Your ISP's DNS should not appear.** Cloudflare/Google may appear because Blocky uses them upstream.
3. If your client has `dig`, test `dig @YOUR_VPN_IPV4_DNS example.com A` and `dig -6 @YOUR_VPN_IPV6_DNS example.com AAAA`. Find both DNS addresses in the generated `full` profile; A and AAAA answers should work.
4. With your **client kill switch enabled**, disconnect WireGuard. Internet access should stop. Reconnect and repeat the tests on Wi-Fi and mobile data.

**Limits:** A full-tunnel profile does not itself provide a kill switch. App/browser-specific DNS-over-HTTPS can bypass **Blocky filtering**, though its traffic normally remains inside an active full tunnel. Leak-test websites are useful checks, not proof that every app is leak-free.

## 6. If something fails

| Problem                    | Check                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------ |
| No IPv6                    | Public IPv6/default route and outbound HTTPS on the VPS; run `curl -6fsS https://api6.ipify.org`       |
| No handshake               | Provider firewall **UDP 443**, endpoint IPv4/IPv6 reachability, `sudo wg show`                         |
| DNS doesn't work           | `sudo wireguard-manager status`; `sudo journalctl -u blocky -n 80 --no-pager`                          |
| Cannot reach VPS after UFW | Use provider console; inspect `/etc/ufw/before.rules`, `/etc/ufw/before6.rules` and SSH firewall rules |
| DNS bypasses Blocky        | Turn off browser Secure DNS and app-specific DoH / Android Private DNS overrides                       |

Keep `.conf` files and QR codes **secret**: they contain client private keys (`/etc/wireguard/clients/`). Blocky DNS listens only on the VPN addresses; its API is local to `127.0.0.1:4000`. This project uses **IPv6 NAT66**, so it needs a working public IPv6 VPS address but not a delegated prefix. The VPS's own DNS resolver is not changed.

### Optional: test the script before deploying

Run from the project directory (Bash + Python 3 required):

```bash
bash -n wireguard-manager.sh
bash tests/test-v1.sh
```

These local tests cannot replace real VPS and client leak testing. v1 does not include an update or migration command.

### Documentation

[WireGuard `wg-quick`](https://git.zx2c4.com/wireguard-tools/tree/src/man/wg-quick.8) · [Blocky configuration](https://0xerr0r.github.io/blocky/main/configuration/) · [Ubuntu UFW rules](https://manpages.ubuntu.com/manpages/resolute/man8/ufw-framework.8.html)
