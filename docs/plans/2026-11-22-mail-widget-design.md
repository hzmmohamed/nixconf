# Mail bar widget — design (2026-11-22)

## Intent

One bar widget for both mail accounts (personal = Gmail, work = Outlook 365):
per-account unread counts at a glance, a menu to open Thunderbird or either
webmail, and a desktop notification when new mail arrives. Thunderbird must
not need to run in the background for any of this.

## Current state

- `email.nix`: `mail-unread-refresh` does one IMAP `STATUS INBOX (UNSEEN)` per
  account (OAuth via `email-oauth2`), writes
  `$XDG_RUNTIME_DIR/mail-unread/<account>.count`, runs on a 5-min timer and
  from imapnotify's `onNotify`. `mail-notify` sends a generic "New message in
  <account>" notification.
- `desktop-status.nix`: `mail-unread-status` sums the counts; empty text at 0.
- waybar `custom/mail` (both hosts use waybar) and the Noctalia `mail`
  widget: hidden at zero, click = Thunderbird, right click = refresh.

## Approaches

1. **vicinae dmenu menu (picked).** A `mail-menu` script fed to vicinae, same
   pattern as `audio-sink-menu` / `caffeine menu`. Works in waybar and
   Noctalia alike.
2. waybar native GTK `menu` (menu-file + menu-actions): waybar-only, Noctalia
   would need its own; no live counts in labels.
3. Separate widget per account: two click targets, but more bar space on a
   vertical bar and no single "open Thunderbird" place.

## Design

- **Always visible.** Mail glyph, then one line per account: `P 3`, `W 12`
  (initial of the account name). Class `unread` when any count > 0 (accent
  colour), `none` otherwise (dimmed). Tooltip: `personal: 3`, `work: 12`.
  Missing count file (not refreshed yet / token error) shows `–`.
- **Left click → `mail-menu`** (vicinae dmenu, prompt "Mail"):
  `Thunderbird`, `Gmail — personal (3)`, `Outlook — work (12)`,
  `Refresh counts`. Webmail opens via `xdg-open`
  (`https://mail.google.com/mail/u/<address>/`, `https://outlook.office.com/mail/`).
  Webmail URL per account derives from its home-manager `flavor`.
- **Right click** refresh; **middle click** Thunderbird.
- **Notifications** move into `mail-unread-refresh`: when an account's unread
  count rises above the previous stored value, notify with the sender and
  subject of the newest unseen message (`UID SEARCH UNSEEN` + header fetch of
  the max UID; falls back to "N new" if that fails). The first refresh of a
  session (no previous value) is silent. imapnotify's hook just runs the
  refresh, so the timer and IDLE paths share one notification code path and
  never double-notify.
- Noctalia `mail` widget gets the same commands.

## Non-goals

- Thunderbird running in the background / tray.
- Folders other than INBOX, per-message actions in the notification.

## Left to the builder

Exact glyph/line formatting in the vertical bar; notification urgency/icon.
