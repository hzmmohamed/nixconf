# Hotspot mode: keep traffic between my devices off mobile data (2026-11-22)

Status: **approved 2026-11-22, revised: hotspot untrusted; tailnet-only; layer 2 deferred.**
The revised decisions below override the original recommendation (kept further
down for the reasoning). Implemented: the policy nodeAttr (`e800556`), the
hotspot as an untrusted metered profile on hazel and butternut, the phone
renamed `wildflower` in the registry, butternut's avahi off Wi-Fi.

## Decisions (user, 2026-11-22)

1. **The hotspot is not a trusted network.** Friends sometimes join it, and
   only the phone (through the Nixconf app) may use the dictation and profile
   services. The `hotspot` profile is declared (SSID from sops, autoconnect,
   priority 10, **metered**, `dhcp-send-hostname`), but it opens **no** LAN
   service ports and no mDNS: `trusted-networks` now trusts only `home` (plus
   cable-link's profiles), not `hotspot`.
2. **Phone ↔ laptop traffic stays on the tailnet.** The nodeAttr
   `disable-android-bind-to-active-network` (`docs/tailscale-policy.hujson`,
   `e800556`) makes that path direct over the hotspot LAN. No mDNS service
   records, no LAN listener, no phone-app change now. Approach B below is
   dropped except for the declarative profile.
3. **Layer 2 is deferred** (see "Deferred: layer 2" below): built only if the
   Tailscale workaround proves unreliable.
4. **Hosts:** `preferences.wifi.hotspot.enable = true` on hazel and butternut
   only (already set in their configs; the profile appears once
   `secrets/shared/wifi-hotspot.yaml` exists, until then eval warns and skips
   it). key-mgmt stays `wpa-psk` (the module default): it joins WPA2 and
   WPA2/WPA3-transition hotspots, and NM's default PMF (optional) is fine for
   both. `sae` only if the phone is ever set to WPA3-only.
5. **The phone is `wildflower` on the tailnet** (renamed in the admin console;
   registry `phone.tailnetName = "wildflower"`, so `/etc/hosts` maps
   `wildflower` and `wildflower.<tailnet>` to its 100.x address).
6. **mDNS side finding: confirmed, half fixed.** See §5.

Laptop ↔ laptop traffic on the hotspot is unaffected by the untrusting:
ssh/deploy, nix offload, the harmonia cache and Syncthing all address peers
by their tailnet names, and `tailscale0` stays trusted. What stops working on
the hotspot is `.local` names, Syncthing local discovery, KDE Connect
discovery and plain-LAN sshd. All of them have tailnet equivalents.

Related: `2026-11-17-network-review.md` (§4 tailnet, §11 hotspot gaps),
`2026-11-22-agent-environment-design.md` (agents learn when the uplink is
metered; this doc coordinates with it and does not duplicate it),
`2026-11-17-t3code-integration.md`, `modules/nixos/features/{wifi-home,trusted-networks,lan-discovery,dictation-server}.nix`,
`docs/tailscale-policy.hujson`.

Legend: **[obs]** observed on butternut today · **[ws]** well supported (docs, source, several independent reports) ·
**[anec]** anecdotal or a single report · **[inf]** my inference, not verified.

## Why

When you are out, hazel, butternut and the phone all sit on the phone's hotspot
(`wildflower`). This happens often. Traffic between the laptops is already
local. Traffic between the **phone and a laptop** is relayed through Tailscale
DERP in Paris instead: T3 Code mobile ↔ butternut, the dictation keyboard
(WAV uploads, the profile, the 640 MB Parakeet model, APK updates), Taildrop,
KDE Connect "by IP", adb, ssh. Each relayed byte crosses the phone's cellular
link twice (up to Paris, back down), so it counts twice against a tight
metered plan. It is also slow: 180–400 ms per ping, and a 64 MB Taildrop
crawled at about 10 KiB/s and stalled.

## Findings

### 1. What the network looks like on the hotspot [obs]

| Fact | Evidence |
|---|---|
| butternut `10.19.167.6/24` on `wlo1`, gateway (the phone) `10.19.167.40`. The hotspot also hands out **global IPv6** from the carrier /64 `2c0f:fc89:8142:f1b2::/64`. The phone's tether-side address is `…::98` | `ip -br addr`, `ip -6 route`, `ip neigh` |
| The phone answers plain ICMP on both LAN addresses in about 5–20 ms | `ping 10.19.167.40`, `ping -6 …::98` |
| **hazel ↔ butternut is already direct over the hotspot**: `direct 10.19.167.16:41641`, and the journal shows disco switching between hazel's LAN IPv4 and its on-link IPv6 | `tailscale status`, `journalctl -u tailscaled` |
| **phone ↔ butternut is DERP**: `pong … via DERP(par) in 182–275ms`, `direct connection not established` | `tailscale ping -c 4 21081111rg` (the phone's old name, now `wildflower`) |
| **The phone *does* advertise its hotspot endpoint.** Its netmap endpoints include `10.19.167.40:36027` and `[2c0f:…::98]:36027`, next to its carrier ones (`105.83.221.163:19901`, `10.223.93.163`, `[…:1:0:36d9:2e0c]`) | `tailscale debug netmap` |
| butternut's side is not the blocker: UDP 41641 is open globally (`networking.firewall.allowedUDPPorts = [41641]`), `tailscale0` is trusted, and netcheck shows an easy NAT (`MappingVariesByDestIP: false`) | `nix eval …networking.firewall`, `tailscale netcheck` |
| NetworkManager already guesses the hotspot is metered (`GENERAL.METERED: yes (guessed)` from Android's DHCP hint). The connection butternut uses is the imperative `wildflower` profile (`connection.metered: unknown`), so it is **not** a trusted network: 8178, 8180, mDNS, KDE Connect and Syncthing discovery are closed on it | `nmcli`, agent-environment design §"Today" |
| `preferences.wifi.hotspot.enable` is **not set on any host**, and `secrets/shared/wifi-hotspot.yaml` doesn't exist. Even with the secret in place, nothing would create the profile today | `rg wifi.hotspot modules/nixos/hosts` |

So the brief's guess ("Android Tailscale can't see the tethering interface")
is half right. It does see the interface and advertises it, but it can't
*use* it.

### 2. Root cause: Tailscale ≥ 1.98 binds its Android sockets to the active network [ws]

- **tailscale/tailscale#20782** (open, `OS-android`, `bug`): *"Android hotspot
  peers fall back to DERP when hotspot host mobile data is enabled."* With
  mobile data on → DERP. With mobile data off and the hotspot still up →
  direct (5–22 ms). Mobile data back on → DERP again. Reproduced on Galaxy
  S22U/Note9, Pixel 8 Pro, vivo X200 Pro and POCO X7 Pro hotspots, with
  Android and macOS clients, on 1.102.2 through **1.104.5** (the version our
  hosts run). <https://github.com/tailscale/tailscale/issues/20782>
- **Workaround in that thread:** the tailnet-policy node attribute
  `disable-android-bind-to-active-network`. One reporter (Pixel 8 Pro hotspot,
  macOS client, which is exactly our phone-is-the-hotspot shape) got
  `direct 10.219.190.167:…` after adding it. Another reports that
  downgrading the Android app to **1.96.4** gave 5 ms over the hotspot LAN,
  against 193 ms on 1.104. **[anec]**: one report each, but they are
  consistent with each other.
- **Source:** `net/netns.SetDisableAndroidBindToActiveNetwork` ("disables the
  default behavior of binding sockets to the currently active network on
  Android") **first appears in tailscale.com v1.98.0**
  (<https://pkg.go.dev/tailscale.com@v1.98.3/net/netns>). That fits the
  1.96 → 1.98 regression.
- **Mechanism [inf]:** on the hotspot phone the *active* network is cellular.
  A socket explicitly bound to it gets cellular's routing table, which has
  no route to the tether subnet `10.19.167.0/24`, and Android's
  `local_network` rule only applies to sockets that didn't explicitly select
  a network. Disco pings from butternut probably reach the phone, but the
  pongs leave through cellular toward a private address and are lost. Hole
  punching over cellular itself is hopeless here: the phone's carrier side is
  CGNAT, and butternut's "public" address `105.83.221.163` *is* the phone's
  own NAT.
- Same family, different trigger: #22336 (TCP to peers dies 2 s after
  joining Wi-Fi while mobile data stays up, netd socket destruction on the
  cellular netId) and #19297 (stuck on DERP after a network switch). The
  active-network binding was presumably added to fix switching problems like
  these. **Turning it off may bring some of them back** on the phone
  **[inf]**. <https://github.com/tailscale/tailscale/issues/22336>,
  <https://github.com/tailscale/tailscale/issues/19297>

### 3. Tailscale-side options

| Option | Verdict |
|---|---|
| **nodeAttr `disable-android-bind-to-active-network`** | **Fixes the root cause.** One line in `docs/tailscale-policy.hujson`, applied with the existing tofu scripts. Only Android clients read it, so `target: ["*"]` doesn't affect Linux. Risk: it works around an open upstream bug, it may be renamed or dropped, and network switching on the phone may regress. Rollback is deleting the line |
| **Peer Relays** (butternut/hazel as relay, `tailscale set --relay-server-port=…` plus a `tailscale.com/cap/relay` grant, already stubbed for maple in the policy) | **Doesn't help.** Android can be a relay *client* but not a server (<https://tailscale.com/docs/features/peer-relay>). The phone reaches a relay through the same bound socket, so a relay on butternut's LAN address is as unreachable as butternut itself **[inf]**. A relay elsewhere (maple at home) cuts latency but still crosses cellular twice |
| Subnet routes, `--accept-routes`, exit-node tricks | Don't apply. The problem is the phone's underlying socket, not tailnet routing |
| Android app settings | Nothing relevant. "Allow LAN access" only concerns exit-node use |
| **Turn mobile data off** on the phone | Works today per #20782 (direct comes back), but there is no internet meanwhile. **A useful manual trick for one-off big local transfers** (the 640 MB model, an APK) until the fix lands |

### 4. App/service-side options (keep traffic local without the tailnet)

- **mDNS/DNS-SD.** avahi already runs everywhere (`lan-discovery`; on
  butternut it is limited to `eno2 wlo1`), but UDP 5353 is open only on
  trusted networks, and today the hotspot isn't one (§1). Features can
  publish service records with `services.avahi.extraServiceFiles`. DNS-SD
  service names are at most 15 characters: `_dictation._tcp`,
  `_phoneprofile._tcp`.
- **The phone side.** `NsdManager` discovers and resolves DNS-SD.
  Android 14's mDNS stack (`MdnsSocketProvider`) follows tethered
  interfaces, so discovery should work *from the hotspot phone itself*
  **[anec/inf, verify on the device]**. Fallback that doesn't depend on
  mDNS: the phone app can list its own interfaces (`NetworkInterface`,
  allowed for apps, MACs hidden) and find the tether subnet, then
  probe-connect port 8178 across that /24. That's 254 parallel connects,
  sub-second on the LAN, and no modem traffic.
- **The cleanest LAN-first hook in the phone app is OkHttp's `Dns`
  interface.** When `butternut.tail1a9f7c.ts.net` is resolved and a fresh
  NSD entry says "butternut is on-link at 10.19.167.6", return the LAN
  address first and the system (MagicDNS 100.x) answer after it. OkHttp
  falls back across addresses by itself. No URL rewriting is needed, and
  profile.json keeps its MagicDNS URLs. This is the `/etc/hosts`-style
  fallback the network review asks for, done per app.
- **Stable addresses: don't rely on them.** Android picks a random private
  /24 for the tether (10/8, 172.16/12 or 192.168/16) and, on recent
  releases, keeps it "persistent till reboot"
  (<https://gerrit.omnirom.org/plugins/gitiles/android_packages_modules_Connectivity/+/c0b0f616d0dc094666ac81f81ddda8913ff22ff0>,
  e/OS mirrors of the same Connectivity commits) **[anec]**. Android has no
  DHCP reservation UI. Clients probably get the same lease while the phone
  stays up (NM keeps the MAC per network by default) **[inf]**. Use names:
  `<host>.local` between laptops, NSD on the phone, and "the default
  gateway" for the phone as seen from a laptop.
- **T3 Code mobile (not our code).** T3 supports several routes per machine
  and uses the first one that answers [doc, integration doc §0.4]. A LAN
  route would need the server off loopback (`--lan`, `0.0.0.0` limited to
  private networks) plus pairing. HTTPS is required for app.t3.codes, and
  whether the native app accepts plain `http://10.x` is **unknown**. With
  the Tailscale fix, T3 needs no change at all: `https://butternut.…ts.net`
  then rides the direct LAN path. Recommendation: don't add a LAN route.

### 5. Security: is the hotspot a trusted network?

**Decided: no** (decision 1). The analysis that led there:

`wifi-home` already designs the `hotspot` profile as trusted, and
`trusted-networks` trusts it by *connection id* (it carries the PSK, so an
evil twin without the key can't associate). Trusted means these ports open:
dictation 8178 and phone-profile 8180 (**no authentication**), mDNS 5353,
KDE Connect 1714–1764 (pairing still required), Syncthing 22000/21027
(device IDs required) and sshd 7654 (keys only).

- **Only your devices on it: fine.** It's a WPA2 network you control.
- **A friend joins:** they can use butternut's GPU through `/inference`,
  download profile.json (the fleet vocabulary: names and project terms),
  the Parakeet files and the APK, and see hostnames over mDNS. Nothing gives
  them a shell or your files. They also learn the PSK, which weakens the
  evil-twin argument afterwards.
- **The Tailscale fix adds no LAN exposure.** The traffic stays WireGuard
  inside the tailnet, under ACLs. That is a second reason to lead with it.
  LAN-first app paths (approach B) are what widen the LAN surface.
- **Side finding: confirmed from the config.** `lan-discovery` runs avahi
  with `publish.enable` + `publish.addresses` and, on hazel,
  `allowInterfaces = null` (every interface). The firewall filters only
  inbound, so avahi still multicasts its `hazel.local` A/AAAA announcements
  whenever an interface comes up, café and office Wi-Fi included. It can't
  hear queries there (5353 closed), so it doesn't answer them. The leak is the
  hostname and the link addresses, to everyone on that link. NM already sends
  the hostname to the café's DHCP server on every connection, so mDNS widens
  the audience but adds little information. butternut had the same leak
  through `wlo1`, which was in its list only for `.local` on the hotspot.
  - **Fixed on butternut:** `lan-discovery.interfaces = ["eno2"]` (the cable
    or the home LAN). With the hotspot untrusted, `wlo1` bought only
    home-Wi-Fi mDNS, and `lan-cache.nix` already avoids `.local` because it
    can resolve to the Wi-Fi address.
  - **Not fixed on hazel (follow-up):** its Wi-Fi interface serves both the
    trusted `home` network and foreign ones. Restricting avahi to the cable
    (`enp4s0`) would also drop `.local` and printer discovery (CUPS) on home
    Wi-Fi. A proper fix makes avahi follow trust: either an NM-dispatcher
    hook that rewrites `allow-interfaces` from `/run/trusted-networks` and
    restarts avahi (avahi reads its interface list only at start), or an
    OUTPUT-chain rule in `trusted-networks` dropping UDP 5353 on untrusted
    interfaces (cheap, but avahi logs a warning per dropped send). Low
    priority given the DHCP hostname. If home-Wi-Fi `.local` turns out to be
    unused, the one-liner `preferences.lan-discovery.interfaces = ["enp4s0"]`
    on hazel is enough.

### 6. Data accounting on the hotspot

| Traffic | Today | After the recommended design |
|---|---|---|
| Laptop ↔ laptop (nix offload hazel → butternut, harmonia substitution, Syncthing, ssh, deploy) | direct LAN (tailnet) — free | same |
| Phone ↔ laptop over the tailnet (T3, dictation, profile, model, APK, Taildrop, KDE Connect by IP, adb) | **DERP, counted twice** | direct LAN — free |
| Laptops → internet (cache.nixos.org, git, LLM APIs, agent pulls) | metered once | metered once (agent-environment design steers this) |
| Tailscale control, DERP keepalive, netcheck | small | small |

**The phone app's "Wi-Fi only" rule.** Today `isUnmetered()` checks
`NET_CAPABILITY_NOT_METERED` on the active network. On the hotspot phone that
network is cellular, so the model download is refused unless forced. That is
right for internet downloads, but it also blocks free LAN ones. **Keep the
gate for tailnet URLs**, because the app can't tell a direct path from a
DERP one, and forcing a 640 MB download over DERP costs 1.3 GB. **Lift it
when the download host resolves to an address on-link with one of the
phone's non-cellular interfaces** (the NSD/`Dns` path above). Such traffic
physically can't touch the modem.
*(Deferred with layer 2: without a LAN path the gate stays as it is, and a
640 MB model download on the hotspot waits for Wi-Fi or a forced
download, which is direct over the tailnet once the nodeAttr works.)*

**Laptop side.** The declarative `hotspot` profile sets `connection.metered = 1`,
on top of NM's DHCP guess. Coordination with agent-environment: "metered"
describes the **uplink**. Transfers to LAN peers, or to tailnet peers on a
direct path, are free, while a peer on `relay "…"` is not. Worth one
sentence in that design, and optionally a "phone path: direct/relay"
signal (below).

## Approaches

**A. Fix the tailnet path (policy nodeAttr).** One line in the repo, user
runs the tofu apply, phone reconnects.
\+ Covers every flow, including T3, which we can't change. No new LAN
exposure. Minutes of work. Trivial rollback.
− Works around an open upstream bug, with possible phone-side network-switch
regressions. Depends on Tailscale running on the phone. Says nothing about
offline robustness.

**B. LAN-first at the service layer.** Declare the hotspot profile (trusted
+ metered), publish avahi records from the features, add NSD-backed `Dns` to
the phone app, and optionally a T3 LAN route.
\+ Works with Tailscale down or broken. Matches the "don't rely solely on
Tailscale" rule. Gives the phone a *provable* free path for big downloads.
− More code. Unauthenticated HTTP on the LAN (the friend problem). Doesn't
cover T3, Taildrop or adb.

**C. Tailscale relays and route tricks.** Rejected (§3): none of them stops
the double cellular crossing.

**Superseded by the decisions at the top: A, plus only the declarative
(untrusted, metered) hotspot profile from B.** The original recommendation,
for the record: **A now, plus the cheap, robust half of B.** A removes almost
all the waste today. From B take the declarative hotspot profile (we need it
anyway for headless butternut, trust, metered, mDNS and `.local`), avahi
records owned by `dictation-server`, and the phone app's on-link `Dns` +
free-download rule. Those keep dictation and model downloads local even if A
regresses or upstream fixes #20782 differently. Skip a T3 LAN route.

## Design (as implemented; items 3–4 are dropped by decision 2)

1. **Tailnet policy** (`docs/tailscale-policy.hujson`, `nodeAttrs`):
   ```hujson
   // Android ≥1.98 binds its sockets to the active (cellular) network, so the
   // phone can't use its own hotspot LAN and every phone↔laptop byte goes
   // through DERP twice over mobile data (tailscale/tailscale#20782).
   // Only Android clients read it. Drop when #20782 is fixed.
   {"target": ["*"], "attr": ["disable-android-bind-to-active-network"]},
   ```
   Applied with `scripts/tailscale/{plan,apply}.sh`. Add a `tests` entry?
   No: nodeAttrs aren't testable there.

2. **Hotspot profile**: `preferences.wifi.hotspot.enable = true` on
   **hazel and butternut** (not maple/peacelily: they are headless and
   stationary). The secret `secrets/shared/wifi-hotspot.yaml` (key
   `wifi_hotspot_env`, catch-all sops rule, primary key) is a user action.
   The profile (NM id `hotspot`, keyfile
   `/run/NetworkManager/system-connections/hotspot.nmconnection`) carries
   `metered = 1`, `dhcp-send-hostname`, priority 10 (below home/office) and
   `key-mgmt = wpa-psk`. **Untrusted**: `trusted-networks` no longer lists
   it. After the deploy, delete the imperative `wildflower` profile on both
   laptops so NM doesn't pick a duplicate without `metered`.

3. ~~**avahi service records**~~ (dropped: no mDNS on the hotspot) in `dictation-server.nix` (owner of the
   services):
   `_dictation._tcp` port `cfg.port`, TXT `host=<hostName>` `path=/inference`;
   when `phone.enable`, `_phoneprofile._tcp` port `phone.port`, TXT
   `host=<hostName>` `path=/profile.json`. Via
   `services.avahi.extraServiceFiles`. Firewall stays trusted-networks only.
   On hazel, consider `preferences.lan-discovery.interfaces` (café
   announcements, §5).

4. ~~**Phone app**~~ (dropped; layer 2 below if ever needed) (`apps/phone/`):
   - `LanDirectory`: `NsdManager` discovery of `_dictation._tcp` and
     `_phoneprofile._tcp` while the app or keyboard is active. Map
     `host` TXT → resolved IPv4/IPv6, with a TTL.
   - OkHttp `Dns` wrapper: for `<host>.<tailnet domain>` (or a bare `<host>`)
     with a fresh on-link entry, return the LAN addresses first, then the
     system answer. `chooseEngine` stays as it is (it probes URLs, and the
     `Dns` layer decides the path).
   - `isFreePath(url)`: true if `NOT_METERED`, **or** the URL's host resolves
     through `LanDirectory` to an address inside a subnet of a local
     non-cellular `NetworkInterface`. `ModelDownloader` and the APK updater
     use it instead of `isUnmetered`.
   - Fallback discovery (if NSD on the tether proves unreliable): probe the
     tether /24 on 8178. Only on demand, never in the background.
   - Android 16/17 "local network access" permission: check the target SDK
     when it's raised **[anec]**.
   - JVM tests: `Dns` ordering, on-link check, gate decisions.

5. **Optional visibility**: `agent-net` (agent-environment design) or a
   waybar module reports `phone path: direct|relay` from
   `tailscale status --json` while the uplink is the hotspot, so a
   regression of (1) is visible and doesn't silently eat data.

## Deferred: layer 2 (only if the Tailscale workaround proves unreliable)

If the nodeAttr stops working (upstream renames it, the phone regresses on
network switches, or #20782 is "fixed" differently), add a LAN path that
doesn't need trust in the hotspot:

- A **separate LAN-only port** on butternut (and hazel if needed) for the
  phone services, opened on the hotspot connection only, never the existing
  unauthenticated 8178/8180.
- **TLS with a self-signed cert** and a **per-phone bearer token**. Requests
  without the token get 401, so friends on the hotspot get nothing.
- **Tailscale as the trust root:** profile.json (fetched over the tailnet, as
  today) carries the LAN port, the cert's SHA-256 fingerprint and the token.
  The app pins the fingerprint and sends the token. The token lives in sops,
  per phone.
- Discovery: "the default gateway's subnet" from the phone's own interfaces,
  or a subnet probe of that port, since mDNS stays off on the hotspot.
- Plus the app's free-path gate for large downloads (§6).

Not built. Revisit after a few weeks on the hotspot with the nodeAttr.

## Rollout (ordered)

0. **Until (1) lands:** for one-off large local transfers, turn mobile data
   off on the phone for the transfer (hotspot stays up).
1. Policy nodeAttr → apply → reconnect Tailscale on the phone → verify
   `direct 10.19.167.40:…`. Watch the phone for a week for stuck or dropped
   connections after Wi-Fi ↔ cellular switches.
2. Hotspot sops secret (user) → deploy hazel and butternut (the enable is
   already set) → delete the imperative `wildflower` profiles → verify
   metered and **untrusted**.
3. ~~avahi records~~, ~~phone app LAN directory~~: dropped (decision 2).
4. hazel's avahi follows trust (§5 follow-up), low priority.
5. Optional phone-path indicator; a sentence in the agent-environment design
   about LAN/direct transfers being free.

## User actions

The paste-ready list lives in `docs/plans/2026-11-17-user-actions.md`,
section "Phone hotspot (wildflower): direct tailnet path, untrusted profile".

## Open questions

Answered 2026-11-22: (1) the SSID is `wildflower`; WPA mode left to NM's
`wpa-psk` default; (3) friends do join, so the hotspot is untrusted.
Still open:

1. **SSID, band and security** of the hotspot: is it always `wildflower`?
   2.4 or 5 GHz? WPA2 or WPA3 (sets `preferences.wifi.hotspot.keyMgmt`)?
2. **Phone Tailscale version** (Settings → About). The workaround needs ≥ 1.98.
   On older versions the bug shouldn't occur at all.
3. **Do friends ever join the hotspot?** If yes: keep the hotspot trusted
   and change the PSK afterwards, or add a "guests present" switch that drops
   trust for the session (small follow-up in trusted-networks)?
4. **Is a week of possible phone-side flakiness** (connections stuck after
   Wi-Fi ↔ cellular switches) acceptable as the price of (1)?
5. **Does a laptop keep the same hotspot IP** across sessions and after a
   phone reboot? (Check `ip -br addr show wlo1` next time.) The design doesn't
   depend on it, but it decides whether the subnet-scan fallback is ever
   worth building.
6. **Should butternut ever follow you onto the hotspot without hazel**
   (e.g. carried somewhere)? That only matters for whether the profile
   autoconnects on butternut (default: yes, priority 10).
