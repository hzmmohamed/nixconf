# Your action list — config refresh (2026-11-17)

Everything that needs you: commands to run, things to paste, settings to click.
Work top to bottom. Tick items off as you go (`[ ]` → `[x]`).

---

## 1. Switch butternut to the new config

- [ ] Wait for Claude to confirm the combined build succeeded (the NVIDIA kernel module compiles locally the first time).
- [ ] Activate the verified build (kernel 6.18.63 LTS + NVIDIA 595.71, built 2026-11-17).
      Use the store path directly while other work is in progress in the repo:

  ```sh
  doas nix-env -p /nix/var/nix/profiles/system --set /nix/store/z3xb3d4a5m766sdq3xzr8p0b03i1k7dv-nixos-system-butternut-26.05.20261115.b349185
  doas /nix/store/z3xb3d4a5m766sdq3xzr8p0b03i1k7dv-nixos-system-butternut-26.05.20261115.b349185/bin/switch-to-configuration boot
  ```

  (Later, normal switching is `doas nixos-rebuild switch --flake ~/nixconf#butternut`.)

- [ ] **Reboot** (kernel 7.2 → 6.18 LTS, NVIDIA driver, keyring change). A re-login is not enough this time.

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

## Agentic workspace (T3 Code, OpenCode)

- [ ] Tailscale admin console: MagicDNS + HTTPS certificates enabled (done 2026-11-17)
- [ ] Logins on butternut: `claude auth login`, `opencode auth login claude-agent`, `glab auth login`
- [ ] T3 Code UI: `https://butternut.tail1a9f7c.ts.net/` — OpenCode UI: `https://butternut.tail1a9f7c.ts.net:8443` (or `oc` in a terminal)
- [ ] Pair each device with T3 Code (token valid 5 min, scan the QR or paste the token):

  ```sh
  t3-pair phone            # = t3 pair --base-dir ~/.t3 --tailscale --tailscale-serve-port 443 --label phone
  t3-pair hazel-desktop    # then turn off "Local environment" in hazel's T3 app
  ```

- [ ] If the T3 Code link fails after a reboot: `tailscale serve status` should list `/ proxy http://127.0.0.1:3773`;
      if missing, `systemctl --user restart t3code.service` (its own serve registration has a 10 s timeout).
- [ ] Merge the `agentic/onboarding` branches (worktrees under `~/work/tfc/repos/.agentic-onboarding/`) after review;
      rotate the routelab Tiltfile DB password and the two Flexprice keys.

## Removable media (butternut, hazel)

New `removable-media` feature (pulled in by `desktop`): udiskie automounts to
`/run/media/$USER/<label>`, a drive glyph appears on the bar while something is
mounted, and the butternut LUKS key stick (`BNKEY`) stays hidden. Before this,
nothing automounted: udiskie was not installed, only gvfs (Thunar sidebar, click to mount).

- [ ] After switching: log out and back in (or `systemctl --user start udiskie`), then
      `systemctl --user status udiskie` should be active. Re-plug the key stick once (or
      `doas udevadm trigger -s block`) so the new udev rules apply to it.
- [ ] **Plain stick** (vfat/exFAT/NTFS/ext4): plug in → one "Device mounted" toast with
      "Browse directory" (opens Thunar). The tray icon (inside the bar's tray drawer) and the
      bar's 󰕓 glyph show while it is mounted. `findmnt /run/media/$USER/*` lists `nosuid,nodev`.
- [ ] **Encrypted (LUKS) stick**: plug in → passphrase dialog → mounted toast. Cancel leaves
      it locked; unlock later from the udiskie tray menu.
- [ ] **Eject**: click the bar glyph (or "Drives" in vicinae) → `Eject <label>`. This unmounts
      every partition, locks LUKS and powers the drive off; the toast "Device unmounted" means
      it's safe to pull. Thunar's sidebar eject button works too. "Busy" → close files and retry.
- [ ] **Phone (MTP)**: unlock the phone, pick "File transfer" in its USB notification → it
      shows in Thunar's sidebar (gvfs, not automounted, no bar glyph). Unmount there before unplugging.
- [ ] **Key stick check (butternut)**: with BNKEY plugged in, `udisksctl info -b /dev/sda1 | grep HintIgnore`
      → `true`; no toast, no tray icon, not in Thunar. To read it by hand:
      `udisksctl mount -b /dev/disk/by-label/BNKEY -o ro`, then
      `udisksctl unmount -b /dev/disk/by-label/BNKEY`. More sticks to hide:
      `preferences.removableMedia.ignore.{labels,uuids,serials}`.

## Work repos: parallel setup

Design: `2026-11-17-repo-size-and-parallelism.md` (option b). T3 threads now start in
the shared main checkout (`local`); a worktree is a per-thread choice ("New worktree"
in the composer's workspace picker). Reference repos left the repos: one shallow,
read-only copy per machine in `~/.local/share/reference-repos/<name>` (already
populated on butternut from the old submodule checkouts, no network, 1.8 GB), reached
through git-ignored `.repos/<name>` symlinks. routelab keeps **`.repos/loom` as a
submodule** (CI and the dashboard image build it). Each repo's AGENTS.md has the
shared-checkout rules.

- [ ] **Switch** butternut (and hazel): the T3 policy's `defaultThreadEnvMode` becomes
      `local` (`t3code.service` restarts on policy change).
- [ ] **Review and merge** `agentic/onboarding` in both repos (worktrees in
      `~/work/tfc/repos/.agentic-onboarding/`; new commits on top of the earlier ones:
      `git log --oneline main..agentic/onboarding`). The merge deletes the submodule
      gitlinks; git leaves the populated `.repos/<name>` directories in place.
- [ ] **T3 project mode:** nothing to do. Both projects have no per-project override
      (`default_thread_env_mode` is NULL), so `t3.json` (`local`) applies once the main
      checkout has it. If one is set later, change it in the UI (Settings → project →
      "Where new threads in this project start"); `t3 project` has no flag for it. Don't
      edit `statev2.sqlite`.
- [ ] **routelab: remove the old submodule checkouts** (after the merge, in
      `~/work/tfc/repos/routelab-monorepo`). They hold 4.5 GB (incl. jazz's 2.85 GB
      `node_modules`/`target`) plus 0.8 GB of `.git/modules`; loom (71 M + 77 M) stays.
      None has modified tracked files or unpushed commits (checked 2026-11-17).
      ```bash
      cd ~/work/tfc/repos/routelab-monorepo
      bash .agents/reference-repos.sh status          # every entry "ok …, .repos/<n> is a real directory"
      for n in $(awk '!/^#/ && NF {print $1}' .agents/reference-repos.txt); do
        rm -rf -- ".repos/$n" ".git/modules/.repos/$n"
        git config --remove-section "submodule..repos/$n" 2>/dev/null
      done
      rm -rf .git/modules/typed .git/modules/repos
      for s in submodule.typed submodule.repos/tfc-plugins submodule..repos/.repos/tfc_qgis_plugins \
               submodule..repos/effect-v3 submodule..repos/eslint-plugin-boundaries submodule..repos/penpot-mcp \
               submodule..repos/react-native-coachmark submodule..agents/effect-atom submodule..agents/effect-machine; do
        git config --remove-section "$s" 2>/dev/null
      done
      bash .agents/reference-repos.sh link             # .repos/<name> -> the shared store
      git submodule status                             # only .repos/loom
      ```
- [ ] **d_abm: same, but save scrape-cedej first.** Its checkout has 1 unpushed commit
      on `main`, 3 modified tracked files, an ignored `src/` (184 M) and a 223 M VM image.
      Move it out as its own clone before deleting anything (the reference copy is read-only):
      ```bash
      cd ~/work/tfc/repos/d_abm
      # keep it as a standalone clone (its .git is a file pointing into .git/modules: absorb it first)
      dst=~/work/tfc/repos/scrape-cedej
      mv .repos/scrape-cedej "$dst" && rm -- "$dst/.git" && mv .git/modules/.repos/scrape-cedej "$dst/.git"
      git -C "$dst" config --unset core.worktree; git -C "$dst" status   # same changes as before
      rm -rf -- .repos/effect-smol .repos/kedro-mlflow .git/modules/.repos
      for n in effect-smol kedro-mlflow scrape-cedej; do git config --remove-section "submodule..repos/$n"; done
      bash .agents/reference-repos.sh link
      ```
- [ ] **Other hosts** (peacelily, maple) that check these repos out: copy the store once
      over the LAN instead of cloning from GitHub:
      `rsync -aH butternut:.local/share/reference-repos/ ~/.local/share/reference-repos/`,
      then `bash .agents/reference-repos.sh link` in each checkout. Bumps later:
      `bash .agents/reference-repos.sh sync [<name>]` (shallow, never deletes;
      `unlock` makes an entry writable again, e.g. before `rm -rf` of a dropped one).
- [ ] **Throwaway worktree test** (once per repo, before relying on it): pick "New worktree"
      for a trivial thread; the setup script should print `linked .repos/…`, and in d_abm
      write `conf/local/globals.yml` and `.envrc.worktree`
      (`direnv exec . env | grep CAIRO_SIM_` → `output/worktrees/<name>/…`).
- [ ] **Safe cleanups from the audit** (no data loss; dry runs first; details in §3 of the audit):
      ```bash
      cd ~/work/tfc/repos/routelab-monorepo
      rm -- ':5432' --desired-status --query --record-type .grafana.net observer-validate.log   # R13 junk files
      rm -rf infra/stack/.alchemy/log infra/analytics/.alchemy/log      # R2 2.6 GB (never .alchemy/state)
      rm -rf .devenv/state/prek                                         # R9 0.5 GB, rebuilt on next hook run
      find .turbo/cache -mtime +14 -delete                              # R8 (cache now lives in ~/.cache/routelab/turbo)
      git clean -ndX apps/dashboard apps/guide                          # R11 review, then -fdX
      git maintenance run --task=gc                                     # R12
      emulator -list-avds && rm -rf apps/observer/.android              # R3 2.5 GB duplicate AVD (check the list first)
      cd ~/work/tfc/repos/d_abm
      nix shell nixpkgs#rdfind -c rdfind -dryrun true -makehardlinks true -minsize 20000000 output   # A1, then without -dryrun (13.1 GB)
      git gc --prune=now                                                # A7 0.4 GB cruft pack
      rm -rf interactive/test-results interactive/dist                  # A8
      rm tools/matsim-2026.0-release.zip tools/osmosis-0.48.3.zip       # A9
      npm cache clean --force; rm -rf ~/.cache/pnpm                     # U1 11 GB
      ```
      R1 (jazz build output) is covered by removing the old checkouts above.
