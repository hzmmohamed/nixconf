# Network, DNS & Tailscale review (2026-11-17)

Scope: butternut, hazel, maple, peacelily, Android phone, planned AWS agent VM and a possible
tiny cloud peer. Read-only review: live evidence from butternut (unprivileged commands only)
plus the repo at the time of writing, including uncommitted `agent-*` changes.

Legend: **[have]** exists today, **[gap]** missing, **[risk]** works but fragile or unsafe.

---

## 1. Current state (evidence)

### 1.1 butternut live (2026-11-17 05:12 EET, on home Wi-Fi `WE_93CBE9`)

| Item | Observation |
|---|---|
| `/etc/resolv.conf` | written by resolvconf on tailscaled's behalf: `search tail1a9f7c.ts.net`, `nameserver 100.100.100.100`, `fd7a:115c:a1e0::53` |
| systemd-resolved | **inactive** (`resolvectl` has no service). tailscaled manages DNS by overwriting resolv.conf |
| nsswitch `hosts:` | `mymachines mdns4_minimal [NOTFOUND=return] files myhostname dns mdns4` |
| `/etc/hosts` | localhost and `127.0.0.2 butternut` only. **No fleet entries**, so the memory rule "never rely only on Tailscale" is not met |
| Tailscale | 1.104.5, `CorpDNS=true` (accept-dns), `RunSSH=true`, no exit node, no advertised routes, `ShieldsUp=false` |
| Tailnet DNS (admin console) | MagicDNS on, suffix `tail1a9f7c.ts.net`. Global resolvers 1.1.1.1/1.0.0.1/8.8.8.8/8.8.4.4 (+v6), so **"Override local DNS" is on**. Tailscale forwards to these over DoH automatically ([KB 1054](https://tailscale.com/kb/1054/dns)). Proof: Google's `o-o.myaddr` TXT seen through 100.100.100.100 returns `162.159.x` (a Cloudflare resolver egress), not the ISP |
| Peers | hazel offline 14 d; **maple offline 249 d; peacelily offline 202 d**; Android `xiaomi-21081111rg` offline 31 d. So today the tailnet is effectively butternut alone |
| netcheck | UDP OK. Public IPv4 `197.39.109.14` (TE Data/WE, **not CGNAT** on the home line). `MappingVariesByDestIP: false` (easy NAT, so direct paths should work). **No PortMapping** (router has no UPnP/NAT-PMP/PCP). No IPv6. Nearest DERP **Paris 52 ms**, then London 64 and Frankfurt 64. Dubai 140 and Mumbai 141 are *worse*, so do not assume a Middle-East region is closer |
| ISP DNS | Router hands out `192.168.100.1` → TE Data resolver `163.121.128.112`. NXDOMAIN is not rewritten. `whoami.cloudflare @1.1.1.1` returns our own IP, so **no transparent DNS interception today** |
| search.nixos.org | DNS resolves fine (Netlify, AWS eu-central-1 `35.157.26.135`, `63.176.8.218`), but **TCP :443 to both IPs times out**. netlify.com and cache.nixos.org return 200. So it is an **IP-routing block, not DNS**: DoH/DoT will not fix it, only a tunnel out of Egypt (exit node or app connector) will |
| Listeners (non-loopback) | `0.0.0.0:5000` nix-serve (firewall: eno2 only), `*:7654` sshd, `100.105.41.75:3773` T3 Code (the *running* build binds the tailnet IP; the working-tree module moves it to loopback + `tailscale serve`), `*:22000/21027` Syncthing, `*:1716` KDE Connect, `*:57622` + `5353` spotifyd, `5353` avahi |
| `tailscale serve status` | "No serve config": the serve-based T3/OpenCode modules are not deployed yet |
| mDNS | avahi limited to `eno2` (down), so `butternut.local` does not resolve and `avahi-browse -art` is empty |
| NM profiles | Declarative: `home` (ssid `"home"`), `ethernet-share`. Imperative: `WE_93CBE9` (in use), `Transport for Cairo*` (office), `Nokia 5.4` (old phone hotspot?), `DIRECT-8eM2070 Series` (Samsung M2070 printer Wi-Fi Direct), several cafés. **The declarative `home` profile's SSID does not match the network actually in use** (`WE_93CBE9`) |
| nix substituters | cache.nixos.org, nixos-cuda, noctalia, numtide. No LAN cache on butternut itself (it is the server) |

### 1.2 Repo (inferred for the other hosts)

- `tailscale.nix`: `extraUpFlags = ["--ssh"]`, **one shared reusable auth key** (`secrets/shared/tailscale.yaml`) for every host. `trustedInterfaces = [tailscale0]`, so *every* port is open to *every* tailnet peer. `checkReversePath = "loose"`. No `useRoutingFeatures`, no tags, no `authKeyParameters`.
- No host sets `services.resolved`, `networking.hosts/extraHosts`, `networking.nameservers` or NM `dns`. So all hosts use tailscaled-managed resolv.conf, or plain NM resolv.conf when Tailscale is down.
- `openssh.nix`: port 7654 open on **all interfaces** (`openFirewall` default), `PasswordAuthentication = true` (TODO), and only butternut's key is in `ssh-keys.nix`.
- Ports opened globally, so they are also open on café Wi-Fi: KDE Connect 1714-1764 tcp+udp, spotifyd 5353/57622, Syncthing 22000/21027, Reticulum udp 29716/42671, sshd 7654.
- `lan-discovery`: avahi with `nssmdns4`. butternut restricts it to eno2; hazel uses all interfaces (it publishes `hazel.local` on café Wi-Fi). maple and peacelily do not import it.
- `lan-cache` (hazel): `http://10.42.0.1:5000`, priority 10, `connect-timeout 3`, `fallback = true`. Cable only.
- `remote-deploy`: tries `<host>.local`, then `<host>`, with `StrictHostKeyChecking=accept-new` (TOFU).
- `hazel` hand-writes an ssh `matchBlocks` for butternut, peacelily and maple (MagicDNS names, port 7654). Nothing similar exists on the other hosts.
- `ai-server` (peacelily): binds 0.0.0.0 and admits ports on tailscale0 only. Good. It imports `wifi-home` (so on Wi-Fi) and has no `lan-discovery`.
- maple has **no `wifi-home` import**, so its Wi-Fi is an imperative NM profile. Its tailnet node has not been seen for 249 days, so it probably needs re-auth (the shared auth key may have expired: max 90 days).
- `agent-t3code`/`agent-opencode` (working tree): loopback + `tailscale serve` HTTPS on `butternut.tail1a9f7c.ts.net` (443 T3, another port for OpenCode). `--operator=hfahmi` via `extraSetFlags`. Good design.
- Committed: `tailnetDomain = "tail1a9f7c.ts.net"` (public repo). It only matters to tailnet members. Low risk, but it also reveals the hostnames through CT logs once HTTPS certs are issued (inherent to `tailscale cert`).

### 1.3 DNS path today (butternut; others are the same once Tailscale is up)

```
app → glibc NSS: mdns4_minimal (.local only) → files → dns
dns → /etc/resolv.conf → 100.100.100.100 (tailscaled)
   ├─ *.tail1a9f7c.ts.net, short names via search domain → answered from the netmap (local, no network)
   ├─ ts.net (other) → Tailscale split DNS 199.247.155.53
   └─ everything else → DoH to 1.1.1.1 / 8.8.8.8 (encrypted; the ISP cannot see or block names)
```

What happens when…

| Event | Effect |
|---|---|
| ADSL down, Tailscale up | Tailnet names still resolve (netmap in memory). Internet names fail (no DoH). LAN peers still work if WireGuard paths were already direct. New paths need disco via DERP, so they **fail** |
| tailscaled stopped or crashed | tailscaled restores the original resolv.conf (NM's, i.e. router/ISP DNS, plaintext). Short names `maple` etc. stop resolving entirely. There is **no /etc/hosts fallback** |
| Coordination server unreachable but internet up | Existing netmap keeps working. DNS keeps working. Key or ACL changes and new nodes don't propagate. After a **reboot** with no control reachable, recent clients start from a cached netmap only if the state permits. **Treat this as unreliable and test it** |
| **Café captive portal** | MagicDNS forwards to DoH 1.1.1.1. The portal's DNS hijack never sees the query, so the login page never appears ("connected, no internet"). Escape hatch today: `tailscale down` or `tailscale set --accept-dns=false` (operator-allowed once `--operator` is set) |
| Direct cable (eno2) | NM shared mode: dnsmasq on 10.42.0.1 serves DHCP+DNS to hazel. hazel's resolv.conf is still owned by tailscaled if it is up. `butternut.local` works over avahi (both sides) |

---

## 2. Recommendations: DNS (item 1)

### 2.1 Enable systemd-resolved on every host (this week)

Why: tailscaled currently clobbers resolv.conf. With resolved, tailscaled programs it over D-Bus instead:
`tailscale0` gets `DNS=100.100.100.100` with `~tail1a9f7c.ts.net` (and `~.` when Override-local is on).
When tailscaled stops, resolved simply drops that link's DNS, with no file restore races. You also get
per-link DNS (eno2 dnsmasq vs Wi-Fi), `resolvectl` diagnostics, a DNS cache, and DoT for the non-Tailscale path.
NM integrates natively (`networking.networkmanager.dns = "systemd-resolved"` is chosen automatically when resolved is enabled).

```nix
# modules/nixos/features/dns.nix  → flake.nixosModules.dns (import in `general`)
{
  flake.nixosModules.dns = {lib, ...}: {
    services.resolved = {
      enable = true;
      settings.Resolve = {
        # Used only when Tailscale is down/not overriding: encrypt if the server
        # supports it, otherwise fall back to plain (keeps captive portals working).
        DNSOverTLS = "opportunistic";
        DNSSEC = "false";             # ISP/captive resolvers break DNSSEC; Tailscale DoH upstreams validate anyway
        LLMNR = "false";
        MulticastDNS = "false";       # avahi owns 5353 (lan-discovery, nss-mdns)
        FallbackDNS = ["1.1.1.1#cloudflare-dns.com" "9.9.9.9#dns.quad9.net"];
        Domains = ["~."];             # resolved's own global servers participate for every name
      };
    };
    # Avahi + nss-mdns keep resolving *.local; resolved never touches .local.
  };
}
```

Risks / notes:
- Re-check `grep hosts /etc/nsswitch.conf` after switching. You want `mdns4_minimal [NOTFOUND=return]`
  before `resolve`, and `files` before `resolve`.
- Do not set `networking.nameservers` with Override-local on. Two global paths would race and leak to the ISP.
  Leave `settings.Resolve.DNS` empty and let Tailscale own the `~.` route while it is up.
- `DNSSEC=allow-downgrade` is tempting but causes intermittent SERVFAIL on Egyptian/café resolvers. Leave it off.
- Option names verified against the pinned nixpkgs (`services.resolved.settings.Resolve.*`; the old flat options are renamed).

### 2.2 Global resolver choice in Tailscale

- Keep **Override local DNS = on** with DoH-known resolvers. This is the anti-ISP-snooping/blocking path and it already works.
- Optional upgrade: **NextDNS** as the global nameserver (Tailscale integration, DoH, per-device analytics,
  ad/tracker blocking for the *phone* too, no home infra). It replaces the need for AdGuard Home on maple.
  Free tier is 300k queries/month, which is enough for one person. Alternatively Quad9 for malware blocking.
- Keep Cloudflare + Google as a second pair so a NextDNS outage does not black-hole DNS.

### 2.3 Captive-portal escape (quick win)

A `captive` script on butternut/hazel: `tailscale set --accept-dns=false; xdg-open http://neverssl.com; read; tailscale set --accept-dns=true`.
It needs `--operator=<user>`, which so far only agent hosts have. Move `extraSetFlags = ["--operator=${user}"]` into `tailscale.nix`
for desktop hosts. Optionally run an NM dispatcher on `connectivity-change` that notifies you
("captive portal detected → run `captive`"). NM's connectivity check (`networking.networkmanager.settings.connectivity`)
is off by default on NixOS. Enable it with `uri=http://nmcheck.gnome.org/check_network_status.txt`.

### 2.4 mDNS / avahi coexistence

- avahi stays the mDNS stack. resolved has `MulticastDNS=false`. spotifyd's own libmdns also binds 5353
  (SO_REUSEPORT, coexists). OK.
- butternut: allow avahi on `eno2` **and `wlo1`**, but only answer on trusted networks (see §6.3 trusted-network firewall).
  Note that NM already leaks the hostname to every café DHCP server (`dhcp-send-hostname` default true),
  so avahi announcements add little. Set `ipv4.dhcp-send-hostname=false` on untrusted profiles if that matters.
- NM shared mode on eno2: its dnsmasq answers DNS for hazel. With resolved on butternut the two do not clash
  (dnsmasq binds 10.42.0.1:53, the resolved stub binds 127.0.0.53). hazel learns `10.42.0.1` as eno-link DNS.
  hazel's Tailscale (if up) still routes `~.` to MagicDNS. Over a cable with no uplink, hazel's internet DNS fails
  either way, and `butternut.local` plus the hosts registry (§3) cover names.

---

## 3. Naming scheme (item 2)

### 3.1 One scheme, three layers

| Layer | Name form | Resolves via | Works when |
|---|---|---|---|
| Tailnet (primary) | `maple`, `maple.tail1a9f7c.ts.net` | MagicDNS **and** /etc/hosts (registry) | tailscaled up (IPs are stable per node) |
| Web services | `https://butternut.tail1a9f7c.ts.net[:port]/`, later `https://t3.tail1a9f7c.ts.net/` (Tailscale Services) | MagicDNS + Let's Encrypt via `tailscale serve` | tailscaled up |
| LAN / cable (fallback) | `maple.local` (mDNS), `maple-lan` (DHCP reservation), `butternut-cable` = 10.42.0.1 | avahi / /etc/hosts | Tailscale down or no internet |

Rule for scripts: try `<host>.local` → `<host>-lan` → `<host>` (`deploy` already does the first and last).

### 3.2 Hosts registry module (this week, unblocks several backlog items)

One attrset drives `/etc/hosts`, ssh client config, `known_hosts`, Syncthing devices, nix-serve keys
and ACL tags (doc only). Tailscale 100.x addresses are stable per node. Pin them in the admin console
("Edit machine IPv4") so a re-register does not move them.

```nix
# modules/hosts.nix
{
  flake.hosts = {
    butternut = {
      ts4 = "100.105.41.75"; ts6 = "fd7a:115c:a1e0::2d01:294b";
      lan = "192.168.100.3";            # reserve in the WE router's DHCP binding table
      cable = "10.42.0.1";              # NM shared mode on eno2
      sshPort = 7654;
      hostKey = "ssh-ed25519 AAAA…";    # /etc/ssh/ssh_host_ed25519_key.pub
      syncthingId = "MRJSBVI-…";
      roles = ["agent-host" "cache" "desktop"];
    };
    hazel     = { ts4 = "100.126.38.74";   lan = null; sshPort = 7654; hostKey = "…"; roles = ["client"]; };
    maple     = { ts4 = "100.111.5.48";    lan = "192.168.100.10"; sshPort = 7654; hostKey = "…"; syncthingId = "H7H47TV-…"; roles = ["server" "relay"]; };
    peacelily = { ts4 = "100.127.239.128"; lan = "192.168.100.11"; sshPort = 7654; hostKey = "…"; roles = ["server" "agent-host" "gpu"]; };
  };
}
```

```nix
# modules/nixos/features/hosts-registry.nix → flake.nixosModules.hosts-registry (import in `general`)
{self, lib, ...}: {
  flake.nixosModules.hosts-registry = {config, lib, ...}: let
    me = config.networking.hostName;
    others = lib.filterAttrs (n: _: n != me) self.hosts;
    dom = "tail1a9f7c.ts.net";
  in {
    networking.hosts = lib.mkMerge (lib.mapAttrsToList (n: h:
      {${h.ts4} = [n "${n}.${dom}"];}
      // lib.optionalAttrs (h.lan or null != null) {${h.lan} = ["${n}-lan"];}
      // lib.optionalAttrs (h ? cable) {${h.cable} = ["${n}-cable"];}) others);

    programs.ssh.knownHosts = lib.mapAttrs (n: h: {
      publicKey = h.hostKey;
      hostNames = [n "${n}.${dom}" "${n}.local" "${n}-lan" "${n}-cable" h.ts4]
        ++ lib.optional (h ? ts6) h.ts6 ++ lib.optional (h.lan or null != null) h.lan
        ++ lib.optional (h ? cable) h.cable;
    }) (lib.filterAttrs (_: h: h ? hostKey) others);

    programs.ssh.extraConfig = lib.concatStrings (lib.mapAttrsToList (n: h: ''
      Host ${n} ${n}-lan ${n}-cable ${n}.local
        Port ${toString h.sshPort}
        User ${config.preferences.user.name}
        StrictHostKeyChecking yes
    '') others);
  };
}
```

Then: drop hazel's hand-written `matchBlocks`, switch `deploy` to `StrictHostKeyChecking=yes`
(backlog audit item), and generate `services.syncthing.settings.devices.<n>.addresses = ["tcp://${n}-lan:22000" "tcp://${h.ts4}:22000" "dynamic"]`.

Caveat: an /etc/hosts entry for `maple` overrides MagicDNS, so if maple's 100.x ever changes
you get a stale answer. Pinning the IP in the admin console mitigates this. Add a `checks` test that compares
the registry with `tailscale status --json` (manual `just verify-hosts`).

### 3.3 Home DNS server on maple? Verdict: not now

- maple is on Wi-Fi, a recycled laptop and a single box. Making it the resolver for anything but an optional
  private zone creates a new single point of failure. MagicDNS + registry + mDNS already give every name you need.
- If you later want friendly service names on the LAN for non-Tailscale devices (Samsung TV, guests):
  run **Blocky** (stateless, Nix-friendly) or AdGuard Home on maple serving only `home.arpa`. Add it to Tailscale
  as **split DNS** (`home.arpa → 100.111.5.48`) and as the router's secondary DNS. maple down then breaks only
  `*.home.arpa`. Sketch:

```nix
services.blocky = {
  enable = true;
  settings = {
    ports.dns = 53;
    upstreams.groups.default = ["https://cloudflare-dns.com/dns-query" "https://dns.quad9.net/dns-query"];
    customDNS.mapping = { "jellyfin.home.arpa" = "192.168.100.10"; "chat.home.arpa" = "192.168.100.11"; };
    blocking.denylists.ads = ["https://big.oisd.nl/domainswild"];
    blocking.clientGroupsBlock.default = ["ads"];
  };
};
networking.firewall.interfaces.tailscale0.allowedUDPPorts = [53];
networking.firewall.interfaces.wlp0s20f3.allowedUDPPorts = [53]; # maple's Wi-Fi iface name: check
```

---

## 4. Tailscale features to adopt (item 3)

| Feature | Recommendation | Priority |
|---|---|---|
| **Re-auth maple + peacelily** | Offline for 249/202 days. Re-login with a tagged key (below). Disable key expiry on servers (automatic for tagged nodes) | Quick win |
| **Tags + auth keys** | Tag headless nodes `tag:server` (maple, peacelily) and `tag:cloud` (AWS VM, ephemeral). Keep **butternut, hazel and phone user-owned**: Taildrop and `autogroup:self` only work between your own untagged devices. Use an **OAuth client secret** (`tskey-client-…`, scope `auth_keys`, tags) in sops instead of one shared reusable key: it never expires and mints a tagged key per boot | This week |
| **Grants ACL** | Replace allow-all with the policy in §8. Then replace `trustedInterfaces` with explicit `networking.firewall.interfaces.tailscale0.allowedTCPPorts` per feature (backlog audit item). Defence in depth: ACL in the control plane, port list on the host | This week |
| **Tailscale SSH** | Keep it (it is the escape hatch when `authorized_keys` or sshd break). Policy: `check` (re-auth every 12 h) for user-owned devices, `accept` for `tag:server`/`tag:cloud`. sshd:7654 remains for `deploy`/`nix copy` and the offline cable path | This week |
| **`tailscale serve` everywhere** | Every web UI behind loopback + serve HTTPS: T3 (443), OpenCode (8443), LibreChat (peacelily 443 → 3080), Qdrant dashboard (peacelily 6334 → 6333), Syncthing GUI (`:8384` → 127.0.0.1:8384 per host), ntfy, dashboard. Then drop the 0.0.0.0 binds on peacelily (llama-swap needs no HTTPS: keep it on `tailscale0` for OpenCode, or serve it as `https://peacelily…/v1` via `--set-path`). **Never Funnel**: omit the `funnel` nodeAttr | This week to later |
| **Tailscale Services** (`svc:t3`, `svc:chat`) | Stable names that survive moving a service between hosts (e.g. LibreChat to maple). Needs tagged hosts + `autoApprovers.services`. Adopt once the host roles settle | Later |
| **Taildrop** | Works out of the box between your untagged devices (phone ↔ butternut/hazel). `tailscale file get --loop ~/Downloads` as a user service on desktops (operator needed) | Quick win |
| **Exit node** | A home exit node (maple) does *not* bypass ISP blocks (same ISP), but is useful from café/office Wi-Fi for trust and Egyptian-only sites when abroad. To bypass the ISP blocks, use (a) the AWS VM when it is up, (b) a tiny always-on cloud node, or (c) the **Mullvad add-on** (~$5/mo, 5 devices). AWS egress: 100 GB/month free account-wide, then ~$0.09/GB. ADSL upload makes a home exit node slow for others anyway | Later |
| **App connector** | Better than a full exit node for ISP blocks: route only `search.nixos.org`, `*.netlify.app` etc. via a cloud node. Needs `tag:connector` + `nodeAttrs` `tailscale.com/app-connectors`. Everything else stays on the local fast path | Later (with the cloud node) |
| **Subnet router** | maple advertises `192.168.100.0/24` (`useRoutingFeatures = "server"`, `extraUpFlags = ["--advertise-routes=192.168.100.0/24"]`, auto-approve). It lets the phone/hazel reach the router admin page, printer, TV and IP cameras from anywhere. Risk: hazel at home would route LAN traffic via maple unless `--accept-routes` is off on LAN members. Keep `--accept-routes` off on butternut/peacelily, on for hazel and phone | Later |
| **Peer relay** | Home line is easy-NAT with a public IP, so direct mostly works. The hard case is hotspot (carrier CGNAT) ↔ office/café. Make maple a peer relay (`tailscale set --relay-server-port=40000` + router port-forward UDP 40000 → maple + grant). Also port-forward UDP 41641 → maple for guaranteed direct paths to maple | Later |
| **DERP** | Paris 52 ms is fine. No custom DERP needed. Relayed throughput is the problem (DERP is rate-limited), which peer relay solves | — |
| **Tailnet lock** | Valuable (a coordination-server compromise can't inject nodes), but every new/ephemeral node then needs signing (`tailscale lock sign`), which complicates the AWS VM and reinstalls. Adopt **after** the OAuth-client/tag flow is stable. Keep the disablement secrets in KeePassXC | Later |
| **Key expiry** | Keep 180 d on user devices (butternut, hazel, phone). Tagged nodes don't expire. Put a calendar reminder or a Gatus check on `tailscale status --json` `KeyExpiry` | Quick win |
| **Phone** | It has been offline for 31 days. Enable Android "Always-on VPN" for Tailscale, otherwise ntfy-over-tailnet, KDE Connect-over-tailnet and Taildrop all fail silently. Battery cost is small with WireGuard idle | Quick win |

Nix for the tagged headless login (OAuth client):

```nix
# tailscale.nix additions
options.preferences.tailscale.tags = lib.mkOption { type = with lib.types; listOf str; default = []; };
config = {
  services.tailscale = {
    authKeyFile = config.sops.secrets."tailscale_oauth".path;     # tskey-client-…
    authKeyParameters = lib.mkIf (cfg.tags != []) { preauthorized = true; ephemeral = false; };
    extraUpFlags = ["--ssh"] ++ lib.optional (cfg.tags != []) "--advertise-tags=${lib.concatStringsSep "," cfg.tags}";
    extraSetFlags = ["--operator=${user}"];   # every host: captive / serve / file get
  };
};
# maple:      preferences.tailscale.tags = ["tag:server"];   useRoutingFeatures = "server";
# peacelily:  preferences.tailscale.tags = ["tag:server" "tag:gpu"];
# AWS VM:     tags = ["tag:cloud"]; authKeyParameters.ephemeral = true;
```

Declarative serve for peacelily (same pattern as `opencode-tailscale-serve`):

```nix
systemd.services.tailscale-serve-librechat = {
  after = ["tailscaled.service" "tailscaled-autoconnect.service"]; wants = ["tailscaled.service"];
  wantedBy = ["multi-user.target"];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  path = [config.services.tailscale.package];
  script = "tailscale serve --bg --https=443 http://127.0.0.1:3080";
};
services.librechat.env.HOST = "127.0.0.1";
```

Suggestion: factor this into a tiny `preferences.tailscale.serve.<name> = { https = 443; target = "http://127.0.0.1:3080"; }`
option in `tailscale.nix` that generates one oneshot per entry. agent-opencode's unit becomes a user of it.

---

## 5. Cross-device UX (item 4)

| Idea | How | Effort |
|---|---|---|
| **ntfy** | Already wired for agent hooks (ntfy.sh topic in sops). Phase 2: `services.ntfy-sh` on maple behind `tailscale serve` (`https://maple…/`). The phone app subscribes over the tailnet (needs Always-on VPN) and keeps ntfy.sh as a fallback for "home is down" alerts (an alert can't come from the thing that is down) | Low |
| **KDE Connect over Tailscale** | Discovery is broadcast, so it does not cross the tailnet. In the Android app use "Add devices by IP" with butternut's/hazel's 100.x. Then it works from anywhere. Restrict the 1714-1764 ports to `tailscale0` + trusted Wi-Fi (§6.3) | Low |
| **Clipboard / files laptop ↔ laptop** | Taildrop (`tailscale file cp`), sftp over the registry names, KDE Connect clipboard sync (laptop ↔ phone ↔ laptop). For a shared folder, a Syncthing `inbox` folder on butternut/hazel/maple/phone | Low |
| **Phone as Syncthing peer** | Already planned for the vault (Syncthing-Fork). Give it the device ID in the registry. On the phone, set Syncthing to "run on Wi-Fi only + charging" except for the vault folder | Low |
| **Wake-on-LAN** | WoL over Wi-Fi rarely works. **Wire peacelily to the router** (also better for model downloads and LAN serving) and `networking.interfaces.<eth>.wakeOnLan.enable = true`. maple (always on) runs `wakeonlan <mac>`. Trigger from the phone with a Tailscale SSH shortcut (`ssh maple wake peacelily`) or an ntfy action button. BIOS: "Restore on AC power loss = On" for maple and peacelily | Medium |
| **Power-cut awareness** | Gatus/Beszel on maple, plus an **external** check from the cloud node/ntfy.sh ("home ADSL down"). A ~$25 mini UPS/DC-UPS for the router + maple keeps the tailnet node reachable through Egyptian load-shedding cuts | Medium |
| **LAN cache discovery** | Add a tailnet substituter in addition to the cable: `extra-substituters = ["http://10.42.0.1:5000?priority=10" "http://butternut:5000?priority=20"]` (tailscale0 is open to 5000), plus peacelily/maple later (harmonia). Keep `connect-timeout = 3` and `fallback = true`. Nix disables an unreachable substituter for the rest of the run after the first failure, so the cost is ≤3 s per absent cache. Do **not** use mDNS URLs (`.local` may resolve to the Wi-Fi IP where the port is closed, as the module comment notes) | Low |
| **spotifyd / cast** | Spotify Connect zeroconf works only on the same L2. On café Wi-Fi it advertises the device to strangers. Restrict 5353/57622 to trusted networks. Spotify Connect also works through your account (cloud discovery) without zeroconf once logged in | Low |
| **Printing** | Samsung M2070 over Wi-Fi Direct (`DIRECT-8eM2070`). Better: join it to the home Wi-Fi and use IPP Everywhere/driverless via avahi (`services.printing` + `services.avahi.nssmdns4`, already on). Later, maple as a CUPS share | Low |
| **Home dashboard** | `services.homepage-dashboard` (or `glance`) on maple behind `tailscale serve` listing T3/OpenCode/LibreChat/Qdrant/Syncthing GUIs/ntfy/Gatus. Generate the links from `self.hosts` + serve registry | Medium |
| **Health monitoring** | **Gatus** on maple (HTTP/TCP/DNS checks over tailnet names; ntfy alerting; config is pure Nix) + **Beszel** hub on maple, agents on all hosts (CPU/RAM/GPU/disk). Uptime-Kuma is heavier/stateful | Medium |

---

## 6. Resilience & security (item 5)

### 6.1 Failure matrix (after the recommendations)

| Failure | Before | After |
|---|---|---|
| ADSL down | Tailnet across sites dead. LAN names work only via MagicDNS cache | LAN: `*-lan`/`*.local` names via registry/mDNS, Syncthing over LAN, deploy via `.local`. Phone hotspot as backup uplink |
| Tailscale coordination unreachable | Existing sessions OK, fresh boots uncertain | Same, but names resolve from /etc/hosts and the LAN path works without Tailscale |
| tailscaled down | Short names gone, DNS falls back to ISP plaintext | Registry names + resolved with opportunistic DoT + FallbackDNS |
| maple off | Vault backup copy, future ntfy/Gatus offline | Nothing critical depends on maple for DNS (no home resolver in the critical path). ntfy.sh fallback |
| peacelily off | OpenCode llama provider fails | Resolver falls through to Anthropic/butternut (agent design) |
| ISP blocks an IP range | Manual workaround | App connector/exit node on the cloud node |

### 6.2 Firewall posture on untrusted Wi-Fi (butternut, hazel)

Today on any café Wi-Fi: sshd 7654 (password auth **on**), KDE Connect 1714-1764, spotifyd 5353/57622,
Syncthing 22000/21027, Reticulum and (hazel) avahi are reachable by strangers.

1. **Now:** `preferences.ssh.passwordAuthentication = false` once hazel's key is in `ssh-keys.nix` (blocker for this,
   and also needed for café SSH; see §7).
2. **This week:** stop opening ports globally. sshd: `services.openssh.openFirewall = false`, then open 7654 on
   `tailscale0`, `eno2` and trusted Wi-Fi only. Syncthing: `openDefaultPorts = false`, with LAN discovery only on trusted networks
   and peers via tailnet addresses.
3. **Trusted-network mechanism** (NixOS firewall has no zones): an NM dispatcher adds/removes an nftables
   table when a *trusted* connection id comes up/down:

```nix
# modules/nixos/features/trusted-networks.nix
{
  flake.nixosModules.trusted-networks = {config, lib, pkgs, ...}: let
    cfg = config.preferences.trustedNetworks;
    tcp = lib.concatMapStringsSep ", " toString cfg.tcpPorts;
    udp = lib.concatMapStringsSep ", " toString cfg.udpPorts;
  in {
    options.preferences.trustedNetworks = {
      connections = lib.mkOption { type = with lib.types; listOf str; default = ["home" "hotspot"]; };
      tcpPorts = lib.mkOption { type = with lib.types; listOf port; default = []; };   # 7654 22000 57622 1714-…
      udpPorts = lib.mkOption { type = with lib.types; listOf port; default = []; };   # 5353 21027 1716
    };
    config = {
      networking.nftables.enable = true;   # check: the repo uses iptables-nft today; switching is a separate change
      networking.networkmanager.dispatcherScripts = [{
        type = "basic";
        source = pkgs.writeShellScript "trusted-net" ''
          iface=$1 action=$2
          case " ${lib.concatStringsSep " " cfg.connections} " in *" $CONNECTION_ID "*) ;; *) exit 0;; esac
          table="trusted_$iface"
          case $action in
            up) ${pkgs.nftables}/bin/nft -f - <<EOF
          table inet $table { chain input { type filter hook input priority -10; policy accept;
            iifname "$iface" tcp dport { ${tcp} } accept
            iifname "$iface" udp dport { ${udp} } accept } }
          EOF
            ;;
            down) ${pkgs.nftables}/bin/nft delete table inet "$table" 2>/dev/null || true ;;
          esac
        '';
      }];
    };
  };
}
```

   Caveat: an SSID can be spoofed (an evil twin named "home"), but the PSK in the NM profile prevents association
   with a fake AP that lacks it, and the services behind these ports are authenticated anyway. Moving KDE Connect, spotifyd and Syncthing
   off the global allow list is the actual win. If you prefer less machinery, firewalld + NM zones is the
   standard alternative, but it fights the NixOS firewall module.
4. Publish nothing on LAN that can be on tailnet: peacelily already follows this. Apply the same to LibreChat/Qdrant via serve + loopback.
5. **DNS leaks:** with Override-local on, all names go DoH via tailscaled. When Tailscale is down, resolved
   sends to DHCP DNS (opportunistic DoT rarely succeeds against café resolvers). That is acceptable: it is also how
   the captive portal works. For strict mode, make the captive script the only way to drop Tailscale DNS.

---

## 7. Café / portable-compute scenario (feeds rollout step 5)

**Scenario.** butternut (no working screen) and hazel go to a café. butternut boots with a USB stick holding a LUKS keyfile
and should come up headless. The Android hotspot is on and hazel joins it. From hazel: SSH, file browsing (sftp/sshfs/Thunar `sftp://`),
T3 Code over `tailscale serve`, `herdr --remote butternut`, `oc` (OpenCode attach), `deploy`.
**Offline variant:** cable butternut `eno2` ↔ hazel (NM shared, 10.42.0.1).

### 7.1 Status at a glance (ranked by how badly it blocks the scenario)

| # | Item | Status | Blocks |
|---|---|---|---|
| 1 | **butternut has no network profile for the phone hotspot** (and the `home` SSID is wrong) | **[gap]** | everything: butternut never joins a network with no screen |
| 2 | **No user lingering on butternut**: t3code, herdr, opencode and agent-run are *user* units, so they don't start until someone logs in at greetd (impossible headless) | **[gap]** | T3/herdr/oc |
| 3 | **Lid close suspends** (logind default `HandleLidSwitch=suspend`; `…ExternalPower` inherits it; `…Docked=ignore` applies only with an external monitor) | **[gap]** | everything, if the lid is closed in the bag/café |
| 4 | **LUKS unlock needs a typed password on a dead screen** (disko `crypt`, scripted initrd, no keyfile) | **[gap]** | boot |
| 5 | **hazel's SSH key not in `ssh-keys.nix`** (only butternut's). sshd allows passwords, so it works but is weak. Tailscale SSH works without keys | **[risk]** | key-only SSH, `deploy` BatchMode, `herdr --remote` (ssh) |
| 6 | Tailscale on both laptops | **[have]** butternut online. hazel offline 14 d: confirm it's logged in before leaving | T3/oc HTTPS names |
| 7 | T3/OpenCode via `tailscale serve` + operator | **[have] in the working tree, not deployed** (live T3 still binds the tailnet IP; `serve status` is empty). HTTPS certs must be enabled in the admin console | T3/oc |
| 8 | Display detection → headless vs greetd | **[gap]** (design only) | nothing critical (greetd idles), but GPU/session waste and kdeconnect/spotifyd confusion |
| 9 | Initrd SSH unlock fallback | **[gap]** | recovery when the stick is forgotten |
| 10 | "I'm up" notification + IPs | **[gap]** | finding butternut's hotspot IP when Tailscale is unavailable |
| 11 | avahi on the hotspot link | **[gap]** (restricted to eno2) | `.local` names on the hotspot |
| 12 | Cable path (shared mode, avahi on eno2, `lan-cache`, `deploy` via `.local`) | **[have]**, but **[risk]**: shared mode hands hazel a default route (metric 100) that beats its Wi-Fi, see §7.12 | internet on hazel while cabled |
| 13 | Boot fallback with no screen (boot counting) | **[gap]** (systemd-boot boot counting not in 26.05; backlog says 26.11) | recovery from a bad generation |

### 7.2 Unattended LUKS unlock with a USB keyfile (systemd initrd)

Switch butternut to the systemd initrd (`boot.initrd.systemd.enable = true`). It is required for the crypttab `keyfile-timeout`
semantics and integrates with initrd SSH and the password agent.

Prepare the stick (once, by hand): a small ext4/vfat partition labelled `BNKEY`, file `/butternut.key`
(`dd if=/dev/urandom bs=64 count=1`), then `cryptsetup luksAddKey /dev/nvme0n1p2 butternut.key`.
Keep the password slot. Record the partition UUID.

```nix
# modules/nixos/hosts/butternut/boot-unlock.nix
{
  flake.nixosModules.hostButternut = {lib, ...}: {
    boot.initrd.systemd.enable = true;
    boot.initrd.supportedFilesystems = ["vfat" "ext4"];
    boot.initrd.availableKernelModules = ["usb_storage" "uas" "sd_mod" "e1000e"];  # e1000e: eno2 for initrd SSH

    # disko named the mapping "crypt"; it already generates boot.initrd.luks.devices.crypt.device.
    boot.initrd.luks.devices.crypt = {
      # systemd-cryptsetup syntax "<path-in-fs>:<device>": file on the stick, found by UUID.
      keyFile = "/butternut.key:UUID=XXXX-XXXX";
      keyFileTimeout = 10;       # seconds to wait for the stick, then ask for the password
      allowDiscards = true;
    };
  };
}
```

Notes and risks:
- Password fallback after the 10 s timeout appears on the console (dead screen) **and** through the password agent,
  so it can be answered over initrd SSH (§7.3) or blind-typed on the keyboard (works, no feedback).
- The keyfile is a bearer secret: the stick on the keyring, never in the laptop bag (as the design says). Later: FIDO2
  (`systemd-cryptenroll --fido2-device=auto` + `crypttabExtraOpts = ["fido2-device=auto"]`).
  TPM2 auto-unlock is the "no stick at all" option but trades away protection against stolen-laptop attacks unless combined with a PIN.
- Verify that disko doesn't also emit a conflicting `keyFile`. It sets `passwordFile` only for formatting, so this should be fine.

### 7.3 Initrd SSH unlock fallback (over the cable)

```nix
boot.initrd.network = {
  enable = true;
  ssh = {
    enable = true;
    port = 2222;                                  # distinct from 7654 → separate known_hosts entry
    hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];   # generate once; NOT the real host key (lives on unencrypted /boot)
    authorizedKeys = builtins.attrValues self.sshKeys;          # hazel's key must be in ssh-keys.nix
  };
};
# systemd-networkd in the initrd: static address on eno2 (no DHCP server on a bare cable).
boot.initrd.systemd.network = {
  enable = true;
  networks."10-eno2" = {
    matchConfig.Name = "eno2";                    # check the initrd name; match by MAC a0:36:bc:30:d3:e3 to be safe
    address = ["10.42.0.1/24"];
    networkConfig.ConfigureWithoutCarrier = true;
  };
};
```

Usage from hazel (cable plugged; hazel gets no DHCP from initrd, so set a static address once:
`nmcli con add type ethernet ifname <hazel-eth> con-name initrd-cable ipv4.method manual ipv4.addresses 10.42.0.2/24 autoconnect no`):
`ssh -p 2222 root@10.42.0.1` → `systemd-tty-ask-password-agent --query` (or `systemctl default`) → type the LUKS password.
Add the initrd host key to the registry as `butternut-initrd` with a separate `knownHosts` entry.

**Wi-Fi in the initrd: feasible but not recommended.** It needs iwlwifi + firmware blobs in the initrd, wpa_supplicant
and the **Wi-Fi PSK stored in plaintext on unencrypted /boot**. The phone hotspot gives a different IP each time, and you would
also need Tailscale in the initrd to find it. Fragile, leaks secrets, and depends on the phone. Use the cable or the USB key.

The scripted initrd also supports SSH, but staying on systemd initrd keeps a single code path.

### 7.4 Display detection → headless vs greetd

Make greetd conditional instead of isolating targets (simpler, reversible):

```nix
systemd.services.greetd = {
  serviceConfig.ExecCondition = pkgs.writeShellScript "external-display" ''
    for s in /sys/class/drm/card*-*/status; do
      case $s in *eDP*) continue;; esac          # dead internal panel
      [ "$(cat "$s")" = connected ] && exit 0
    done
    exit 1                                        # skipped, not failed: stays headless
  '';
};
# Monitor plugged in later → start greetd.
services.udev.extraRules = ''
  ACTION=="change", SUBSYSTEM=="drm", RUN+="${pkgs.systemd}/bin/systemctl --no-block start greetd.service"
'';
```

The DRM driver must be loaded before greetd evaluates the condition (i915 is in the initrd via `force_probe`. Add
`After = ["systemd-udev-settle.service"]` only if it races in practice; prefer the udev trigger).
**Required companion:** `users.users.${user}.linger = true;` (gap #2) so agent-host user units run with no session.
Gate the desktop-only user units (kdeconnect, spotifyd, sway helpers) on `graphical-session.target`.
They already are mostly (`Requisite=sway-session.target`).

### 7.5 Lid switch (butternut)

```nix
services.logind.settings.Login = {
  HandleLidSwitch = "ignore";              # headless in a café with the lid closed must keep running
  HandleLidSwitchExternalPower = "ignore";
  HandleLidSwitchDocked = "ignore";
};
services.upower = { enable = true; criticalPowerAction = "PowerOff"; percentageAction = 4; };  # on battery: clean shutdown instead of a crash
```

Thermal risk: a closed lid on a 3050 laptop under agent load can heat-soak. Run it lid-open or on a stand when the GPU is in use.

### 7.6 System NM profiles (before login, PSKs from sops)

Extend `wifi-home` into a `wifi-profiles` feature with one sops env file (`secrets/shared/wifi.yaml`:
`WIFI_HOME_SSID`, `WIFI_HOME_PSK`, `WIFI_HOTSPOT_SSID`, `WIFI_HOTSPOT_PSK`, `WIFI_OFFICE_PSK`):

```nix
networking.networkmanager.ensureProfiles.profiles = {
  home = {
    connection = { id = "home"; type = "wifi"; autoconnect = true; autoconnect-priority = 30; };
    wifi = { ssid = "$WIFI_HOME_SSID"; mode = "infrastructure"; };       # today hardcoded "home" ≠ WE_93CBE9
    wifi-security = { key-mgmt = "wpa-psk"; psk = "$WIFI_HOME_PSK"; };
  };
  hotspot = {
    connection = { id = "hotspot"; type = "wifi"; autoconnect = true; autoconnect-priority = 10; metered = "yes"; };
    wifi = { ssid = "$WIFI_HOTSPOT_SSID"; mode = "infrastructure"; };
    wifi-security = { key-mgmt = "wpa-psk"; psk = "$WIFI_HOTSPOT_PSK"; };   # WPA3-only hotspots: key-mgmt = "sae"
    ipv4 = { method = "auto"; dhcp-send-hostname = true; };   # "butternut" appears in the phone's hotspot client list
  };
  office = {
    connection = { id = "office"; type = "wifi"; autoconnect = true; autoconnect-priority = 20; };
    wifi = { ssid = "Transport for Cairo"; mode = "infrastructure"; };
    wifi-security = { key-mgmt = "wpa-psk"; psk = "$WIFI_OFFICE_PSK"; };
  };
};
```

ensureProfiles go to `/run/NetworkManager/system-connections`, so they are system-wide and connect at boot with no
user secret agent. Delete the duplicate imperative `home` profile in `/etc/NetworkManager/system-connections`.
`metered` doesn't stop Syncthing/Nix by itself. Add an NM dispatcher that pauses Syncthing (`syncthing cli config … paused`)
on the hotspot connection, or keep the hotspot off Syncthing's LAN discovery (§6.3 handles ports).

### 7.7 Android hotspot specifics

- **Client isolation:** stock Android/MIUI hotspots generally let clients talk to each other (they are on one bridged
  /24, e.g. `192.168.x.0/24` or a random `10.x` on newer Android). Verify once: `ping <butternut hotspot IP>` from hazel.
- **IPv6:** Android tethers IPv6 only if the carrier gives it (Egyptian mobile carriers: mostly IPv4 CGNAT). Expect IPv4 only.
- **DHCP/DNS:** the phone is the DHCP server and DNS forwarder (its own IP). Leases change between sessions, so do not put hotspot IPs in the registry.
- **MTU:** carrier paths can be <1500. Tailscale's 1280 MTU absorbs this. Plain SSH/sftp over the hotspot LAN never leaves the phone, so no issue.
- **Tailscale path:** both laptops on the same hotspot LAN advertise their 192.168.x endpoints. disco finds the
  **direct LAN path** (no DERP, no mobile data used for the traffic itself), as long as both clients have a fresh
  netmap from control. `tailscale ping butternut` should report `via 192.168.x.y:41641`.
- **Hotspot with poor/no internet:** already-running tailscaled keeps its netmap. MagicDNS still answers
  `butternut`/`*.ts.net` from memory, and a direct LAN path keeps working. A **freshly booted** butternut that never reached
  control has no peers/netmap: Tailscale names and T3 HTTPS fail. The `tailscale serve` cert is cached on disk
  (`/var/lib/tailscale/certs`) and valid ~90 days, but reaching it still needs the WireGuard path. **Plan for the plain-LAN path:**
  sshd 7654 + `butternut.local` (avahi on the hotspot) + the registry. For T3 offline, use an SSH port-forward:
  `ssh -L 3773:127.0.0.1:3773 butternut` → `http://localhost:3773`.
- **mDNS on the hotspot:** yes. Allow avahi on `wlo1` on butternut and gate 5353 via the trusted-networks mechanism (hotspot is trusted).
  The connection id is `hotspot`, so the dispatcher opens 5353/7654 only there. Android's hotspot forwards multicast between clients in practice. Verify with `avahi-resolve -n butternut.local`.

### 7.8 "I'm up" notification + status page

```nix
systemd.services.im-up = {
  description = "Announce butternut is up (ntfy)";
  after = ["network-online.target" "tailscaled.service"]; wants = ["network-online.target"];
  wantedBy = ["multi-user.target"];
  path = with pkgs; [curl iproute2 config.services.tailscale.package jq upower coreutils];
  serviceConfig = { Type = "oneshot"; Restart = "on-failure"; RestartSec = 30; };
  startLimitIntervalSec = 0;
  script = ''
    topic=$(cat ${config.sops.secrets."agents-ntfy-topic".path})
    case $topic in https://*) url=$topic ;; *) url=https://ntfy.sh/$topic ;; esac
    lan=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    ssid=$(nmcli -t -f NAME con show --active | head -1)
    ts=$(tailscale ip -4 2>/dev/null || echo "no tailscale")
    ac=$(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo ?)
    bat=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null || echo ?)
    curl -fsS -H "Title: butternut up ($ssid)" -H "Tags: computer" \
      -d "LAN $lan · TS $ts · AC $ac · battery $bat% · $(systemctl is-system-running)" "$url"
  '';
};
```

The secret needs `owner = root` (the default) or a separate copy. With a hotspot that has no internet the push can't leave.
In that case the phone's hotspot client list (hostname `butternut`) is the fallback, so keep `dhcp-send-hostname` on for the hotspot.
Status page: serve a tiny static page or Gatus endpoint on `https://butternut…/status` via `tailscale serve --set-path /status`,
or use Beszel's agent. The ntfy push is the 90% solution.

### 7.9 Troubleshooting kit (headless boot)

| Stage | Symptom | Access |
|---|---|---|
| systemd-boot | Can't pick a generation (no screen) | `boot.loader.timeout = 3`. Pick blind (arrow keys + Enter; the default is the newest). Better: `bootctl set-oneshot <entry>` from a working system before risky switches, and `deploy hazel test`-style `switch-to-configuration test` (non-persistent) for risky changes. Boot counting arrives in 26.11: adopt it then |
| initrd | Stick missing / LUKS prompt | initrd SSH on cable `10.42.0.1:2222`. `boot.initrd.systemd.emergencyAccess = true` gives a console shell (blind) |
| stage 2 emergency | sshd not running | Rare. Mitigate by testing with `switch-to-configuration test`. Keep the previous generation default via `nixos-rebuild boot` only after a `test` succeeded |
| Network | Didn't join hotspot | Cable to hazel (shared mode does not need butternut's Wi-Fi): `ssh butternut.local` / `ssh 10.42.0.1` |
| Logs | — | journald is persistent: `journalctl -b -1 -p warning`, `journalctl -u NetworkManager -u tailscaled -u greetd -b`. Initrd logs are included in the stage-2 journal of that boot |
| Last resort | — | `programs.wayvnc` is enabled but needs a sway session. Plug in any HDMI display/TV: greetd starts via the udev rule |

### 7.10 Security at the café

- butternut and hazel both expose sshd 7654 on the café Wi-Fi today **with password auth on**. Order:
  add hazel's key → `passwordAuthentication = false` → `openFirewall = false` + open 7654 on `tailscale0`, `eno2` and trusted connections only (`hotspot`, `home`).
- Over the phone hotspot (trusted), plain sshd is fine (key-only). Over café Wi-Fi, use the tailnet only (Tailscale SSH with `check`, or sshd over tailscale0).
- T3/OpenCode never bind non-loopback (working-tree design: correct). OpenCode additionally has its password.
- The initrd SSH host key is readable from /boot. It is a separate key, so a thief who clones it can impersonate only the
  *initrd*, and only to hazel over the cable. Acceptable. Never reuse the real host key there.

### 7.11 End-to-end flow (target state)

1. Power on butternut with the stick → systemd initrd unlocks (keyfile), else the password via initrd SSH over the cable.
2. No external display → greetd skipped. Lingering user services start (t3code, herdr, opencode).
3. NM joins `hotspot` (priority 10; `home`/`office` win when visible). tailscaled connects. `im-up` pushes "LAN 192.168.x.y · TS 100.105.41.75".
4. From hazel on the hotspot: `ssh butternut` (registry → 100.x, direct via the hotspot LAN) or `ssh butternut.local`.
   Files: `sftp://butternut/home/hfahmi` in Thunar (uses ssh config + port), or `sshfs butternut: ~/mnt/bn`.
   T3: `https://butternut.tail1a9f7c.ts.net/`. OpenCode: `oc`. herdr: `herdr --remote butternut`. Deploy: `deploy butternut`.
5. Offline cable: `ssh butternut.local` / `butternut-cable`, `ssh -L 3773:…` for T3, `deploy` already prefers `.local`.

### 7.12 Preferred topology: cable for LAN, phone hotspot for internet

User preference: **butternut ↔ hazel over the ethernet cable for all local traffic** (SSH, file copy, T3, herdr),
**the phone hotspot for internet** on *both* laptops (hazel over Wi-Fi always, butternut auto-joins it because its agents need internet).

```
             phone hotspot (internet, 192.168.x.0/24, DHCP from the phone)
               ▲ Wi-Fi                         ▲ Wi-Fi
            hazel ───────── cable 10.42.0.0/24 ───────── butternut
          10.42.0.2 (no gateway)            10.42.0.1 (no gateway)
```

#### (1) The default-route trap **[gap, today's config has it]**

Today butternut's `ethernet-share` profile is `ipv4.method = shared`. NM runs dnsmasq on eno2 and hands hazel a DHCP lease
**with a default gateway (10.42.0.1) and DNS**. hazel's auto "Wired connection 1" installs that default route at
metric **100** (ethernet), beating Wi-Fi at **600**. So hazel's internet goes hazel → cable → butternut NAT → butternut's
uplink. That is fine if butternut has internet, but it is a **black hole** when butternut's Wi-Fi is down or still booting, and a pointless double hop
when both are on the same hotspot. hazel's DNS also gets 10.42.0.1 (butternut's dnsmasq) as a link DNS.

Two fixes:

- **A. Keep shared mode, neuter it on hazel:** a declarative hazel profile with `ipv4.never-default = true`,
  `ipv4.ignore-auto-dns = true`, `ipv6.never-default = true`. Minimal change, but it still depends on butternut's dnsmasq/DHCP being up,
  hazel's address is dynamic (10.42.0.x), and there are firewall holes 53/67 on eno2.
- **B. Pure point-to-point link (recommended):** static addresses on both ends, **no gateway, no DHCP, no NAT, no dnsmasq**.
  Deterministic (`10.42.0.1` ↔ `10.42.0.2`), up the instant the carrier appears, identical to the initrd SSH address (§7.3),
  works with zero internet/DNS/Tailscale/mDNS, and removes the 53/67 holes. Shared mode becomes an explicit, *non-autoconnect* fallback (5).

Recommendation: **B**. Turn `ethernet-share` into a `cable-link` feature with a `mode` option:

```nix
# modules/nixos/features/cable-link.nix  (replaces ethernet-share; lan-cache's 10.42.0.1 default stays valid)
{
  flake.nixosModules.cable-link = {config, lib, ...}: let
    cfg = config.preferences.cable;
    base = id: {
      connection = { inherit id; type = "ethernet"; } // lib.optionalAttrs (cfg.interface != null) { interface-name = cfg.interface; };
      ethernet = {};
      ipv6 = { method = "link-local"; addr-gen-mode = "stable-privacy"; };   # never a v6 default route
    };
  in {
    options.preferences.cable = {
      interface = lib.mkOption { type = with lib.types; nullOr str; default = null; };   # null: any wired NIC
      address   = lib.mkOption { type = lib.types.str; example = "10.42.0.1/24"; };
    };
    config = {
      networking.networkmanager.ensureProfiles.profiles = {
        # Default: pure link, autoconnects on carrier.
        cable = lib.recursiveUpdate (base "cable") {
          connection = { autoconnect = true; autoconnect-priority = 50; };
          ipv4 = {
            method = "manual";
            address1 = cfg.address;          # no gateway field → no default route
            never-default = true;            # belt and braces
            ignore-auto-dns = true;
            may-fail = false;
          };
        };
        # Fallback: share THIS host's internet over the cable (manual: nmcli con up cable-share).
        cable-share = lib.recursiveUpdate (base "cable-share") {
          connection.autoconnect = false;
          ipv4 = { method = "shared"; address1 = cfg.shareAddress; };
        };
        # Fallback: take internet FROM the peer (manual: nmcli con up cable-uplink).
        cable-uplink = lib.recursiveUpdate (base "cable-uplink") {
          connection.autoconnect = false;
          ipv4 = { method = "auto"; route-metric = 700; };   # still loses to any Wi-Fi uplink
        };
      };
      # DHCP/DNS for cable-share only when that profile is active: NM's dnsmasq needs 53/67.
      networking.firewall.interfaces.${cfg.interface or "eno2"} = { allowedUDPPorts = [53 67]; allowedTCPPorts = [53]; };
    };
  };
}
# butternut: preferences.cable = { interface = "eno2"; address = "10.42.0.1/24"; shareAddress = "10.42.0.1/24"; };
# hazel:     preferences.cable = { interface = "<hazel NIC, check `ip link`>"; address = "10.42.0.2/24"; shareAddress = "10.42.1.1/24"; };
```

(Add the `shareAddress` option next to `address`. The sketch elides it.) On hazel, also delete or neuter NM's auto
"Wired connection 1": `networking.networkmanager.settings.main.no-auto-default = "*"` stops NM from generating it, so the
declarative `cable` profile (priority 50) is the only wired candidate.

#### (2) Fixed, internet-independent names over the cable **[gap]**

- Registry (§3.2): `butternut.cable = "10.42.0.1"`, `hazel.cable = "10.42.0.2"`. These become /etc/hosts `butternut-cable` / `hazel-cable`
  and known_hosts entries on both ends. That gives no DNS, no mDNS and no Tailscale involved.
- **Automatic cable preference for the plain `butternut` name** in hazel's ssh config, so `ssh butternut`, `sftp://butternut`
  (gvfs/Thunar spawn `ssh` and honour `~/.ssh/config`), `herdr --remote butternut`, `sshfs butternut:` and `deploy` all take the
  cable when it is up and the tailnet otherwise:

```nix
# generated by hosts-registry on hosts that have a `cable` peer (hazel)
programs.ssh.extraConfig = ''
  Match originalhost butternut exec "ip -4 -o addr show to 10.42.0.0/24 | grep -q ."
    HostName 10.42.0.1
    HostKeyAlias butternut
  Host butternut butternut-cable
    Port 7654
    User hfahmi
    StrictHostKeyChecking yes
'';
```

  `HostKeyAlias` keeps one known_hosts identity for every path. `deploy`'s candidate list becomes
  `butternut-cable butternut.local butternut`.
- Firewall: in link mode the cable is an ordinary interface, so open sshd and friends on it explicitly
  (`networking.firewall.interfaces.eno2.allowedTCPPorts = [7654 5000]` on butternut, and 7654 on hazel's NIC), or add it to
  `trustedInterfaces` on both ends. A physical cable between your own two machines is a reasonable trust boundary.

#### (3) Tailscale over the cable vs the hotspot

- Both nodes advertise all local endpoints (hotspot 192.168.x.y and cable 10.42.0.x) to control. disco probes all of them
  and magicsock moves to the **lowest-latency** working path (with some hysteresis). The cable (sub-ms, no Wi-Fi airtime contention)
  normally wins over the hotspot Wi-Fi. **No `--advertise-routes` or endpoint flags are needed.** Advertising 10.42.0.0/24 would be wrong:
  it is not a routed subnet.
- Verify after connecting: `tailscale ping butternut` → `pong … via 10.42.0.1:41641`, and `tailscale status` shows `direct 10.42.0.1:41641`.
  If it sticks to the hotspot path, `tailscale debug restun`/re-ping usually re-evaluates. As a last resort, use the plain-IP path.
- So T3 Code (`https://butternut.tail1a9f7c.ts.net/`) and `oc` ride the cable *inside* WireGuard automatically. Throughput over the cable with
  WireGuard is hundreds of Mbit/s on these CPUs, which is plenty. For bulk copies, prefer plain sftp/rsync to `butternut-cable` (no WireGuard, no MTU 1280).
- Caveat: Tailscale needs a fresh netmap. If the hotspot has no internet at boot, Tailscale names may not work (§7.7). The ssh `Match` path and an
  `ssh -L 3773:127.0.0.1:3773 butternut-cable` tunnel for T3 are the offline answers.

#### (4) butternut on the hotspot (and remote control from hazel) **[gap]**

- Profile as in §7.6 (sops `WIFI_HOTSPOT_SSID/PSK`). **Priorities: `home` 30 > `office` 20 > `hotspot` 10.** NM picks the
  highest-priority *visible* network. At a café only the hotspot is known, so it wins anyway. At the office or at home the phone's
  mobile data is never used just because the hotspot happens to be on. Mark it `connection.metered = "yes"`.
- No route conflict on butternut: the only default route is Wi-Fi (cable has none in link mode).
- Remote control from hazel over the cable: the user is in the `networkmanager` group and NixOS's NM polkit rule grants that group
  NM actions without an active session, so **no doas is needed**:
  `ssh butternut-cable nmcli con up hotspot`, `… nmcli con down hotspot`, `… nmcli -t dev wifi list --rescan yes`,
  `… nmcli dev wifi connect "<café SSID>" password '…'` (one-off café Wi-Fi, stored root-only in /etc/NetworkManager).
  Add a `bn-net` helper on hazel wrapping these.
- Because control happens over the cable, a bad Wi-Fi change can't lock you out of butternut (it would over Tailscale-on-Wi-Fi).

#### (5) Fallback: hazel shares its internet to butternut

When: butternut can't join the hotspot (Android client cap, 2.4/5 GHz band mismatch, weak signal at the table), or to save
phone battery and data by having one hotspot client. Then hazel runs `cable-share` and butternut runs `cable-uplink`:

```
# from hazel (still on the cable link; the order matters, the link drops briefly)
ssh butternut-cable 'nmcli con up cable-uplink' ; nmcli con up cable-share
# back
nmcli con up cable ; ssh 10.42.1.x 'nmcli con up cable'   # or wait: butternut's cable-uplink DHCP fails, then `cable` autoconnects
```

Role-flip risks and guards:
- **Address collision:** hazel's share subnet is `10.42.1.1/24`, *different* from butternut's 10.42.0.1. A half-flipped state
  (one end static, the other shared) can't produce two hosts claiming 10.42.0.1.
- **Two DHCP servers** (both ends `cable-share`) gives no usable address on either. Never autoconnect any shared profile. A `cable-mode {link|hazel-shares|butternut-shares}`
  script on hazel that drives both ends over SSH keeps the pair consistent.
- **Losing the SSH path mid-flip:** run the remote half with `systemd-run --on-active=5 nmcli con up cable-uplink` so the command
  survives the link drop. The fallback is `ssh butternut.local` (avahi on eno2 resolves whichever address butternut has).
- In hazel-shares mode, butternut's address is dynamic (10.42.1.x), so `butternut-cable` (10.42.0.1) breaks until you flip back. Use
  `butternut.local`. hazel's `lan-cache` URL (10.42.0.1:5000) also fails, but Nix falls back after `connect-timeout = 3`.
- butternut-shares mode (today's behaviour) remains available for home use without Wi-Fi on hazel: `nmcli con up cable-share` on butternut,
  `cable-uplink` on hazel.

#### Gaps for rollout step 5 (implementation order)

1. `cable-link` feature (link mode default, share/uplink as manual profiles) on both laptops; `no-auto-default` on hazel; firewall on the cable interfaces.
2. Registry `cable` addresses → /etc/hosts, known_hosts, ssh `Match … exec` cable preference with `HostKeyAlias`; `deploy` candidates `-cable` first.
3. `wifi-profiles` with `home` (correct SSID), `office`, `hotspot` (priorities 30/20/10, metered hotspot) from sops on butternut **and** hazel.
4. butternut: linger, lid ignore, systemd initrd + USB keyfile + initrd SSH on 10.42.0.1 (matches the link address), greetd ExecCondition, `im-up`.
5. Helpers on hazel: `bn-net` (nmcli over the cable), `cable-mode` (flip both ends safely), `captive`.
6. Verification checklist: `ip route` on hazel shows exactly one default (wlan); `ssh butternut` uses 10.42.0.1 with the cable in and 100.x without it;
   `tailscale ping butternut` goes via 10.42.0.1; T3 loads; unplug the cable, everything continues over the hotspot; reboot butternut
   without the stick → initrd SSH unlock over the cable works.

---

## 8. Tailscale policy draft (HuJSON)

```hujson
{
  // Owners of tags: only the admin (you) can apply them; OAuth client for headless nodes.
  "tagOwners": {
    "tag:server":    ["autogroup:admin"],   // maple, peacelily
    "tag:gpu":       ["autogroup:admin"],   // peacelily
    "tag:cloud":     ["autogroup:admin"],   // AWS agent VM (ephemeral), cloud Syncthing peer
    "tag:connector": ["autogroup:admin"],   // app connector / exit for ISP blocks (cloud box)
  },

  "grants": [
    // You → all your own devices (butternut, hazel, phone stay user-owned for Taildrop).
    {"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]},

    // You → servers and cloud agents: everything (SSH, web UIs, llama-swap…).
    {"src": ["autogroup:member"], "dst": ["tag:server", "tag:cloud"], "ip": ["*"]},

    // Servers ↔ servers: Syncthing, nix cache, SSH for deploy, ntfy, Gatus probes.
    {"src": ["tag:server"], "dst": ["tag:server"],
     "ip": ["tcp:22000", "udp:22000", "tcp:5000", "tcp:7654", "tcp:443", "tcp:80"]},

    // Servers → your devices: health checks + Syncthing only (not SSH).
    {"src": ["tag:server"], "dst": ["autogroup:member"], "ip": ["tcp:22000", "udp:22000", "icmp:*", "tcp:443"]},

    // Cloud agent VM → home: binary cache, llama-swap, git over SSH to maple (if used); nothing else.
    {"src": ["tag:cloud"], "dst": ["tag:server"], "ip": ["tcp:5000", "tcp:9292", "tcp:22000", "udp:22000"]},
    {"src": ["tag:cloud"], "dst": ["tag:gpu"],    "ip": ["tcp:9292"]},

    // Internet via exit nodes / app connectors (for you only).
    {"src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"]},

    // Home LAN via maple's subnet route (printer, router UI, TV).
    {"src": ["autogroup:member"], "dst": ["192.168.100.0/24"], "ip": ["*"]},

    // Peer relay on maple usable by your devices and cloud nodes.
    {"src": ["autogroup:member", "tag:cloud"], "dst": ["tag:server"],
     "app": {"tailscale.com/cap/relay": []}},
  ],

  "ssh": [
    // Own devices: re-authenticate in the browser every 12 h.
    {"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"],
     "users": ["autogroup:nonroot"], "checkPeriod": "12h"},
    // Servers/cloud: accept as the primary user (never root).
    {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:server", "tag:cloud"],
     "users": ["hfahmi"]},
  ],

  "autoApprovers": {
    "routes":   {"192.168.100.0/24": ["tag:server"]},
    "exitNode": ["tag:server", "tag:connector", "tag:cloud"],
    // "services": {"svc:t3": ["autogroup:member"], "svc:chat": ["tag:server"]},  // when adopting Tailscale Services
  },

  // App connector for ISP-blocked destinations (requires a tag:connector node).
  "nodeAttrs": [
    {"target": ["*"], "app": {"tailscale.com/app-connectors": [
      {"name": "egypt-blocked", "connectors": ["tag:connector"],
       "domains": ["search.nixos.org", "nixos-search.netlify.app"]}
    ]}},
  ],

  "tests": [
    {"src": "tag:cloud",  "accept": ["tag:gpu:9292", "tag:server:5000"], "deny": ["tag:server:7654"]},
    {"src": "tag:server", "deny": ["autogroup:member:7654"]},
  ],
}
```

Notes: `autogroup:self` covers only untagged devices you own. The `check` SSH rule makes `ssh` from hazel to butternut over
*Tailscale SSH* prompt periodically, while sshd:7654 (key-based, used by `deploy`/`nix copy`/herdr) is unaffected.
Test the policy in the admin console's preview before saving. Funnel is denied by default because no `funnel` nodeAttr is granted.

---

## 9. Prioritised plan

### Quick wins (≤ 1 hour each)
1. Re-auth **maple** and **peacelily** on Tailscale. Turn on Android **Always-on VPN**. Check hazel is still logged in.
2. Add hazel's key to `ssh-keys.nix` → set `passwordAuthentication = false` everywhere.
3. butternut: `users.users.hfahmi.linger = true` and the lid-switch `ignore` settings (§7.5).
4. Fix the `home` profile SSID (sops `WIFI_HOME_SSID`) and add the `hotspot` profile (§7.6).
5. Enable HTTPS certificates in the tailnet admin console. Deploy the serve-based T3/OpenCode modules.
6. `captive` helper + `--operator` on all desktop hosts.
7. Taildrop receiver user service on butternut/hazel.

### This week
8. `dns` feature (systemd-resolved) on all hosts. Verify nsswitch and captive portals.
9. `hosts-registry` (/etc/hosts, ssh config, known_hosts → `deploy` StrictHostKeyChecking=yes, Syncthing addresses).
10. OAuth-client tagged auth for maple/peacelily. Grants ACL (§8). Replace `trustedInterfaces` with explicit tailscale0 ports.
11. Café firewall posture: sshd/Syncthing/KDE Connect/spotifyd off the global allow list, via the trusted-networks dispatcher.
12. Café scenario core: `cable-link` (pure static link, §7.12), systemd initrd + USB keyfile + initrd SSH on eno2, greetd ExecCondition, `im-up`.
13. Second substituter `http://butternut:5000` over the tailnet for hazel.

### Later
14. maple: subnet router + peer relay (+ router UDP port-forwards 40000/41641), ntfy-sh, Gatus + Beszel, homepage dashboard.
15. peacelily: wire to the router, WoL via maple, LibreChat/Qdrant behind `tailscale serve`, bind to loopback.
16. Tiny cloud node (`tag:connector` + `tag:cloud`): app connector for ISP blocks, exit node, encrypted Syncthing peer, external uptime probe.
17. Tailscale Services names, tailnet lock, systemd-boot boot counting (26.11), FIDO2 LUKS.
18. Optional: NextDNS as the Tailscale global resolver (phone ad-blocking). Blocky on maple for `home.arpa` only if you need non-tailnet devices to resolve names.

---

## 10. Open questions for the user

1. Is `WE_93CBE9` the home network (so `home` should use that SSID), and is `WE_BCEEB8` a second AP/extender?
2. Will peacelily be **wired** at home? (It matters for WoL, LAN serving and model downloads.) Can maple be wired too?
3. Does the WE router allow DHCP reservations and UDP port-forwards (for peer relay/direct paths to maple)?
4. Phone hotspot SSID/security (WPA2 vs WPA3-SAE), and is it OK to keep Tailscale always-on on the phone?
5. Is a ~€4/month always-on cloud box acceptable (app connector + exit + Syncthing peer + external monitoring), or should all of that wait for the on-demand AWS VM? Mullvad add-on as an alternative?
6. Tailscale SSH `check` mode: acceptable to re-auth every 12 h from hazel, or `accept` for own devices too?
7. Keep the tailnet name and 100.x IPs in the public repo (registry), or move the registry values into sops/a private flake input?
8. butternut at the café: lid open on a stand (thermals) or closed? On battery or always with the charger?
9. Do you want hazel to act as cable *host* in reverse (hazel shares eno → butternut), e.g. when hazel has the Wi-Fi and butternut does not?

## Sources

- Tailscale DNS (DoH for public global nameservers, split DNS): https://tailscale.com/kb/1054/dns
- Tailscale NextDNS integration: https://tailscale.com/docs/integrations/nextdns
- Tailscale peer relays (`--relay-server-port`, `tailscale.com/cap/relay` grant): https://tailscale.com/docs/features/peer-relay , GA Feb 2026: https://tailscale.com/blog/peer-relays-ga
- Option names checked against the pinned nixpkgs (`ak757c8k…-source`): `services.resolved.settings.Resolve`, `boot.initrd.luks.devices.<n>.keyFileTimeout`, `boot.initrd.network.ssh`, `services.tailscale.{authKeyParameters,extraSetFlags,useRoutingFeatures}`, `services.{blocky,adguardhome,gatus,beszel-*,ntfy-sh,homepage-dashboard,glance}`. No systemd-boot boot-counting option in 26.05.
