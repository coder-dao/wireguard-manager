# WireGuard Manager

**A private IPv4 + IPv6 WireGuard VPN with ad-blocking Blocky DNS for Ubuntu Server 26.04 LTS.**

Simple interactive menus for adding devices, checking your VPN, and getting each device's WireGuard configuration. **Phones can scan a QR code; computers and routers can import a `.conf` file or copy/paste the plain-text configuration.** Command-line options are also available for scripting or experienced users.

> **Fresh VPS installations only.** Requires working public IPv4 **and** IPv6. No migration or automated update command is included.

## 1. Requirements

- A **fresh Ubuntu Server 26.04 LTS VPS** (x86_64 or arm64) with working public IPv4 and IPv6.
- SSH access with `sudo`, plus access to the provider's rescue/console screen in case firewall settings block SSH.
- Provider firewall allowing your **SSH TCP port** and **UDP 443** for both IPv4 and IPv6. Keep public **TCP/UDP 53 closed**.
- No existing WireGuard, Blocky, active UFW, or custom UFW NAT setup.

Check IPv4 and IPv6 **on the VPS before installing**:

```bash
ip -6 route
curl -4fsS https://api.ipify.org; echo
curl -6fsS https://api6.ipify.org; echo
```

Both `curl` commands must show public IPs. If IPv6 fails, configure its public address and default route with your VPS provider first. **Do not disable IPv6:** installation deliberately rejects IPv4-only servers.

## 2. Install

**Option A — download the script onto the VPS** (after the updated script has been pushed to your repository's `main` branch):

```bash
ssh ubuntu@YOUR_VPS_IP
curl -fsSLo wireguard-manager.sh https://raw.githubusercontent.com/coder-dao/wireguard-manager/refs/heads/main/wireguard-manager.sh
sudo bash wireguard-manager.sh install
```

**Option B — upload the updated script from your computer:**

```bash
scp wireguard-manager.sh ubuntu@YOUR_VPS_IP:/home/ubuntu/
ssh ubuntu@YOUR_VPS_IP
sudo bash wireguard-manager.sh install
```

Replace `ubuntu` and `YOUR_VPS_IP` with your SSH username and VPS address. Confirm the SSH port and VPN IPv4 subnet (default `10.66.66.0/24`), then type `INSTALL` when the installer shows its summary.

The installer sets up WireGuard on UDP 443, a private IPv6 `/64`, IPv4 NAT, IPv6 NAT66, UFW, and private dual-stack Blocky DNS. **Keep your SSH session and provider console available** while UFW is enabled. If installation fails after firewall changes, inspect the VPS from its provider console; do not blindly rerun the installer.

## 3. Open the simple menu

After installation, run:

```bash
sudo wireguard-manager
```

```text
WireGuard Manager  v1.1
Dual-stack IPv4 + IPv6 VPN | Private Blocky DNS
----------------------------------------------------

Devices
  1  Add a new device
  2  List devices
  3  Get device configuration  (QR / copy / file)
  4  Remove a device

Server
  5  Check server status
  6  Reset Blocky DNS to defaults
  7  Install on a fresh VPS

  0  Exit

Your choice [0]:
```

The menu guides you through adding a device, selecting **Full VPN** or **Private network only**, and picking the endpoint family. After adding a device, it offers configuration delivery right away. Colors appear on supported terminals only, and the menu still works over ordinary SSH.

## 4. Get a device's WireGuard configuration

**Use menu option `3` (Get device configuration)** or run:

```bash
sudo wireguard-manager get laptop
```

```text
Get configuration: laptop
  1  Show QR code          Phone or tablet camera
  2  Show configuration   Copy/paste into a WireGuard client or router
  3  Save .conf file      Import on a computer or router
  0  Back
Choose how to get the profile [3]:
```

Your device's profile is always stored securely on the VPS in `/etc/wireguard/clients/DEVICE.conf`. The commands below let you retrieve it in a useful format without changing the profile or generating a new private key.

### Phone or tablet: scan a QR code

```bash
sudo wireguard-manager add phone full
sudo wireguard-manager qr phone
```

Open the official WireGuard app on the phone, add a tunnel, and scan the code displayed on your **private** terminal. QR scanning is convenient for devices with cameras; computers and routers should normally use one of the next two methods.

### Windows, macOS or Linux computer: export a `.conf` file

On the **VPS**, while logged in as your usual SSH user (for example, `ubuntu`):

```bash
sudo wireguard-manager add laptop full
sudo wireguard-manager export laptop
```

This writes `laptop.conf` into the **current working directory on the VPS**. You can also specify a full destination path:

```bash
sudo wireguard-manager export laptop /home/ubuntu/laptop.conf
```

From a **terminal on your own computer** (not the VPS), securely copy that file:

```bash
scp ubuntu@YOUR_VPS_IP:/home/ubuntu/laptop.conf .
```

Then open the WireGuard app on your computer, choose the option to **import a tunnel from a file**, select `laptop.conf`, and activate it. In Linux, `wg-quick` can also load a `.conf` profile; see the official documentation linked below.

**Export safeguards:** Files are created with mode `600` (owner only), owned by the invoking `sudo` user when available, and never overwrite an existing file or symlink. If a path already exists, choose a new one or delete the old copy deliberately. Avoid exporting into Git repositories, shared directories, or cloud-sync folders. You can remove the extra file on the VPS after successfully importing it; the original profile under `/etc/wireguard/clients/` remains intact.

### Router or other device: copy/paste the full configuration

```bash
sudo wireguard-manager add home-router full
sudo wireguard-manager config home-router
```

The `config` command prints the **complete, plain-text WireGuard profile**, including `[Interface]` and `[Peer]`, without a decorative banner or terminal color codes. Copy it into a router's WireGuard configuration/import screen if that firmware accepts this format. Alternatively, use `export` and import the `.conf` file. Router interfaces vary; some require individual fields instead of a complete pasted profile.

**Important:** The `config` output contains the device's _private key_. Do not post it in support forums, screenshots, issue reports, or chat messages. Avoid recording or logging your terminal when showing it. For a file, prefer `export` rather than shell redirection so owner-only file permissions are guaranteed.

## 5. Everyday commands

| What you want                     | Command                                                         |
| --------------------------------- | --------------------------------------------------------------- |
| Open the guided menu              | `sudo wireguard-manager`                                        |
| Add a full-tunnel device          | `sudo wireguard-manager add laptop full`                        |
| Add a private-only device         | `sudo wireguard-manager add pi private`                         |
| Use an IPv6 server endpoint       | `sudo wireguard-manager add tablet full ipv6`                   |
| List devices and VPN IP addresses | `sudo wireguard-manager list`                                   |
| Choose QR / copy / file           | `sudo wireguard-manager get laptop`                             |
| Copy/paste full configuration     | `sudo wireguard-manager config laptop`                          |
| Export owner-only `.conf` file    | `sudo wireguard-manager export laptop`                          |
| Export to a specific file         | `sudo wireguard-manager export laptop /home/ubuntu/laptop.conf` |
| Show a device QR code             | `sudo wireguard-manager qr phone`                               |
| Remove/revoke a device            | `sudo wireguard-manager remove laptop`                          |
| Check VPN, DNS and firewall       | `sudo wireguard-manager status`                                 |
| Reset Blocky DNS settings         | `sudo wireguard-manager dns`                                    |
| Show friendly command help        | `wireguard-manager --help`                                      |
| Show version                      | `wireguard-manager --version`                                   |

### Full VPN vs private-only

**Full VPN (`full`)** routes all ordinary IPv4, IPv6 and DNS traffic through the VPN. Its generated configuration contains:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

**Private-only (`private`)** allows access to your VPN's IPv4 and IPv6 addresses while regular internet traffic and DNS remain on the device's normal network.

By default, the **server endpoint uses public IPv4**, even though _both IPv4 and IPv6_ travel through the tunnel. Use `ipv6` as the last argument only when the device's network can reach the VPS over IPv6.

**Android:** For better disconnect protection, enable **Always-on VPN** and **Block connections without VPN** in system VPN settings. To use Blocky rather than another DNS provider, turn off Android **Private DNS** and browser **Secure DNS** overrides where applicable. Other platforms need an equivalent tested kill switch. A `full` profile alone **is not** a kill switch.

## 6. Check VPN, IPv6 and DNS health

On the **VPS**:

```bash
sudo wireguard-manager status
sudo wg show
sudo systemctl is-active wg-quick@wg0 blocky
sudo journalctl -u wg-quick@wg0 -u blocky -n 50 --no-pager
sudo ufw status verbose
sudo iptables -t nat -S POSTROUTING
sudo ip6tables -t nat -S POSTROUTING
```

UFW's `status` does **not** show custom NAT rules. To check forced DNS redirection, inspect `PREROUTING` in the IPv4 and IPv6 NAT tables as well. The `dns` action resets `/etc/blocky/config.yml` (including custom edits), **not** client profiles or the VPS system resolver.

**On a connected device using a `full` profile (not on the VPS):**

1. Visit [IPLeak.net](https://ipleak.net/) or [Test-IPv6.com](https://test-ipv6.com/). Both public IPv4 and IPv6 should belong to your VPS, not your local ISP.
2. Run the **Extended test** at [DNSLeakTest.com](https://www.dnsleaktest.com/) or [BrowserLeaks DNS](https://browserleaks.com/dns). Your ISP's resolver should not appear. Cloudflare or Google may appear because Blocky uses them as upstream resolvers.
3. If `dig` is installed on the device, run `dig @YOUR_VPN_IPV4_DNS example.com A` and `dig -6 @YOUR_VPN_IPV6_DNS example.com AAAA`. The DNS server IPs are inside the generated full profile.
4. With your **client kill switch enabled**, disconnect WireGuard: internet access should stop. Reconnect and repeat the checks on Wi-Fi and mobile data where possible.

Browser- or app-specific DNS-over-HTTPS can bypass **Blocky filtering**, though it normally still travels inside an active full tunnel. Leak-check sites are helpful indicators, not proof that every app is leak-free.

## 7. Troubleshooting

| Problem                       | What to check                                                                                                               |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| IPv6 doesn't work             | VPS public IPv6 and default route; `curl -6fsS https://api6.ipify.org`                                                      |
| No WireGuard handshake        | VPS provider firewall **UDP 443**, IPv4/IPv6 endpoint reachability, `sudo wg show`                                          |
| DNS doesn't work              | `sudo wireguard-manager status` and `sudo journalctl -u blocky -n 80 --no-pager`                                            |
| Locked out after enabling UFW | Provider console; inspect SSH firewall rules and `/etc/ufw/before.rules`, `/etc/ufw/before6.rules`                          |
| DNS bypasses Blocky           | Disable app/browser secure DNS or Android Private DNS overrides as appropriate                                              |
| Cannot download exported file | Save it into your SSH user's accessible home directory, check owner-only permissions, then use `scp` **from your computer** |
| Export says file exists       | Existing files are intentionally protected: use another path or deliberately remove the previous exported copy              |

Profiles in `/etc/wireguard/clients/`, their exported copies, and QR codes **must stay private**. Blocky listens for DNS only on the VPN IPs; its API is local to `127.0.0.1:4000`. IPv6 uses NAT66 and needs a working public IPv6 VPS address, but no delegated prefix. The server's own DNS resolver is unchanged.

## 8. Local tests

From the repository root (Bash and Python 3 are required):

```bash
bash -n wireguard-manager.sh
bash tests/test-v1.sh
```

Local tests cover profile generation, peer management, private file export, and the new CLI. They do **not** replace end-to-end tests on a real VPS and client. There is still no automated update or migration command.

### Official and upstream documentation

[WireGuard installation](https://www.wireguard.com/install/) · [WireGuard quick start](https://www.wireguard.com/quickstart/) · [WireGuard `wg-quick`](https://git.zx2c4.com/wireguard-tools/tree/src/man/wg-quick.8) · [Blocky configuration](https://0xerr0r.github.io/blocky/main/configuration/) · [Ubuntu UFW framework](https://manpages.ubuntu.com/manpages/resolute/man8/ufw-framework.8.html)
