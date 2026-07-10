# OM5P-AC Radio Setup

Scripts for turning FRC-locked OpenMesh OM5P-AC v2 radios into practice robot
radios: one unlocks the stock FRC firmware and flashes OpenWrt, the other
configures the flashed radio with team-specific networking.

1. **`unlock-and-flash.ps1`** — unlocks the FRC-locked stock firmware and
   flashes stock OpenWrt.
2. **`configure-robot-radio.sh`** — configures a freshly-flashed OpenWrt radio
   with team-specific networking (IP addressing, SSIDs, keys, hostname).

Run them in that order.

---

## 1. `unlock-and-flash.ps1`

Windows PowerShell script (must run as Administrator) that unlocks an
FRC-firmware OM5P-AC v2 and flashes stock OpenWrt onto it. This works on the
radio's FRC firmware regardless of its current state — unconfigured,
configured for competition use, or configured for practice use.

### What the unlock does

Open Mesh's stock firmware only accepts updates that are cryptographically
signed. The `om5p-ac-v2-unlocker` project found a stack-overflow
vulnerability in the U-Boot bootloader's signature-checking code, and built
an exploit that smuggles a custom U-Boot image in as a fake "signature" file.
Once that custom U-Boot runs, it wipes the RSA key check from the
bootloader entirely, permanently unlocking the radio so it will accept any
firmware — like stock OpenWrt — with no signature at all.

You can't brick the radio with this process. Once the unlock succeeds,
power-cycling is always safe, and the radio still accepts firmware normally
going forward — including the original FRC firmware, which can still be
uploaded afterward through the normal FRC Radio Configuration Utility/
tooling and process, even though the radio is now unlocked.

Background and technical details:
- [true-systems/om5p-ac-v2-unlocker wiki](https://github.com/true-systems/om5p-ac-v2-unlocker/wiki)
- ["Free Your Router, Again!" — True Systems blog post](https://blog.true.cz/2017/02/free-your-router-again/)

> **Heads up:** this unlock process can be tricky and temperamental — timing,
> port choice, and power source all matter. It's been tested successfully on
> all 3 radios available to us, but budget extra time and be ready to retry
> a step if the radio doesn't respond as expected.

### Prerequisites

- Windows 11
- PowerShell running **as Administrator**
- [Npcap](https://npcap.com/#download) installed (also bundled with
  Wireshark or the FRC Radio Configuration Utility) — required for
  `ap51-flash` to access the network adapter
- A laptop Ethernet port (Wi-Fi will not work for this)

### Required files (same directory as the script)

- **Unlocker files** — `fwupgrade.cfg` and `fwupgrade.cfg.sig`, both from the
  same release: [om5p-ac-v2-unlocker releases](https://github.com/true-systems/om5p-ac-v2-unlocker/releases)
- **OpenWrt sysupgrade firmware** — download directly from the
  [OpenWrt firmware selector for the OM5P-AC v2](https://firmware-selector.openwrt.org/?target=ath79%2Fgeneric&id=openmesh_om5p-ac-v2),
  under "Sysupgrade" (not "Factory")
- **ap51-flash** — [ap51-flash releases](https://github.com/ap51-flash/ap51-flash/releases),
  the `i686-npcap` Windows build
- **tftpd64.exe** — [PJO2/tftpd64 releases](https://github.com/PJO2/tftpd64/releases/)
  (portable build). Its config file (`Tftpd32.ini`) does **not** need to be
  downloaded — the script generates it automatically with known-working
  settings every time it runs.

The script checks for all of these on startup and refuses to proceed if any
are missing.

> **Note on `fwupgrade.cfg.sig`:** this file is intentionally ~129MB. It is
> not a real cryptographic signature — it's the exploit payload described
> above. Its size is expected and correct; if it's much smaller, you have the
> wrong file.

### Hardware requirements and port identification

The OM5P-AC v2 has two Ethernet ports plus a barrel jack for DC power.

- **Power the radio from the barrel jack**, not a passive PoE injector.
  Passive PoE fed into the closer port interferes with the data path during
  the unlock exploit and will prevent it from working.
- **Use the port closest to the barrel jack** for both the unlock phase and
  the flash phase. This is the same physical connection for the whole
  process — you do not need to move the cable between phases.
- The other port (farthest from the barrel jack) is the one used later,
  post-flash, as the normal LAN/management port (see
  `configure-robot-radio.sh` below).

### Running the script

Place the script alongside the required files above, then right-click it →
**Run with PowerShell**, or open PowerShell as Administrator and run it from
there. The script walks you through every remaining step interactively
(adapter selection, when to power-cycle the radio, what to watch for), so no
separate usage walkthrough is needed here.

Because the script isn't signed, Windows SmartScreen will likely block it
the first time you try to run it. To bypass that:

- If you see a blue "Windows protected your PC" popup, click **More info**,
  then **Run anyway**.
- If PowerShell instead reports it cannot run scripts (execution policy),
  run it as: `powershell -ExecutionPolicy Bypass -File .\unlock-and-flash.ps1`

### If something goes wrong

- **Radio doesn't come up at `192.168.1.1` after flashing.** Wait the full
  60 seconds the script polls for — first boot on new firmware is slower
  than normal. If it still doesn't respond, set your adapter to
  `192.168.1.100/24` manually and try browsing to `http://192.168.1.1`
  directly; if that also fails, re-run the flash phase.
- **Firewall rule or leftover `tftpd64` process from an interrupted run.**
  The script cleans up its own firewall rule (`OM5P-AC TFTP`) and kills any
  running `tftpd64.exe` at the start of each run, so it's safe to re-run
  after a Ctrl+C or crash.

---

## 2. `configure-robot-radio.sh`

Bash script — run from WSL or Linux — that SSHes into a stock/factory OpenWrt
radio and configures it as a team-specific practice robot radio: field
uplink, local AP, IP addressing, and hostname.

This only works against a radio already running **OpenWrt** (i.e. after
`unlock-and-flash.ps1`), not the original FRC firmware. It's provided purely
as a convenience to get a radio into a configuration that mostly mirrors a
real FRC field setup — it's not required. After `unlock-and-flash.ps1`, the
radio is just a plain OpenWrt device; you're free to configure it by hand
(via LuCI/SSH) instead of running this script.

### Prerequisites

- The radio must already have a **root password set** via LuCI (the OpenWrt
  web UI), since stock OpenWrt blocks passwordless remote SSH. The script's
  SSH command will prompt for this password interactively.
- The radio doesn't need to be at its default address or default config —
  the script works as long as either your laptop's current DHCP-assigned
  default gateway is the radio, or you know the IP to SSH into it at (you
  can enter it manually at the prompt).
- Laptop connected to the radio's **LAN port (farthest from the barrel
  jack)** — not the unlock/flash port.
- `ssh` available (WSL, Linux, or any environment with an SSH client).

### What it configures

- **5GHz radio (`radio0`)** — WDS client (`sta` mode) uplink to the field
  AP's SSID (e.g. `2846-Field`), auto channel / VHT80, WPA2-PSK with the
  supplied field PPSK. Channel is auto (not fixed) so it can associate
  regardless of whatever channel the field AP actually uses.
- **2.4GHz radio (`radio1`)** — local AP, auto channel / HT20, SAE-mixed
  (WPA3/WPA2) with the supplied local key. The 2.4GHz AP exists so a driver
  station laptop can connect and drive the robot directly over Wi-Fi when
  there's no field network available.
- **LAN IP** — set from team number using FIRST's `10.TE.AM.x` convention
  (see below), replicating Freesy Arena's subnet logic. This only sets the
  radio's own IP (`10.TE.AM.1`) — it does **not** touch the roboRIO. The
  roboRIO's static IP reservation (`10.TE.AM.2`) still needs to be configured
  separately/manually — it isn't magically assigned automatically the way
  the FRC firmware/tooling normally handles it for you.
- **DHCP** — hands out gateway/DNS options pointing at `10.TE.AM.4`, with a
  pool of `10.TE.AM.200`–`10.TE.AM.219` (`start=200`, `limit=20`).
- **Firewall** — the radio is a bridge, not a router: the stock `wan` zone
  and forwarding rules are removed, and the `lan` zone is set fully
  permissive (accept/accept/accept). All interfaces end up bridged onto one
  flat subnet with no NAT, matching the real FRC field network.
- **Ethernet ports** — both physical ports are bridged into `br-lan`. Stock
  config only puts the LAN port (`eth1`) in the bridge and leaves the WAN
  port (`eth0`) separate; since the `wan` firewall zone is removed anyway,
  `eth0` is added into `br-lan` too so either port works identically.
- **Hostname and timezone** — timezone auto-detected from the host OS
  (Windows via `tzutil`, or `/etc/localtime` on Linux) with a North
  American IANA zone table; hostname defaults to `OM5P-AC_<AP SSID>`.

### IP addressing

The script computes the radio's IP from the team number using FIRST's
standard `10.TE.AM.x` field addressing convention — see
[WPILib: IP Configurations — TE.AM notation](https://docs.wpilib.org/en/stable/docs/networking/networking-introduction/ip-configurations.html#te-am-ip-address-notation)
and the [FMS Whitepaper](https://fms-manual.readthedocs.io/en/latest/fms-whitepaper/fms-whitepaper.html)
for the full convention this replicates.

### Usage

1. Connect your laptop to the radio's LAN port (farthest from the barrel
   jack). The radio should still be at its OpenWrt default address
   (`192.168.1.1`) with a root password already set via LuCI.
2. Run the script: `./configure-robot-radio.sh`
3. It auto-detects your current default gateway (usually the radio's IP) and
   your OS timezone as defaults — accept or override each prompt:
   - Timezone (IANA name)
   - Current radio IP address
   - Team number (1–25699)
   - Local AP SSID (default `<TEAM>-Robot`)
   - Local AP WPA key (defaults to the AP SSID)
   - Field uplink SSID (default `2846-Field`)
   - Field uplink PPSK (defaults to the AP SSID)
   - Hostname (default `OM5P-AC_<AP SSID>`)
4. Review the configuration summary and confirm with `yes`.
5. The script SSHes in (host key checking disabled — these radios get
   re-imaged often and reuse IPs, so a fixed known-hosts entry isn't useful),
   applies the `uci` changes, commits, and reboots the radio to apply them
   cleanly (a live service restart over the same session/interface being
   reconfigured is unreliable).
6. The radio comes up at its new `10.TE.AM.1` address. If you were connected
   via the radio's LAN port, you'll lose connectivity to it momentarily
   during the restart — reconnect at the new IP.

### Troubleshooting

- **SSH prompts for a password you don't know / connection refused.** The
  radio needs a root password set once via LuCI (`http://192.168.1.1`)
  before SSH will accept it — stock OpenWrt has SSH enabled but blocks login
  with a blank password.
- **"Unknown zone" when entering a timezone.** Only a fixed table of North
  American IANA zones is supported (see the script's `TZ_TABLE`). Use one of
  the zones listed in the error, e.g. `America/Chicago`.
- **Auto-detected gateway/timezone is wrong.** These are only defaults —
  just type the correct value at the prompt.
- **Lose connectivity partway through and can't tell if it applied.** The
  `uci commit` and reboot are triggered before the connection drops, so
  the config did apply — reconnect at the new `10.TE.AM.1` address (or the
  radio's previous IP if something failed before commit) to confirm.
- **Radio isn't reachable at the new IP afterward.** Confirm your laptop's
  adapter is on a compatible subnet, or connect through the Unifi UX7/field
  network instead of directly, since the radio's LAN IP has changed away
  from `192.168.1.1`.
