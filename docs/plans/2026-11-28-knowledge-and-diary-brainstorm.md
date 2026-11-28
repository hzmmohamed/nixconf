# Knowledge system and voice diary: brainstorm notes

2026-11-28. Raw shaping notes from one conversation with the user, before
any design. Two projects came out of it, explored in separate threads:
**A. the voice diary** (more important to the user) and **B. the
knowledge/media system** (capture, tray, inbox, graph). They share parts but
are designed separately. "User said" = their words; "proposal" = Claude's,
not yet agreed.

## Prior notes in the repo

- `2026-11-22-phone-dictation-keyboard-design.md:277` (Later): *Voice diary
  (own design): record-first, audio kept, encrypted and synced;
  sentence-timed transcripts to browse and replay; re-transcribed as better
  models (Egyptian Arabic) appear; private LLM processing.* The diary is to
  live in the phone companion app (Pollen), next to the keyboard.
- `2026-11-17-backlog.md:88`: *Knowledge base / references beyond Zotero;
  photo and file organisation with local LLMs.*
- `2026-11-25-attention-tracker-design.md`: the second brain / media inbox
  is a separate project; seam §5.10 exports `media.consumed` (YouTube id +
  channel, article URL, seconds, finished) and attention-state changes.
  Its §3 constraints (model boundary, no plaintext at rest, key custody,
  capture never depends on the network) and storage choice (signed,
  encrypted, append-only logs in S3 → one brain → encrypted DuckDB) are the
  template for personal data in this fleet.
- `2026-11-24-pollen-keyboard-audit-and-ideas.md`: phone-local Parakeet is
  English only, Arabic needs the server's Whisper; Egyptian Arabic is where
  fine-tuning pays off (LoRA on peacelily, later); Pollen keeps a dictation
  journal (`YYYY-MM-DD.md`), not a diary.
- `2026-11-25-dictation-training-lab-design.md` §5.7: Arabic audio kept
  indefinitely, other audio 90 days.
- Existing tools: Zotero shared via Syncthing (`shared-zotero.nix`), vault
  (KeePassXC over Syncthing, `vault.nix`), Immich pilot on butternut.
  Obsidian removed from the default app set.

## Standing constraint

Personal data (diary audio/text, reflections, "why" notes) is processed by
**open-weight models on the user's hardware only** (peacelily, butternut).
No commercial model, including the agents building this, reads real
entries. Agents design; they never see the data.

## The user's history with tools (user said)

- **Google Keep**: frictionless chronological dump (throwaway notes like a
  price, lyrics, verses, links, reflections). After a year it was
  overwhelming: nothing got resolved, only carried along.
- **Notion**: a life system centred on projects (work and knowledge-based
  interests: coding, reading, topics). PARA in the mix; never stuck to one
  system. Projects still fit.
- **Obsidian**: plugins (todo, private search) and the Zotero plugin.
- **Zotero**: good at keeping everything (papers, YouTube, blog posts,
  highlights), but heavy, ceremonious, and blind to media types: no
  captions or indexing for YouTube, no quick surfacing of what matters.
- **Anytype**: followed since before its stable launch; drawn to its graph
  of typed objects, not tried deeply.
- **Social posts today**: saved inside Instagram/Facebook or sent to self on
  WhatsApp. Fragmented, unsearchable, bad for privacy. The sharpest pain.

## A. Voice diary (user said)

- Deeply personal. Recorded by voice more and more; sometimes written.
  Mixed Egyptian Arabic / English.
- Not an inbox: you don't process and clear an entry. The interface looks
  back into one's life: read old entries, reflect on an older entry, see
  general sentiment over the past weeks, record memories and link them to
  photos, ask questions and search "what did I say a year ago". Many
  recurring themes and ideas.
- Entries link to each other; related to work and knowledge but a
  self-contained system.
- Earlier wishes: everything recorded and kept, encrypted; transcripts with
  timestamps; indexed, searchable, summarised.

Proposals (not agreed): links point one way, a diary entry may reference a
project, question or saved item, the knowledge system never sees inside the
diary; photo links go to Immich.

## B. Knowledge / media system (user said)

**Inbox as the shape of life.** Every input gets a definite output that
clears it, even if it returns. Not inbox zero, a healthy processing rate.
Inboxes of questions, material, videos, comedy, movies: something to look
forward to (a weekend list) instead of holding it all in memory. Pacing,
not a strict plan ("what is a healthy rate of acquisition?", "how am I
progressing on the questions that matter most?").

**Capture is where the work is.** Each save carries *why*: free-form,
kept verbatim, then turned by a local model into graph links (example: a
paper on a model's architecture saved "to understand its KV cache because I
run it locally" links to the llama setup, peacelily, related papers, the
question). Knowledge is contextual; things live in relation to other
things. Digital store ≠ what is internalised in the head; the system holds
metadata about *the user's relation* to items, not just facts.

**Questions as units.** Pursuit of knowledge starts with an inquiry,
gathers resources/observations, ends answered or still open. Objective
answers (how rockets steer in space) and subjective ones (sub-agents vs
threads). Questions can be stashed ("how do bees communicate?"). Rough map:
know / don't know but want to / don't care (discard).

**Lifecycle.** Tentative ("interesting, look when focused") → consumed →
out of the inbox, which needs its own reflection (spoken or typed). Ends
as: reference; a library of things dear (documentaries, old songs, short
films, like a YouTube playlist); key moments/highlights only; scoped to a
project and archived with it; discarded (irrelevant, near-duplicate).
Where kept things live: unclear, to be found by using it.

**Highlights.** A self-contained quote/idea can be an object of its own;
a key point inside a paper stays attached to its source.

**Two modes.** Mindful scrolling (10–20 saves in an hour after a week off
social media) and focused work on a topic. Mindless scrolling is
something to prevent.

**Saving on the phone.** A prompt to type or say why, skippable. Possibly
suggestions from a fast lookup in the existing graph ("fits this, this or
this?"). A **tray** (Claude's name): bounded (~20), emptied daily before the
reasons fade, the "back to the tent, sort the rocks and twigs" step; also
gives batch/rate-limited extraction time.

**Mechanical processing** (captions, bibliography, summaries, indexing) is
async background work with its own state, distinct from processing in the
head.

**Getting posts out of platforms.** Scraping is blocked; full-post
screenshots are unreliable (scrolling screenshot often not offered). The
user is willing to supply credentials for a headless browser. Proposals:
an Android accessibility service in Pollen reads the post text on screen
plus a screenshot for images (one-time manual permission for a sideloaded
app); headless browser on butternut for public pages, with the risk that a
logged-in automated session gets the account flagged. To test in a spike.

## Open (next to explore)

- A: capture flow and interface on phone and desktop; what "ask the diary"
  looks like; sentiment/themes; storage and key custody (reuse attn's
  pattern?); re-transcription as models improve; how entries reference
  photos and knowledge items.
- B: object types and the graph; where questions live and how items attach;
  the tray and inbox UI; what happens to Zotero, Keep-style quick notes,
  existing saved posts; storage engine (Anytype-like vs own).
