# Vault search in the launcher (vicinae ↔ KeePassXC)

Status: approved 2026-11-22, then **deferred**. The cheaper fix was built
first (`features/vault.nix`): KeePassXC opens `vault.kdbx` at login, its main
window is a large floating sway scratchpad that Super+p toggles over the
current workspace, and Ctrl+C/Ctrl+B hide it again. Build the extension
below only if that still isn't enough after some use. Why deferred: the
file dialog was most of the pain; Super+p → type → Ctrl+C is as short as
the launcher flow; KeePassXC-Browser covers website logins; the extension
is custom code against two pre-stable APIs (vicinae 0.x, the browser
protocol) and enables entry listing for every associated client.

## Intent

Finding a password on hazel today means opening KeePassXC, picking the
database from a file dialog, then searching. Goal: Super+Space, type
"github", Enter: the password is on the clipboard. KeePassXC stays the only
thing that ever unlocks the vault.

## Goals

- Search every entry of the unlocked vault from vicinae by title, URL or group.
- Actions per entry: copy password (default), copy username, copy TOTP, open
  URL, show in KeePassXC.
- Locked vault: KeePassXC's own unlock window comes up, and the search
  continues once it's unlocked. The launcher never sees the master password.
- Fix the file dialog: KeePassXC opens `~/Vault/vault.kdbx` at login.
- Works on every desktop host that imports `vault` (hazel, butternut).

## Non-goals

- Editing or creating entries from the launcher (use KeePassXC).
- Auto-type into other windows (sway's portal has no RemoteDesktop; see the
  secrets design).
- Changing the Secret Service provider: gnome-keyring keeps serving mail,
  Chromium and VSCodium (phase 2 of the secrets design stays optional).

## Anti-goals

- No master password, key file or decrypted database outside KeePassXC.
- Copied passwords never show up in vicinae's clipboard history.
- Never leave a password on the clipboard indefinitely.

## Approaches considered

| | How | Trade-off |
|---|---|---|
| A. KeePassXC as Secret Service | Replace gnome-keyring, the launcher reads over D-Bus | Mail/Chromium/VSCodium depend on KeePassXC being unlocked; app secrets need a second local database; re-sign-ins on migration. Rejected |
| B. Launcher opens the `.kdbx` (keepmenu style, `keepassxc-cli`/pykeepass) | Own unlock + own timeout | Two unlocks, two lock timers, master password in a second process. Rejected |
| **C. Browser-extension protocol (chosen)** | vicinae extension talks to the running KeePassXC over its local socket, like KeePassXC-Browser and git-credential-keepassxc | Nothing else changes; a small custom client for an encrypted protocol |

Why C works (verified in KeePassXC 2.8.0, the nixos-26.05 version):

- Socket: `$XDG_RUNTIME_DIR/app/org.keepassxc.KeePassXC/org.keepassxc.KeePassXC.BrowserServer`
  (`BrowserShared::localServerPath`). Messages are JSON, payloads encrypted
  with NaCl `crypto_box` (X25519 + XSalsa20-Poly1305).
- `get-database-entries` lists every entry (`title`, `uuid`, `url`, `group`;
  no passwords). Gated by `Browser/AllowGetDatabaseEntriesRequest` (default
  off; present in the 2.8.0 binary).
- `get-logins` with `url = "keepassxc://by-uuid/<uuid>"` returns exactly that
  entry with login and password, including entries without a URL
  (`BrowserService::shouldIncludeEntry`).
- `get-totp` takes a `uuid`.
- Requests carrying `triggerUnlock: "true"` bring up KeePassXC's unlock
  dialog when locked (`Browser/UnlockDatabase`, default on).
- KeePassXC asks once per entry before releasing it ("Allow access", with
  "remember"). Groups marked hidden from browser integration stay hidden.

## Design

**Extension** `modules/nixos/features/vicinae/extensions/vault/`, TypeScript,
packaged like `wallpapers` (`config.lib.vicinae.mkExtension`, committed
`package-lock.json`). One dependency beyond `@vicinae/api`: `tweetnacl`
(Node's crypto has no XSalsa20).

- Command **Search Vault** (view mode): list of entries, title as the row,
  username/URL host as subtitle, group as accessory. Built-in vicinae fuzzy
  filter over title, URL host and group.
- Default action (Enter): fetch the entry by UUID, copy the password with
  `Clipboard.copy(…, {concealed: true})`, close the window, HUD "Password
  copied, clears in 30 s". Other actions: copy username, copy TOTP, open URL,
  show in KeePassXC (focus the window via `vault-open`).
- Clipboard clear: a detached helper waits the timeout, then clears only if
  the clipboard still holds the same value (compared by hash, never passing
  the password on argv). Timeout = `preferences.vault.clipboardClearSeconds`.
- First run: `associate` → KeePassXC asks to name the connection (e.g.
  "vicinae-hazel"). The client's ID and key go in vicinae `LocalStorage`.
  `test-associate` on later runs; if that fails (new database, key removed),
  associate again.
- Errors as a single empty-state row: KeePassXC not running (action: start it),
  listing disabled, association refused, locked and unlock cancelled.
- The entry list isn't cached on disk; each open fetches it (one round trip).

**`vault.nix` changes (desktop part)**

- `Browser.AllowGetDatabaseEntriesRequest = true`. Side effect: any
  associated browser client can list entry titles/URLs (not passwords);
  acceptable, they already ask for passwords by URL.
- Autostart opens the database directly: `keepassxc --minimized
  ${cfg.path}/vault.kdbx`, with a new `preferences.vault.database` option
  (default `"vault.kdbx"`). Fixes the file dialog.
- Register the extension under `programs.vicinae.extensions` (the vault
  module stays independent of `vicinae`: guarded on
  `config.home-manager.users.${user}.programs.vicinae.enable`, or the
  extension lives in its own small `vicinae-vault` feature that hosts add
  next to `vicinae-wallpapers`. Builder's call; the separate feature matches
  the wallpapers precedent).
- Optional keybinding: `Mod4+p` keeps focusing KeePassXC; the launcher entry
  is reached by typing "vault" (vicinae aliases). A direct deeplink binding
  can come later.

**Docs**: `docs/plans/2026-11-17-secrets-design.md` gets a short section
pointing here, and the `personal.kdbx` name there is corrected to `vault.kdbx`.

## Left to the builder

- Exact protocol client structure (connection per command vs. per request),
  nonce handling and error codes, from the KeePassXC-Browser protocol doc.
- Icon, subtitles, whether TOTP is shown only for entries that have it (the
  list call doesn't say; fetch lazily).
- How the clipboard-clear helper is spawned (`wl-copy`/`wl-paste` in a
  `writeShellApplication`, passed to the extension as a preference default or
  found on `PATH`).

## Verification

- `just check` (fmt, lint, eval-all).
- Manual on hazel after deploy: first-run association, search, copy password
  (absent from clipboard history, cleared after 30 s), locked-vault unlock
  flow, KeePassXC not running.
