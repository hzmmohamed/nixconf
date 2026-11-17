# Your action list — config refresh (2026-11-17)

Everything that needs you: commands to run, things to paste, settings to click.
Work top to bottom. Tick items off as you go (`[ ]` → `[x]`).

---

## 1. Switch butternut to the new config

- [ ] Wait for Claude to confirm the combined build succeeded (the NVIDIA kernel module compiles locally the first time).
- [ ] Switch:

  ```sh
  doas nixos-rebuild switch --flake ~/nixconf#butternut
  ```

- [ ] **Reboot** (new kernel 7.3.4, NVIDIA driver, keyring change). A re-login is not enough this time.

**If login fails after reboot:** pick the previous generation in the boot menu, then tell Claude.
Most likely cause: sway can't find `/dev/dri/igpu` → remove the `WLR_DRM_DEVICES` line in
`modules/nixos/hosts/butternut/gpu.nix`.

## 2. Check it works (after reboot)

Run these and look at the results:

```sh
nvidia-smi                                                   # RTX 3050 listed
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status   # active
powerprofilesctl get                                         # performance
pgrep -a gnome-keyring                                       # exactly ONE daemon
systemctl --user status waybar --no-pager | head -3          # active (running)
xdg-mime query default image/png                             # org.gnome.Loupe.desktop
```

On screen:

- [ ] Waybar is on the right at login, without waiting for sunset
- [ ] `Mod4+Shift+b` hides/shows the bar
- [ ] `Mod4+Space` opens vicinae; `Mod4+v` opens clipboard history; `Mod4+.` emoji picker types into the window
- [ ] Lock screen (`swaylock`) is themed, not white
- [ ] Chromium no longer asks for your password
- [ ] Notifications: swaync (`Mod4+Shift+n` notification centre, `Mod4+n` do-not-disturb)
- [ ] `darkman toggle` switches bar, launcher and GTK apps between light and dark
- [ ] Double-click an image / PDF / folder / video → Loupe / zathura / Thunar / mpv
- [ ] Apps open on their workspace (browser → 4, editor → 5, QGIS → 6, mixer → 3, files/office → 2)

## 3. One-time audio fix

```sh
rm ~/.local/state/wireplumber/default-nodes
systemctl --user restart wireplumber
```

- [ ] Open the mixer (right-click the volume icon in the bar) → Configuration tab → set the Intel HDA
      card's profile to **Off** (it only exposes unused HDMI outputs and was hijacking fallback).
- [ ] Test: connect the Bluetooth headset → becomes default; disconnect → falls back to the speakers.

## 4. Spotify on butternut

- [ ] Open Spotify on your iPhone → device picker → choose **butternut** (first time signs it in).
      If it doesn't appear: `spotifyd authenticate` in a terminal and follow the link.
- [ ] Bar media widget shows the track and controls it.

## 5. Email

- [ ] Google Cloud console → your OAuth project → **OAuth consent screen** → if "Testing", click
      **Publish app** (Testing mode expires refresh tokens every 7 days).
- [ ] Re-authorise:

  ```sh
  email-oauth2 setup personal
  email-oauth2 setup work
  systemctl --user restart imapnotify-personal imapnotify-work
  ```

- [ ] Gmail web → Settings → **Labels** → "All Mail" → untick **Show in IMAP**.
- [ ] Thunderbird → Settings → Privacy & Security → Passwords → untick **Use a Primary Password**
      (asks for the current one once).

## 6. Disk space (before the Immich pilot)

Disk is ~90% full. Reclaim Docker build cache (~200 GB):

```sh
docker builder prune
# only if nothing important lives in volumes:
docker volume prune
```

## 7. Security rollout (do in this order; keep an SSH session open while testing)

**a. hazel's key**

- [ ] On hazel: `cat ~/.ssh/id_ed25519.pub` → paste into `modules/ssh-keys.nix` (or give it to Claude).
- [ ] Switch every host (peacelily too). Then from butternut **and** hazel, for each host:

  ```sh
  ssh -p 7654 -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no <host>
  ```

**b. Turn off SSH passwords**

- [ ] Set `preferences.ssh.passwordAuthentication = false;` (in `modules/nixos/features/openssh.nix`
      or per host), switch, re-test each host.

**c. New login password from sops** (must be different from the current one — the old hash is
public in git history)

- [ ] Generate a hash:

  ```sh
  mkpasswd -m yescrypt
  ```

- [ ] Add secrets:

  ```sh
  sops ~/nixconf/secrets/shared/user.yaml
  ```

  ```yaml
  user-hashed-password: <paste the hash>
  syncthing-gui-password: <a new password>
  ```

- [ ] `git -C ~/nixconf add secrets/shared/user.yaml`
- [ ] Set `preferences.user.passwordFromSops = true;` and `preferences.syncthing.guiPasswordFromSops = true;`, switch.
- [ ] Verify: `ls /run/secrets-for-users/user-hashed-password`, then log out/in, `doas true`,
      keyring unlocks, Syncthing GUI login works.
- [ ] Tell Claude to delete the committed hash and the `"password"` fallback.

**d.** Decide whether to keep **Tailscale SSH** (`--ssh` in `tailscale.nix`) — a second way in that bypasses sshd.

## 8. Answers Claude still needs

- [ ] **Immich pilot:** where do your photos/videos live (which drives, roughly how big, mounted on butternut?)
- [ ] After a week: **waybar vs Noctalia** — flip `preferences.desktopShell = "noctalia";` in
      `modules/nixos/hosts/butternut/configuration.nix`, switch, compare.
- [ ] Hazel/maple still keep Telegram/Element/Obsidian etc. via opt-in lines — remove there too?
- [ ] OpenRGB: if the boot profile fights the ASUS keyboard lighting, set `preferences.openrgb.profile = null;`.

## Handy commands for later

```sh
, freecad          # run an on-demand app (also: , obs  , blender  , vlc  , digikam)
sudo systemctl start ollama          # local LLMs (not started at boot any more)
systemctl --user start rnsd          # Reticulum
nvidia-offload blender               # render on the RTX 3050
```

## 9. Hazel over ethernet

Goal: plug a cable between butternut (`eno2`) and hazel, run `deploy hazel` on butternut.
butternut shares its port (DHCP + NAT, butternut = `10.42.0.1`), both announce `<host>.local`
over mDNS, and hazel pulls from butternut's nix-serve cache over the cable first.

**a. Switch butternut** (with section 1, or on its own later) — this adds the shared
ethernet profile, avahi and the `deploy` command.

- [ ] Verify the cache signing key matches the one hazel will trust:

  ```sh
  doas cat /run/secrets/nix-serve-secret-key | nix key convert-secret-to-public
  # must print: butternut:uXXUBdRO9KP5DDdmrN80171HDGjqRB5zsey1I7Db8XM=
  ```

  If it differs, put the printed key in `flake.nixServeKeys.butternut`
  (`modules/nixos/features/nix-serve.nix`) before switching hazel.

**b. Switch hazel once locally** — it does not have butternut's SSH key, avahi or the cache yet.

- [ ] On hazel, get the current repo (`git -C ~/nixconf pull`, or copy it over the cable:
      plug in, then from butternut `rsync -a -e 'ssh -p 7654' ~/nixconf/ <you>@<hazel-ip>:nixconf/` —
      hazel's IP: `cat /var/lib/NetworkManager/dnsmasq-eno2.leases` on butternut (10.42.0.x);
      password login still works at this point), then:

  ```sh
  doas nixos-rebuild switch --flake ~/nixconf#hazel
  ```

- [ ] Add hazel's own key for reverse access: on hazel `cat ~/.ssh/id_ed25519.pub`
      (create with `ssh-keygen -t ed25519` if missing) → `hazel = "...";` in `modules/ssh-keys.nix`
      (same as 7a).

**c. Test the cable** (cable plugged in, both switched)

```sh
nmcli device                       # butternut: eno2 connected (ethernet-share)
ping -c2 hazel.local               # from butternut
ssh -p 7654 hazel.local true       # no password prompt
curl http://10.42.0.1:5000/nix-cache-info   # from hazel: StoreDir: /nix/store ...
```

**d. Deploy from butternut**

```sh
deploy hazel           # build here, copy over the cable, show diff, switch
deploy hazel boot      # or: test / dry-activate
just deploy hazel      # same, from ~/nixconf (if `just` is installed)
```

It tries `hazel.local` first, then `hazel` (Tailscale / /etc/hosts), SSH port 7654.

Notes:
- While the cable is in, hazel's default route goes through butternut (NM's wired metric 100 beats
  wifi 600); internet still works via butternut's NAT. Unplug to go back to wifi.
- Off the cable, hazel tries `10.42.0.1` for at most 3 s, then uses cache.nixos.org as usual.

## Gaming

Module: `modules/nixos/features/gaming.nix` (butternut only). Steam always runs games on the RTX
3050 (PRIME offload env baked into the `steam` wrapper), so no per-game launch options needed.

**Xbox controller**
- USB: just plug it in (kernel `xpad` driver). Check with `evtest-qt`.
- Bluetooth (xpadneo + BlueZ `Privacy=device`, `JustWorksRepairing=always`, `FastConnectable`):
  1. Update controller firmware first if you can (Xbox Accessories app on Windows/Xbox); old
     firmware is the usual reason pairing fails.
  2. `bluetoothctl` → `power on`, `agent on`, `default-agent`, `scan on`.
  3. Hold the pair button on top of the controller until the Xbox logo flashes fast.
  4. `pair <MAC>`, `trust <MAC>`, `connect <MAC>`, `scan off`. (Or use blueman-manager.)
  5. If it connects then drops in a loop: `bluetoothctl remove <MAC>` and pair again.
     Fallback to try: add `Class = "0x000100"` to `hardware.bluetooth.settings.General`.
  6. Xbox Wireless Adapter (USB dongle) would need `hardware.xone.enable` instead (not set).

**Steam first run**
- Your Steam library on butternut is empty (only the client, 4.3 GB); reinstall games from Steam.
- Proton-GE: Steam → Settings → Compatibility → "Enable Steam Play for all other titles" → pick
  `GE-Proton…`. Per game: Properties → Compatibility.
- Launcher entries: game → Manage → "Add desktop shortcut" writes a `.desktop` to
  `~/.local/share/applications`, which vicinae picks up.
- Optional per game: launch options `gamemoderun %command%` or `mangohud %command%`.
- SteamOS-like mode: pick "Steam (gamescope)" in tuigreet's session list (F3). tuigreet remembers
  the last session, so switch back to Sway the same way. Experimental on this hybrid GPU: if it
  shows a black screen, Ctrl+Alt+F2 → log in → `sudo systemctl restart greetd`.

**Lutris / BioShock Remastered (GOG)**
- Wine prefix with the game is at `~/Games/gog/bioshock-remastered` (22 GB), but Lutris's DB lists it
  as not installed. In Lutris: BioShock → Install → "locally installed", point it at that prefix
  (exe: `drive_c/GOG Games/BioShock Remastered/Build/Final/BioshockHD.exe`).
- For the dGPU: game → Configure → System options → "Enable NVIDIA Prime Render Offload".
- Right-click game → "Create application menu shortcut" for vicinae.

**PS2 (PCSX2)**
- BIOS is already in `~/.config/PCSX2/bios` (SCPH-77008 selected). Never download BIOS files.
- ISOs: `~/Downloads/GTASA/Grand Theft Auto - San Andreas (USA) (v3.00).iso` (4.3 GB), plus NBA 2K12
  and PES 2014 under `~/Downloads`. In PCSX2: Settings → Game List → add `~/Downloads` (recursive),
  or launch them from Lutris (existing PS2 entries).
