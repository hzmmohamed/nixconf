# Dictation: input choice, visibility, one-shot batch delivery

Approved 2026-11-17 (after the first café test on hazel, Sony + Soundcore
P40i). Small change; design only, plan inline.

## Why

- With two headsets connected, dictation silently used the Sony (PipeWire's
  default source); nothing said which mic was live.
- A headset busy playing music from the phone (multipoint) gave silence and
  no explanation.
- Batch mode "typed" the finished text with `wtype`, one keystroke at a
  time: a long text trickled in after stop.

## Goals

1. Show the mic: the panel header and the "Listening" notice name the
   input ("soundcore P40i"), the bar tooltip too; the draft records it.
2. Choose the mic as a setting, never a prompt: `dictate input`
   (list / auto / NAME) and a "Microphone" entry in the "Dictation drafts"
   launcher picker. Sticky in `~/<journalDir>/input`.
3. Automatic choice: the **most recently connected Bluetooth headset**,
   else the system default source. A preferred mic that isn't connected
   falls back to automatic (and says so).
4. Batch: the text lands at once (clipboard paste, clipboard restored),
   after the panel's accurate "Transcribing n/m" progress.
5. Silence from a Bluetooth mic (all-zero samples for 3 s) raises a clear
   notice: the headset may be busy with another device.

## Non-goals / anti-goals

- No per-session prompt to pick a mic.
- No hardcoded device names or MACs (both headsets are just bluez5 devices).
- Not forcing the phone off the headset: the headset firmware arbitrates
  multipoint. The laptop already opens the call link (HFP) when recording
  starts; making it look like a real *call* (PipeWire bluez5 telephony
  indicators) is a separate experiment, see "Later".

## How (decided)

- WirePlumber 0.5 exposes every connected headset as a virtual source
  `bluez_input.<MAC>` (a loopback) even in A2DP, and switches the device to
  the headset profile when something records from it (autoswitch; restores
  A2DP after). Verified on hazel. So dictation just targets that node:
  `pw-record --target <node.name>`; no profile juggling of our own.
- Resolution runs in `dictate-stream` before the recorder starts, from one
  `pw-dump` (stdlib JSON, ~50 ms). "Most recent" = highest `object.serial`
  of the bluez5 device (serials are never reused).
- Choices offered: Automatic, each headset (`bluez_input.*`), each other
  hardware source (`alsa_input.*`, USB mics), the DeepFilter source.
- Batch delivery: `wl-copy --paste-once --foreground` + paste key, wait for
  the paste to be served (≤ 2 s), restore the previous clipboard (preferred
  text type, else its first type). Paste key from the focused app: Ctrl+Shift+V
  in terminals (kitty, foot, alacritty, wezterm, ghostty), Ctrl+V elsewhere
  (Ctrl+Shift+V is markdown preview in VSCodium). Falls back to typing.
  Stream mode keeps typing short segments with `wtype`.

## Approaches considered

- **Target the WirePlumber loopback node (chosen)**: stable name, autoswitch
  handled by WirePlumber, nothing to restore on crash.
- Switch the card profile ourselves (`pactl set-card-profile`): must restore
  on every exit path, WirePlumber may persist it as a user choice; only gain
  is control we don't need.
- Prompt at each press: rejected by the user (gets in the way).

## Later

- Spike: PipeWire bluez5 telephony (fake an active call) to make multipoint
  headsets prefer the laptop over the phone's music.
