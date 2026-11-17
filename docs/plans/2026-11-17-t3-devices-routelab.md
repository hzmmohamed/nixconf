# T3 devices: the routelab Android emulator on butternut (2026-11-17)

Goal: threads that touch the routelab mobile app (`apps/observer`) can boot,
see and drive an Android emulator through T3 Code's device tools, on
butternut (KVM, always on, works with no monitor).

Evidence: T3 Code 0.1.9 server source (from the package's source maps) and
the routelab repo, read-only. Paths are T3 source paths unless noted.

## How T3 0.1.9 devices work

- **Per environment, not per project.** Devices live in *server* settings:
  `enableDeviceSupport` (Device panel), `enableAgentDeviceAccess` (agent
  tools; the only device key a project can override), `deviceHosts` (SSH
  machines), `easDeviceHosts`, `simlockDeviceHosts*`
  (`packages/contracts/src/settings.ts:1413-1421`). `t3.json` has **no device
  fields** (`packages/contracts/src/t3ProjectFile.ts`), so nothing has to be
  declared in the routelab repo.
- **"Local simulators" = the machine running the T3 server.** Android support
  needs an SDK found through `ANDROID_HOME` / `ANDROID_SDK_ROOT` (then
  `~/Android/Sdk`, then `adb` on PATH) containing `platform-tools/adb`,
  `emulator/emulator` **and `cmdline-tools/latest/bin/avdmanager`**
  (`src/device/LocalDeviceHost.ts:114-181`). An SDK with only a versioned
  `cmdline-tools/<n>` is reported unavailable.
- **AVDs** come from `emulator -list-avds` in the server's environment, so
  `ANDROID_AVD_HOME` / `ANDROID_USER_HOME` must point at the repo's
  `.android` (`src/device/DeviceHubOperations.ts:124-197`).
- **Booting and streaming** go through T3's device hub (npm packages
  `expo-device-hub` + `agent-device`, installed on first use into
  `~/.t3/tools`; needs `npm` and network). Extra emulator flags:
  `EXPO_DEVICE_HUB_EMULATOR_EXTRA_ARGS`. Streaming needs `ffmpeg` with
  libx264 on the server's PATH (`src/device/DeviceService.ts:774-800`).
- **Agent tools** (`src/mcp/toolkits/device/tools.ts`): `device_list`,
  `device_open` (boots, shows it, returns an `agent-device` command pinned to
  it for taps/typing), `device_screenshot`, `device_close`.
- **"Machine over SSH"** (`deviceHosts`, `{kind:"ssh", id, label, target,
  identityFile?, port?}`): T3 SSHes in, installs the hub under
  `~/.t3/device/hosts/…`, needs `node` on the SSH PATH and an SDK in
  `~/Android/Sdk` there. Useful later for an emulator on a machine that
  doesn't run the server (e.g. hazel's threads using butternut's emulator
  without linking). Not set up now.

## Design

The emulator runs where T3 runs the routelab project's mobile threads:
**butternut**. T3 itself boots the repo's AVDs headless (it streams the
screen to the Device panel), so it also works when butternut has no monitor.

The SDK is **routelab's own** (its devenv `mobile` shell), not a second one
built in nixconf:

- one SDK in the store instead of two (system images are GBs);
- the hub's `adb` (from `ANDROID_HOME/platform-tools`) is the same version as
  the `adb` Gradle/Expo use inside `rl-dev-mobile`, so they share one adb
  server instead of killing each other's (version mismatch restarts it).
  Avoid the system `adb` (android-tools) while a T3 device is booted.

Wiring (nixconf, done):

- `preferences.agents.t3code.devices.android` on butternut
  (`modules/nixos/features/agent-t3code.nix`, `hosts/butternut/agents.nix`):
  - server env: `ANDROID_HOME=~/.local/share/t3-android/sdk`,
    `ANDROID_AVD_HOME=<routelab>/.android/avd`,
    `ANDROID_USER_HOME=<routelab>/.android`,
    `EXPO_DEVICE_HUB_EMULATOR_EXTRA_ARGS=-no-window -gpu swiftshader_indirect
    -no-audio -no-boot-anim -no-snapshot -memory 4096 -cores 6`, and
    `nodejs` + `ffmpeg-full` on its PATH;
  - policy defaults (unlocked): `enableDeviceSupport = true`,
    `enableAgentDeviceAccess = true` (environment-wide: project ids are
    random UUIDs, so a per-project override can only be set in the UI);
  - the user joins the `kvm` group (`/dev/kvm` is currently 0666 anyway);
  - `t3-android-sdk`: run inside routelab's mobile shell, it links that
    shell's `ANDROID_HOME` to `~/.local/share/t3-android/sdk`, GC-roots it,
    adds `cmdline-tools/latest -> <newest version>`, and restarts
    `t3code.service`. Re-run after routelab bumps its SDK.

`-gpu swiftshader_indirect` is the safe headless default. If the NVIDIA/Intel
EGL path works headless on butternut, `-gpu host` is much faster: set
`preferences.agents.t3code.devices.android.emulatorArgs`.

## Proposed routelab changes (not applied; the repo is the team's)

1. **Re-create `routelab-app-emulator`.** Its `config.ini` is still the bare
   fallback profile (320x640, `hw.gpu.enabled = no`): `create-avd` was never
   re-run after it got its pixel_6 defaults. `routelab-e2e` (android-34,
   1080x2400) is usable as is.

   ```fish
   cd ~/work/tfc/repos/routelab-monorepo
   direnv exec . rl-dev-mobile -c create-avd
   ```

2. **Optional: `cmdline-tools` "latest".** If devenv's android module learns
   to expose `cmdline-tools/latest` (today `cmdLineTools.version = "11.0"`
   installs only `cmdline-tools/11.0`), `t3-android-sdk` stops needing its
   symlink. Nothing breaks without it.

3. **AGENTS.md (apps/observer):** a short "T3 device" section:

   ```markdown
   ## Android device (T3 Code)

   On butternut, T3 exposes the repo's AVDs as devices. Use the device tools:
   `device_list`, then `device_open` (prefer `routelab-e2e`); it returns an
   `agent-device …` command for taps, typing and screenshots. Build and
   install from the mobile shell, which talks to the same adb server:
   `rl-dev-mobile -c bash -lc 'cd apps/observer && pnpm android'`.
   Don't run the system `adb`; don't start a second emulator with
   `start-emulator` while a T3 device is booted.
   `device_close` with `shutdown=true` when done (RAM).
   ```

4. **`t3.json` (when the repo adopts one, see
   `2026-11-17-t3code-integration.md` §5.4):** no device fields exist. A
   script entry for the app build is enough:

   ```json
   { "name": "Android (observer)",
     "command": "rl-dev-mobile -c bash -lc 'cd apps/observer && pnpm android'",
     "icon": "debug", "stopOnSettle": true }
   ```

## User steps (butternut, after `just deploy butternut switch`)

```fish
# 1. Give the T3 server routelab's SDK (once, and after SDK bumps).
cd ~/work/tfc/repos/routelab-monorepo
direnv exec . rl-dev-mobile -c t3-android-sdk

# 2. Check the server sees it.
ls ~/.local/share/t3-android/sdk/cmdline-tools/latest/bin/avdmanager
systemctl --user status t3code
```

Then in the desktop app (or web UI) on butternut's environment: Device panel →
`routelab-e2e` → boot. First use downloads the device hub into `~/.t3/tools`
(needs network). In a routelab thread, ask the agent to `device_open` and
take a `device_screenshot`.

A windowed emulator for manual work stays the repo's own command (don't run
it while T3 has the same AVD booted):

```fish
cd ~/work/tfc/repos/routelab-monorepo
direnv exec . rl-dev-mobile -c start-emulator
```

## To verify on first run

- Whether the hub already passes `-no-window` (duplicate flags have been
  harmless in the emulator so far).
- Boot time and frame rate with swiftshader vs `-gpu host`.
- That `device_open` streams with the `ffmpeg-full` on the server PATH.
