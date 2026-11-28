# Software factories: what they are, what is real, and how to apply them to routelab (research, 2026-11-28)

Status: research report with a staged proposal, no code. Written for the owner of hazel,
butternut, peacelily and fern, who works through T3 Code. Companion to
`2026-11-17-agentic-workspace-design.md`, `2026-11-22-thread-orchestration-research.md`,
`2026-11-22-agent-environment-design.md`, `2026-11-28-agent-isolation-research.md`,
`2026-11-17-t3-devices-routelab.md`, `2026-11-17-repo-size-and-parallelism.md`,
`2026-11-17-work-projects-review.md` and `2026-11-17-aws-agent-host.md`. It builds on them
and does not repeat their findings.

How claims are marked:

- **[doc]** vendor documentation or a published write-up, cited by URL (§9).
- **[src]** read in a shallow clone made today under the session scratchpad, cited as `repo:path`.
- **[repo]** read in `routelab-monorepo` (read-only, branch `feat/observability-phase-1`,
  HEAD `f137313`) or in this repository.
- **[A]** my inference or judgement.

Network: ≈120 MB pulled in total (clones 117 MB on disk, of which Vibe Kanban 104 MB; web pages
the rest). Nothing in routelab was built, run or modified.

---

## 0. TL;DR

- **"Software factory" is a real pattern with a real shape, and a hype label.** Every shipping
  example runs the same five-stage loop: intake (ticket/Slack/Sentry) → isolated environment →
  agent implements → machine verification → a pull request a human reviews. Nobody publishes a
  ticket-to-merged-PR reliability number; the only hard figures come from three internal systems
  (Stripe, Cloudflare, Anthropic) [doc].
- **The project you remembered is Fractal** (fractal.how, Compounding Tech, Johannes Schickling).
  "Factory-as-code" in Effect/TypeScript/KDL: missions with goals, constraints, steps, workers and
  **gates** ("gates, not the agent's report, decide when a step is done"). It runs locally, is in
  preview, and the public demo repo is typed design targets, not a runtime [doc][src]. Worth
  watching, not building on yet.
- **Factories do not bypass version control.** They bypass *human-paced serialisation* of every
  diff: small batches on short-lived branches, machine-driven merging (merge queue or post-merge
  verification), and human attention moved from diffs to specs, scenarios and acceptance evidence.
  Commits, branches and PRs survive everywhere, including at Anthropic (Scion keeps changesets and
  design review) [doc]. Your claim is half right: the *pace* is bypassed, the *control* is not.
- **Verification is the whole game.** Stripe caps a task at two CI rounds and spends its effort on
  lint-before-push and auto-fixes; StrongDM replaces human review with thousands of scenario runs
  against behavioural clones at "$1,000 of tokens per engineer per day"; Cloudflare's reviewers are
  told what *not* to flag [doc]. Cheap deterministic gates first, LLM review last.
- **Code graphs are a token economy, not a quality lever.** The one 2026 head-to-head
  (Codebase-Memory) is *worse* on answer quality (83 % vs 92 %) at 10× fewer tokens; Claude Code
  dropped RAG for grep-style search on quality grounds; Amazon finds keyword search reaches >90 %
  of RAG. For routelab (6.5 k tracked files) the cheap wins are scoped `AGENTS.md`/`CODEMAP.md`
  files and the type checker as oracle [doc][A].
- **Routelab already runs an agent factory with the gates removed.** 2,645 commits since
  September, all one author, 202 of the last 200 carry agent attribution, commits at every hour
  including 00–06; 809 commits ahead of `origin/main` and 440 unpushed; CI only runs on merge
  requests, and no merge request exists, so **CI has not run on this work** [repo]. The missing
  piece is not autonomy, it is verification and a morning report.
- **Hosted factories are blocked for routelab by GitLab.** Claude Code cloud sessions, scheduled
  tasks, Projects and PR Steward need GitHub; self-hosted environments need a Team plan. Codex
  cloud and GitLab Duo flows do support GitLab. Everything the user wants is reachable with T3 on
  butternut plus a few hundred lines of glue [doc][A].
- **Stage 1 (one weekend):** a nightly T3 scheduled task on butternut starts a coordinator with a
  fresh session; it reads a committed queue file, runs one `delegate_task` worktree child per task,
  re-runs CI's `verify` logic locally, dispatches a fresh review child, and writes
  `docs/plans/<date>-overnight-report.md` plus an ntfy. Caps: task count, wall clock, concurrency
  of 1–2. Branches stay unmerged for the morning.
- **Skip:** Gas Town/Beads (cost, Dolt, host-UID agents, flaky per users), Vibe Kanban (sunset
  2026-04-10; T3 already is the worktree board), container-use (dormant since August; worktrees +
  the planned `agent` user cover it), StrongDM-style no-review (needs digital twins).
- **Before overnight full-access runs:** the `agent` user and egress layers from
  `2026-11-28-agent-isolation-research.md` §3.3–3.4. A factory multiplies whatever the agent
  can reach.

---

## 1. Landscape

### 1.1 What the term means in late 2026

Hashnode's survey (July 2026) names four products as defining the category (Devin, Factory, 8090,
Buildful) and finds they all run the same loop: **Intake → Isolation → Implementation →
Verification → Pull request**, with the PR as the human review point. Its core finding: "There is
no public benchmark for ticket-to-merged-PR reliability, no cross-vendor comparison" [doc]. A
February 2026 study of 128,018 GitHub projects found 22–29 % had adopted coding agents [doc,
secondary].

The term was popularised by StrongDM's manifesto *Software Factories and the Agentic Moment*
(2026-02-06) and Factory.ai's *Factory 2.0* (2026-06-15). The GitHub list
`varun1505/awesome-software-factories` now groups ~40 projects into: end-to-end factories,
ticket-to-PR pipelines, autonomous loops, parallel session managers, isolation, backlog/spec
layers, review and merge gates, multi-agent frameworks, hosted [doc].

### 1.2 Internal factories with published numbers (the ground truth)

| Who | What runs | Numbers | Git / review |
|---|---|---|---|
| **Stripe "Minions"** | Fork of Block's Goose, deterministic "blueprint" nodes around agentic ones; pre-warmed devboxes (10 s), isolated from production and the internet; Toolshed MCP (~500 tools); rule files scoped to subdirectories | 1,000 → **1,300 merged PRs/week**, "human-reviewed, but containing no human-written code"; **at most two CI rounds** per task; lint before every push | Feature branch → PR with the template → human review. "If it's good for humans, it's good for LLMs, too" |
| **Cloudflare AI code review** | OpenCode-based orchestrator, up to 7 scoped reviewers + a coordinator (Opus 4.7 / GPT-5.4; Sonnet-tier for security/perf/quality; Kimi K2.5 for docs); risk tiers (≤10 lines → 2 agents) | 30 days: **131,246 runs, 48,095 MRs, 5,169 repos**, median 3 m 39 s, **$1.19 per review**, 0.6 % break-glass overrides, 85.7 % cache hits | Posts MR comments via MCP, tracks resolutions, never blocks on a single warning; "This isn't a replacement for human code review" |
| **Anthropic** | Claude writes >80 % of merged production code (May 2026); Scion replaces git for the monorepo | Merges/day **2,500 (May) → 30,000 (Sept 2026)**; ~25 M checkouts/day; infra 200× smaller; 7 engineers, 5 months | Changesets, server-side merges, **post-merge and pre-deploy testing instead of a merge-queue lock**; "the role of the engineers was to tell Claude 'no'" |
| **StrongDM Software Factory** | Specs + "scenarios" → Attractor (non-interactive agent) → harnesses → Digital Twin Universe (behavioural clones of Okta, Jira, Slack, Google) → satisfaction scoring | "If you haven't spent at least **$1,000 on tokens today** per human engineer, your software factory has room for improvement" | "Code must not be written by humans. Code must not be reviewed by humans." No git details published. Attractor released as a natural-language spec only; `cxdb` as code |

Sources: Stripe parts 1–2, Cloudflare, Anthropic 80 % and Scion, StrongDM manifesto and Simon
Willison's commentary [doc].

Willison's reading of StrongDM is the right frame: the consequential question is "proving
software works when both code and tests are agent-generated", and the $1,000/day figure is the
cost of answering it with scenarios instead of reviewers [doc]. METR's 2025 RCT is the cautionary
base rate: experienced developers on their own mature repos were **19 % slower** with AI while
believing they were 20 % faster, because large repos carry implicit requirements that "take humans
substantial time to learn" [doc]. Factories are an attempt to turn those implicit requirements
into executable gates.

### 1.3 Fractal (Johannes Schickling, Compounding Tech)

- Site: fractal.how, "a batteries-included framework to build your own software factory",
  labelled **Preview**. Talk: *Building Your Own Software Factory*, Builder's Day 2026-10-26: "Move
  from supervising individual coding agents to a software factory built on declarative goals,
  missions, and feedback" [doc].
- **Model:** a *mission* declares a goal, constraints and steps; dependencies order steps;
  **"gates, not the agent's report, decide when a step is done."** Gate kinds in the demo: CI
  passed on a branch, `exec` a command on a host/workspace, a custom check, an LLM evaluation, and
  `type="human"` with a reviewer and a question. Workers pair a harness (Claude `claude-opus-5`,
  Codex `gpt-5.6-sol`, OpenCode `kimi-k3`) with an effort level and a workspace [doc]
  [src: `fractal-factory-demo:kdl/missions/ship-comments.kdl`, `ts/missions/fix-backlog.ts`,
  `stubs/fractal.d.ts`].
- **Runtime claims:** runs locally with durable state and replication across machines; clients
  are TUI, web, mobile, CLI, MCP. GitHub integration: "turn repository events into finite,
  evidence-backed agent work"; "Only decisions reach you" [doc].
- **Reality check:** the demo repository says in its README "Design target, not a runtime …
  These declarations validate types but do not implement execution, durable journaling, agent
  launch, authentication or graph publication" (last commit 2026-10-28) [src:
  `fractal-factory-demo:README.md`]. The install docs exist (`fractal.how/llms.txt` lists CLI,
  daemon and agent setup pages) but I could not inspect the engine. **Verdict [A]:** the best
  articulated *model* in the field (missions, gates, evidence) and the closest to the user's
  Effect-TS stack, but pre-release. Adopt the vocabulary now; evaluate the runtime when the repo is
  public.

### 1.4 Hosted and vendor platforms

| Product | What it is (verified) | Git host | Relevance to routelab |
|---|---|---|---|
| **Claude Code cloud sessions** | Sessions on Anthropic VMs from web, mobile, desktop, `claude --cloud`; counts against plan usage, no VM charge; Pro/Max/Ultra/Team | **GitHub only** for clone and PR. A GitLab repo can be *uploaded* as a bundle (`CCR_FORCE_BUNDLE=1`, <100 MB) but "can't push results back" | Blocked by GitLab; the bundle path fails on a 236 MB tree |
| **Claude Code scheduled tasks** (ex-routines, research preview 2026-04-14) | Prompt + repos + connectors; triggers: cron (≥ hourly), API (`/fire`), GitHub events; per-account hourly caps; runs as *your* GitHub identity | GitHub | Same block |
| **Claude Code Projects** (public beta, Pro/Max/Ultra) | One coordinator conversation; each task becomes a cloud thread on its own branch, opens a PR, auto-fix on; Overview pane "Ready for review / Waiting on you"; project memory + ≤16 k-char instructions. Thread limits are "instructions Claude keeps to, not enforced settings" | GitHub | This *is* the hosted version of what the user wants. Blocked by GitLab |
| **PR Steward** (Team/Enterprise beta) | Pushes fixes for failing checks, conflicts, review comments; never approves or merges; billed to org credits, spend limit settable | GitHub | n/a |
| **Self-hosted environments** (Team/Enterprise beta) | Your runner (like a CI runner) claims cloud sessions, clones, runs Claude locally; outbound HTTPS only; other git hosts only via `--environment` dispatch | GitHub + GHES; others partial | Would put the control plane in claude.ai and execution on butternut. Needs Team plan |
| **Remote Control** (Pro+) | Drive a *local* `claude` from phone/browser; `--spawn worktree`, `--capacity 32` | any | Overlaps T3; not needed |
| **Claude Code GitLab CI/CD** (beta, maintained by GitLab) | A CI job running `claude -p` with `--permission-mode acceptEdits`, `mcp__gitlab`; API key (no subscription); `--max-turns` + job `timeout` as caps | GitLab | Works, but burns the Free tier's 400 CI minutes and pays per token |
| **GitLab Duo Agent Platform** (GA 2026-01-15; Free teams can buy credits since 18.10, March 2026) | Developer flow: assign an issue → agent reads it, codes, runs tests, opens an MR; Code Review flow 0.25 credits/review; custom flows | GitLab | The only *native* ticket-to-MR path on routelab's host. Credits, GitLab's models/agents |
| **OpenAI Codex cloud** | Per-task sandbox, install script, network policy, HTTP secrets; parallel tasks; scheduled tasks; since 2026-04 Codex "can schedule future work for itself"; reusable environments (2026-09) | **GitHub and GitLab** | Works with GitLab. Different harness and account |
| **GitHub Agent HQ / mission control** (Universe 2025; Agents tab 2026-01-26) | Assign issues to Copilot or third-party agents (Anthropic, OpenAI, Google, Cognition, xAI); sessions → draft PRs; branch-level governance | GitHub | n/a |
| **Cursor Cloud Agents** (3.5, 2026-05-20) and **Origin** (2026-08-17) | Detached VM agents; Origin is a git-compatible forge with Graphite's stacked PRs and a merge queue "as an intelligent gatekeeper for AI-written code" | Origin | The clearest statement of "VCS at machine pace = stacked PRs + merge queue" |
| **Factory.ai (Droids)** | Factory 2.0: Droids, Automations, "Droid Computers", "Missions" over hours/days; a Router picks models; enterprise (RBC, EY, MongoDB); $150 M at $1.5 B (April 2026) | GitHub/GitLab (enterprise) | Enterprise sales motion; no prices published |
| **Devin 2.0** (April 2026) | $20 Pro, ACUs at $2.25 (≈15 min compute), bundled with Windsurf; Devin Desktop "Agent Command Center" (June) | GitHub/GitLab | Cheapest hosted entry; closed |
| **Google Jules** (GA 2026-05-19) | Async agent on Gemini; AI Pro/Ultra plans | GitHub | n/a |
| **Tembo** | Hosted, agent-agnostic (Claude Code, Codex, Cursor, Amp, OpenCode, Pi); events from GitHub/GitLab/Bitbucket/Linear/Jira/Slack/Sentry/PagerDuty → PRs and running "Previews" | GitHub, GitLab, Bitbucket | Closest hosted fit for a GitLab solo dev; pricing not published |
| **Terragon** | **Shut down** (site shows only "Terragon Shutdown", 2026-11-28) | — | dead |
| **Conductor** | macOS app, worktree per agent, $50/month Pro | — | macOS only |

Sources in §9 [doc].

### 1.5 Open-source orchestrators and loops (deep dives in §2)

| Project | State on 2026-11-28 | One line |
|---|---|---|
| **Gas Town + Beads** (Steve Yegge, now `gastownhall/*`) | Go; v1.0 2026-04-03; active | Roles (Mayor, Polecats, Witness, Refinery, Deacon, Dogs), Beads on Dolt as the ledger, worktrees, Bors-style merge queue |
| **Ralph loop** (Geoffrey Huntley) + **ralph-orchestrator** (mikeyobrien) | Rust; 3.2 k stars; pushed 2026-11-13 | `while :; do cat PROMPT.md \| claude; done` with fresh context each iteration; the orchestrator adds "hats", typed events, backpressure gates, loop detection |
| **Vibe Kanban** (Bloop) | Rust; 28.8 k stars; **sunset announced 2026-04-10**, "open source and community maintained", still pushed 2026-11-28 | Kanban of tasks, worktree per task, 10 executors, PR monitor, merge/rebase buttons |
| **container-use** (Dagger) | Go; 4.1 k stars; **last push 2026-08-12** | MCP server: container + worktree per environment, `container-use/<id>` branches, history in git notes, `merge`/`apply` |
| **Attractor** (StrongDM) | 3 Markdown specs, 35 k words; last commit 2026-03-17 | "NLSpec": DOT-graph pipeline with goal gates, retries, human gates, checkpoints; build it with your own agent |
| **Sculptor** (Imbue) | MIT; Linux + macOS; "experimental research preview" | Desktop app, isolated workspace per agent (container-backed), skills for spec/TDD |
| **Symphony** (OpenAI), **Eve** (Vercel Labs), **Mastra Factory**, **Superplane**, **Optio**, **continuous-claude**, **Backlog.md** | listed in awesome-software-factories; not inspected | issue-tracker-as-control-plane spec; SDLC specialist template; self-hostable boards/orchestrators; Ralph-with-PRs; markdown task files |

Dropped as irrelevant or marketing: 8090 and Buildful (enterprise/hosted, no verifiable
internals), "Pinkie software factory" (Product Hunt), the many "N best orchestrators" listicles.

---

## 2. Deep dives (what the code and specs actually do)

### 2.1 Gas Town and Beads

Read: `gastown:docs/overview.md`, `docs/glossary.md`, `docs/concepts/integration-branches.md`,
`docs/design/architecture.md`, `docs/design/sandboxed-polecat-execution.md`, `docs/WASTELAND.md`;
`beads:README.md` [src]; Appleton, de hÓra, HN thread, Software Engineering Daily [doc].

- **Task queue / ledger:** Beads (`bd`) is "a distributed graph issue tracker for AI agents,
  powered by Dolt": `bd create` → dependency graph → `bd ready` (claimable) → `bd update --claim` →
  `bd close`; `bd dolt push/pull` syncs machines. It installs hooks and `AGENTS.md` snippets for
  Claude, Codex, Cursor, Factory. Gas Town stores every agent, MR and signal as a bead
  ("accountability … every action is attributed").
- **Roles:** Mayor (coordinator, singleton), Deacon (watchdog daemon), Witness (per-repo lifecycle
  manager that nudges stuck workers), Refinery (per-repo merge queue), Polecats (workers with
  persistent identity, ephemeral sessions), Crew (long-lived, push to main), Dogs (infra helpers).
  Work is grouped in **convoys**. The core directive is GUPP: "If you find work on your hook, YOU
  RUN IT."
- **Git:** polecats and the refinery are **git worktrees, not clones**. The Refinery runs a
  **batch-then-bisect merge queue** ("Bors-style"): rebase a batch, test, fast-forward all on
  pass, bisect on failure. **Integration branches** group an epic: polecats branch from it, the
  Refinery merges MRs into it, and lands it on main as one merge commit when all children close.
- **Sandboxing:** none by default. The 2026-03-02 proposal admits "Every polecat today runs
  directly on the host machine in a tmux session under the user's own UID, with full access to
  the host filesystem, network, and credentials" and sketches exitbox/daytona backends.
- **Cost:** tracked post hoc (`gt costs record` parses Claude JSONL transcripts with hard-coded
  prices; a "factory worker API" design wants it from the runtime). No budget enforcement found in
  the docs. Users: "a space heater", "hideously expensive", Beads "keeps breaking in such
  frustratingly random ways", a `doctor` command "regularly" needed [doc, HN]. Appleton: "vibe
  coded … a stream of consciousness converted directly into code", "thousands of dollars a month"
  [doc]. de hÓra: "it confidently does the wrong thing" [doc].
- **Takeaways [A]:** three ideas are worth keeping without the system: persistent task ledger
  outside the agent's context; a *merge queue agent* separate from workers; integration branches
  per epic. The rest (Dolt, tmux, seven roles, a federated "Wasteland" reputation network) is
  cost and surface area a solo developer does not need.

### 2.2 Ralph loop and ralph-orchestrator

Read: `ralph-orchestrator:README.md`, `docs/concepts/{backpressure,hats-and-events}.md`,
`docs/advanced/loop-detection.md`, `docs/api/config.md` [src]; Huntley [doc].

- **The loop:** `while :; do cat PROMPT.md | claude-code; done`. Each iteration gets a fresh
  context and the same files: `@fix_plan.md` (prioritised to-dos), `@specs/*`, `@AGENT.md` (how
  to build and test). Commit only when tests pass; tag; `git reset --hard` on bad states. Huntley:
  "you need to trust Ralph to decide what's the most important thing to implement"; failure modes
  are placeholder implementations ("optimize for compilation rather than completeness") and
  non-deterministic search concluding code does not exist; "Anyone claiming … a tool can do 100 %
  of the work without an engineer is peddling horseshit." Suits greenfield to ~90 %.
- **ralph-orchestrator** formalises it: `ralph plan` writes `requirements.md`, `design.md`,
  `implementation-plan.md`; `ralph run` iterates until the agent prints `LOOP_COMPLETE` or
  `max_iterations` (50 default) / `max_runtime_seconds` (3600) hit. **Hats** are personas with
  `triggers`/`publishes`/`instructions`; typed events route planner → builder → reviewer.
  **Backpressure** is its gate model: "Don't prescribe how; create gates that reject bad work",
  an event like `build.done` must carry evidence (`tests: pass, lint: pass, typecheck: pass …`).
  **Loop detection:** sliding window of 5 outputs, exit at ≥90 % fuzzy similarity.
- **Takeaways [A]:** the fresh-context iteration with state in files is the same pattern as
  Anthropic's long-running-harness guidance (already adopted in
  `2026-11-22-thread-orchestration-research.md`). The evidence-carrying "done" event is the
  reusable idea: a child's final report must list the gates it passed, and the coordinator
  re-runs them.

### 2.3 Vibe Kanban

Read: `vibe-kanban:crates/{db,git,services,executors}` (sparse) and `docs/` [src]; shutdown
post [doc].

- **Queue:** `TaskStatus { Todo, InProgress, InReview, Done, Cancelled }`
  (`crates/db/src/models/task.rs:14`). Dragging a card to In Progress starts a workspace.
- **Environment:** one git worktree per task via a CLI wrapper
  (`crates/git/src/cli.rs:84` `worktree add`, `:527` `rebase --onto`, in-progress-rebase
  detection and abort). Per-repo `setup_script`, `cleanup_script`, `dev_server_script`,
  `copy_files` (`crates/db/src/models/repo.rs:42-47`). Run reasons: `SetupScript`,
  `CleanupScript`, `ArchiveScript`, `CodingAgent`, `DevServer`.
- **Agents:** executors for Claude, Codex, Amp, Cursor, Droid, Gemini, OpenCode, Qwen, Copilot and
  ACP (`crates/executors/src/executors/`). An `approvals` service brokers tool-permission prompts
  to the UI.
- **Git/merge:** `pr_monitor.rs` polls the git host for PR state and merge status; the UI offers
  Merge, Rebase, conflict resolution ("Automatic resolution works best for most conflicts"). No
  merge queue: a human clicks Merge.
- **Status:** "Vibe Kanban is sunsetting" banner in the README; Bloop "couldn't find a business
  model"; hosted features (issues, comments, orgs) ended after 30 days, "local workspaces will
  continue to function" [doc]. Commits continue from the community.
- **Takeaway [A]:** this is the tool T3 Code most resembles (board + worktree per task + setup
  scripts + PR watch). Nothing to add from it except the explicit `InReview` state and per-repo
  scripts, which T3's `t3.json` already has.

### 2.4 container-use (Dagger)

Read: `container-use:repository/{repository,git}.go`, `environment/{environment,note}.go`,
`README.md`, `docs/quickstart.mdx` [src].

- An MCP server. Each **environment** is a Dagger container plus a worktree in a *fork* of the
  user's repo under `~/.config/container-use/repos/<repo>/worktrees/<id>`
  (`repository/repository.go:69`). Every agent write is committed in the worktree
  (`git.go:567 commitWorktreeChanges`), state and command history go to **git notes**
  (`git.go:454,522`), and the branch is fetched into the user's repo as `container-use/<id>`
  (`repository.go:472`).
- The user reviews with `container-use checkout <id>` and lands with `container-use merge <id>`
  (`merge --no-ff --autostash`, `repository.go:623`) or `apply` (`--squash`, `:635`). Submodule
  gitdirs are propagated by hand (`git.go:322-355`).
- **Takeaway [A]:** the "operational history as git notes" idea is neat for audit, but the whole
  thing presumes Docker-shaped environments. Routelab's environment is a Nix/devenv shell with a
  shared Postgres and an emulator; worktrees plus the planned `agent` Unix user give the same
  isolation with no second toolchain. The project also looks dormant (no push since August).

### 2.5 Attractor (StrongDM) and the digital-twin model

Read: `attractor:attractor-spec.md`, `coding-agent-loop-spec.md` [src]; manifesto [doc].

- Attractor is a **DOT-graph pipeline runner**: nodes are `codergen` (LLM task), `wait.human`
  (hexagon), `conditional`, `parallel`/`fan_in`, `tool`, `stack.manager_loop`; edges carry
  `condition`, `weight`, `loop_restart`. Graph attributes: `goal`, `default_max_retries`,
  `retry_target`; node attributes: `goal_gate` ("this node must reach SUCCESS … before the
  pipeline can exit"), `max_retries`, `timeout`, `llm_model`. **Checkpoint after every node**
  for crash resume; an "interviewer" interface for human questions with timeouts.
- The agent loop spec has explicit **stop conditions** (natural completion, `max_tool_rounds`,
  `max_turns`, abort, unrecoverable error) and **loop detection** on repeating tool-call
  signatures (window 10, patterns of length 1–3) that injects a steering turn.
- The manifesto's verification answer is the **Digital Twin Universe**: behavioural clones of
  third-party services so agents can run "thousands of scenarios per hour", scored
  probabilistically ("what fraction of observed trajectories through all scenarios likely satisfy
  the user") rather than pass/fail [doc].
- **Takeaway [A]:** the graph-with-gates shape is the same as Fractal's missions; routelab's
  `packages/scenarios` (deterministic seeds, content-addressed event ids, hermetic Maestro suite)
  is already a small digital twin of the field. Scenario-based scoring is the direction; the
  $1,000/day budget is not.

### 2.6 What T3 Code already is

From the tool schemas in this session [src: T3 MCP]: `delegate_task` (roles, `isolation:
shared|worktree`, `mode: async|wait` with `timeoutMs`, `runtimeMode` never broader than the
parent, cross-provider `target`), `t3_thread_launch` (worktree from any `baseRef`, `startFromOrigin`),
`schedule_task` (`interval` ≥ 60 s, `fixed_time` with weekdays, `once`, `webhook` with filters
and dedupe; `freshSession`; `bindToCurrentThread`), PR link/watch, devices. **There is no budget
or token field anywhere.** Caps available: `timeoutMs` on waits, `task_cancel`, concurrency by
construction, the Claude plan's usage limits as the backstop, and `claude -p --max-budget-usd`
only outside T3 (print mode) [doc].

---

## 3. Comparison

| | Intake | Queue / ledger | Environment | Git model | Merge | Verification gates | Review | Human checkpoints | Cost control | Dashboard |
|---|---|---|---|---|---|---|---|---|---|---|
| **Stripe Minions** | Slack mention, tickets, CI flaky-test tickets, CLI/web | internal | pre-warmed devbox, no internet/prod | branch per task | human merges PR | lint pre-push; CI, ≤2 rounds; auto-fixes | human | PR review | 2-round cap, scoped tools | internal |
| **Cloudflare review** | MR opened | CI job | CI container | n/a (reviews MRs) | human | n/a | 7 scoped agents + coordinator | approve-with-comments bias | $1.19/review, cache, tiers, circuit breakers | MR comments |
| **Anthropic/Scion** | internal | internal | server-side, sparse checkouts | changesets; no merge-queue lock | post-merge + pre-deploy tests | CI at 25 M checkouts/day | design review ("tell Claude no") | design | n/a | internal |
| **StrongDM/Attractor** | specs + scenarios | pipeline graph | own | unpublished | n/a | DTU scenarios, satisfaction score | **none by humans** | `wait.human` nodes only | none ($1k/day/eng) | event stream |
| **Fractal** | GitHub events, schedules, missions | durable graph of claims | local workspaces per worker | branch per step | gate `ci-passed` on branch; human gate | gates: CI, exec, check, LLM | reviewer agent + human gate | `type="human"` gates; "only decisions reach you" | timeouts per step/mission | TUI/web/mobile |
| **Gas Town/Beads** | `gt sling`, convoys | Beads (Dolt) | worktree, host UID | worktree per polecat; integration branches | **Refinery batch-then-bisect queue** | whatever the Refinery runs | none built in | overseer mail | post-hoc `gt costs` | TUI, convoy status |
| **Ralph / ralph-orchestrator** | PROMPT.md, specs | plan files | one checkout | commit on green | n/a | backpressure evidence in events | reviewer hat | none | `max_iterations`, `max_runtime_seconds` | TUI |
| **Vibe Kanban** | kanban card | SQLite tasks | worktree + setup script | branch per task | Merge button, rebase | your scripts | none | approvals prompt, InReview | none | web board |
| **container-use** | MCP calls | git notes | Dagger container + worktree | `container-use/<id>` | `merge`/`apply` | your commands | none | human merge | none | `log` |
| **Claude Code Projects** | chat, pasted bugs | project memory | Anthropic VM | branch + PR per thread | human; auto-fix | repo CI | optional | Overview "Waiting on you" | plan usage; soft thread limits | Overview pane |
| **Codex cloud** | tasks, GitHub/GitLab | cloud | per-task sandbox, install script, network policy | branch; PR on request | human | repo CI | Codex review | PR | plan | app |
| **GitLab Duo flows** | assign issue | GitLab | GitLab runner | MR per flow | human | runs tests | Code Review flow | MR | credits (0.25/review) | GitLab UI |
| **T3 Code today** | thread prompt | threads | worktree + `t3.json` scripts, devices | branch per thread | human; PR watch | `t3.json` scripts | `delegate_task role:review` | approval modes | none (timeouts, cancel) | sidebar |

---

## 4. The core ideas, and what is real vs hype

### 4.1 Six ideas every working factory shares

1. **State lives outside the agent's context.** A ledger (Beads, Fractal's graph, plan files,
   project memory) and git are the memory; sessions are disposable. Already the house pattern
   here (`2026-11-22-thread-orchestration-research.md` §1.3).
2. **One task → one isolated workspace → one branch.** Everyone converges on worktrees or
   per-task VMs. Nobody shares a working tree between concurrent agents.
3. **Gates decide "done", not the agent.** Fractal says it verbatim; Ralph calls it backpressure;
   Stripe caps CI rounds; Attractor has `goal_gate`. The agent's report is a claim; a command's
   exit code is evidence.
4. **Deterministic first, LLM last.** Stripe's blueprint interleaves deterministic nodes; its ≤2
   CI rounds exist because "CI runs cost tokens, compute, and time". Cloudflare uses risk tiers
   and tells reviewers what not to flag.
5. **Human attention moves up the stack**: to specs and scenarios (StrongDM), design review
   (Anthropic), owner decisions (routelab's own `docs/plans/*owner-decisions*` files already do
   this), and to a queue of "waiting on you" items (Claude Projects, Fractal "only decisions
   reach you").
6. **A merge mechanism that is not a person clicking.** Merge queue (Gas Town Refinery, Origin,
   GitHub stacked PRs GA 2026-10-06 with queue), or post-merge verification (Scion). The branch
   and the review survive; the serialisation is automated.

### 4.2 "Version control optimised for human pace": the claim tested

- **Evidence for strain at scale:** Anthropic's 30,000 merges/day and 25 M checkouts/day broke
  git's clone economics and the global merge-queue lock [doc]. Cursor built Origin around stacked
  PRs and a queue "for AI-written code" [doc]. GitHub's CTO reportedly re-planned capacity 10× →
  30× for agent load [doc, secondary].
- **Evidence that control is kept, not dropped:** Scion keeps changesets, blame, review ("tell
  Claude no") and adds *more* testing; Stripe keeps PRs and human review; Cloudflare adds review
  agents on top of human review; Gas Town's Refinery is a stricter, Bors-style queue than most
  human teams run; Fractal's gates are CI on a branch. DORA 2025's seven AI amplifiers include
  "strong version control practices" and "working in small batches" [doc].
- **Evidence of what happens when the gate is bypassed:** the fintech case study found 27 % of
  merges "rested only on an approval that a coding agent had submitted through the technical
  lead's GitHub account", and recommends separating decision authority from account identity and
  verifying evidence at the integration point [doc]. MergeGym found **47 % of conflicts between
  concurrent agents occur with disjoint file sets** (semantic, not textual), so "when exact replay
  is cheap, verify everything" [doc].
- **Verdict [A]:** factories bypass the *human-paced* parts of version control: a person
  rebasing, a person serialising merges, a person reading every diff. They keep, and usually
  tighten, the machine-paced parts: small commits, branches, executable gates, provenance. The
  honest reformulation for routelab is: *you are already past human pace (one branch, thousands
  of agent commits, no MRs, no CI). A factory would add the machine gates back, not remove more.*

### 4.3 Do code graphs / repo maps help on a large monorepo?

- **For:** RepoGraph (ICLR 2025) "substantially boosts the performance of all systems" on
  SWE-bench as a plug-in (+32.8 % relative in secondary reporting), on 2024 agents and models
  [doc]. KGCompass and CodexGraph report similar gains on SWE-bench Lite [doc, secondary].
- **Against, and more recent:** Codebase-Memory (March 2026, 31 repos): **83 % answer quality
  vs 92 % for a plain file-exploration agent**, at 10× fewer tokens and 2.1× fewer tool calls;
  it only matches or beats exploration on graph-native questions (hub detection, caller ranking)
  [doc]. Amazon (Dec 2025): agentic keyword search reaches ">90 % of RAG-level performance" with
  no vector store [doc]. Boris Cherny: Claude Code tried a local vector DB and agentic search
  "outperformed everything … at the cost of latency and tokens" [doc]. Stripe, with 3 M tests,
  gives minions Sourcegraph *search* via MCP and gets more from **rule files scoped to
  subdirectories** than from global context [doc].
- **Verdict [A]:** a graph index is a **cost** optimisation for very large repos and a help for
  impact questions ("who calls this"), not a quality lever; the newest controlled result is
  negative on quality. Routelab is 6,451 tracked files / 236 MB with a strict type system: the
  type checker (`tsgo`) is the best "graph" an agent can have, and the observer app already ships
  `CODEMAP.md` and `PATTERNS.md` [repo]. Do: scoped `AGENTS.md` per package (Stripe), keep
  `CODEMAP.md`-style maps current (a cheap nightly task), and expose `tsgo`/LSP. Don't: build or
  buy a code knowledge graph.

### 4.4 Verification, spec quality, flaky CI, review load

- **Verification** is where the published systems spend: pre-push lint and tests (Stripe),
  scenario farms (StrongDM), ≥7 reviewers with a coordinator (Cloudflare), post-merge testing at
  25 M checkouts/day (Anthropic). Every one of them caps the loop (Stripe: 2 CI rounds; Ralph:
  iterations and runtime; Attractor: `max_retries`, `max_turns`, loop detection).
- **Spec quality:** 2026 is the year spec-driven development went mainstream (GitHub Spec Kit
  ~150 k stars, AWS Kiro with EARS requirements, Tessl; Fowler/Thoughtworks coverage) [doc].
  Ralph's `requirements/design/plan` triple and Fractal's goal + constraints + gates agree.
  Routelab already has the strongest form of this: 706 files in `docs/plans/` with design docs,
  numbered tasks (`T1.1 (H)`), a "House rules block (paste at the end of every brief)", and
  owner-decision tables with recommendations [repo]. The spec problem is solved; the missing
  part is **acceptance criteria as commands** (what Fractal calls gates).
- **Flaky CI:** Stripe treats flaky-test fixing as a minion task class and applies known auto-fixes
  before resubmitting; Fractal's `eval-flaky-test` mission compares harnesses on the same flaky
  test [doc][src]. Hermetic suites (routelab's `maestro/hermetic`, content-addressed scenario
  ids) are the structural answer.
- **Review load:** Anthropic names human review as the new bottleneck [doc]. The mitigations
  seen: risk-tiered automated review (Cloudflare), evidence attached to the PR (Buildful's
  browser recordings, ralph's evidence events), stacked small PRs (Origin), and a "waiting on
  you" queue instead of a diff list (Claude Projects, Fractal).

---

## 5. Routelab today (read-only audit relevant to a factory)

| Area | Finding [repo] |
|---|---|
| Shape | 19 apps, 43 packages, pnpm 12 + turbo; `tsgo` typecheck; 570 vitest files; Postgres suites (`PROJECTOR_IT=1`) for graph-eventstore and projections; GraphQL schema export as a gate; dashboard Playwright (8 specs); observer Maestro suite (105 flows, hermetic + connected) **written but "no flow has run on a device yet"** (`docs/plans/2026-11-24-observer-e2e-suite.md`) |
| CI | GitLab Free, 400 minutes/month; pipelines **only on merge requests and `main`**, affected-only (`ci/scripts/lib.sh` `ci_filters`/`ci_affected`), content-keyed reuse; a self-managed runner is designed (`infra/stack/src/ci/runner.ts`, `CI_RUNNER_TAG=routelab`) "for when the minutes run out" (`docs/ci.md`) |
| Git flow | HEAD `f137313` on `feat/observability-phase-1`: **4,067 commits ahead of local `main`, 809 ahead of `origin/main` (last updated 2026-10-27), 440 unpushed**; 2,645 commits since 2026-09-01, one author; 202 of the last 200 commit bodies carry Claude attribution; commits in every hour of the day (00–06 h: 62/36/53/57/79/47). No MRs → the `verify`, `test-db` and `gql-schema` jobs have not run on this branch |
| Agent setup | `AGENTS.md` (578 lines, `CLAUDE.md` a copy), `apps/observer/{AGENTS,CODEMAP,PATTERNS}.md`, `.github/skills/` (superpowers set), `.mcp.json` (`npx -y effect-mcp@latest`), `docs/plans/` with the design → plan → owner-decisions convention and `*-owner-decisions-and-reviews.md` as the morning read |
| T3 | `agentic/onboarding` branch (8 commits, not merged): `t3.json` with `defaultThreadEnvMode: local`, `worktreeSubmodules: none`, `setup-worktree.sh` on worktree create, `on-settle.sh`, Typecheck/Lint/Dashboard/Android scripts; AGENTS.md "Agent Workflow and Worktrees" rules (one stream per package, no lockfile changes in the shared checkout, one emulator per machine, shared compose stack `name: routelab-monorepo`) |
| Local stack | `pnpm dev` = docker compose (PostGIS, floci, Greptime/Grafana) + `alchemy dev --stage dev_$USER`; destructive scripts wipe the shared stack; fixed ports |
| Verification you can run locally | `direnv exec . pnpm typecheck` (turbo, concurrency 4), `turbo run test --filter=...`, the Postgres suites against the compose DB, `pnpm dev:schema`, Maestro hermetic flows on butternut's `routelab-e2e` AVD (once they run) |

**Reading [A]:** the owner already works like a factory operator (dispatch plans, read
owner-decision docs in the morning). What is missing is exactly the machine layer the factories
add: gates run per task, an independent review pass, a report with evidence, and a branch per
task instead of one long branch.

---

## 6. Applying it: staged plan

Principles [A]: T3-native where possible; gates are commands with exit codes; one task → one
worktree → one branch; nothing merges overnight in stage 1; the morning report is a file in the
repo, like the owner-decision docs are now.

### 6.1 Stage 1: one weekend, tools that exist today

**Where:** butternut. It is always on, has KVM and the routelab AVDs, 1.8 TB (after the R1–R4
cleanups in `2026-11-17-repo-size-and-parallelism.md`), and T3 already runs there. fern is out:
routelab is not cloned there, `r7i` has no nested virtualisation for the emulator, and 35 GB of
state would have to move. Hosted Claude cloud is out for GitLab (§1.4).

**Intake (the queue):** a committed file, `docs/plans/queue/<date>.md`, one entry per task in the
existing brief format plus two new fields:

```markdown
## Q3  Dashboard: export page shows the manifest's row counts   (area: apps/dashboard; size: S)
Goal: …                     Read first: docs/plans/2026-11-25-exports-and-gtfs-plan.md §T1.6
Accept:                      # the gates, as commands, run from the worktree root
  - direnv exec . turbo run typecheck test --filter=dashboard...
  - direnv exec . pnpm --filter dashboard exec playwright test tests/e2e/export.spec.ts
Don't: lockfiles, codegen, other packages.     Budget: ≤ 90 min wall clock, ≤ 1 review round
```

The "House rules block" the plans already paste stays. Tasks that need Android are tagged so
the coordinator serialises them (one emulator per machine).

**Scheduling:** a T3 `schedule_task` on butternut, `fixed_time` 22:00 on weekdays,
`freshSession: true`, `bindToCurrentThread: false` (a new coordinator thread per night), prompt
= "run the overnight queue for routelab per `.agents/overnight/COORDINATOR.md`". T3-native.

**Coordinator (a skill file, ~100 lines, new glue):** reads the queue, then for each task in
order:
1. `delegate_task` with `isolation: "worktree"`, `role: "implementation"`, `mode: "wait"`,
   `timeoutMs` = the task's budget; on timeout `task_cancel` and mark *timed out*. Concurrency 1
   for Android tasks, otherwise 2 (RAM: Gradle and the emulator are the constraint, not disk).
   Each child gets the brief template from `2026-11-22-thread-orchestration-research.md` §3.2
   with the Accept commands as its Verify section and the report contract as its final message.
2. **Re-run the gates itself** in the child's worktree (`.agents/overnight/verify.sh <worktree>
   <base>`: the CI `verify` logic, i.e. affected packages via `turbo --filter=...{<dir>}`,
   typecheck, vitest; `PROJECTOR_IT=1` suites against the shared compose Postgres only when
   graph-eventstore or projections changed; `pnpm dev:schema` export when schema inputs changed).
   The child's claim is not evidence; the exit code is. New glue, mostly a port of
   `ci/scripts/lib.sh` to run outside GitLab.
3. If green: `delegate_task role: "review"`, fresh context, given the SHA range, the Accept
   list and a Cloudflare-style prompt (flag only: correctness, data loss, security, a violated
   house rule; never style). One fix round by a new child, one re-review. Then stop (Stripe's
   two-round rule).
4. Append to `docs/plans/<date>-overnight-report.md`: task, branch, SHA, gates with their exit
   codes and durations, review verdict and open findings, decisions needed, and an estimate of
   cost from turn counts (T3 does not expose tokens; see §7). Commit the report on the
   coordinator's branch. `agent-notify` → ntfy "overnight: 4 green, 1 failed, 1 needs you".

**Caps:** total tasks per night (e.g. 6), per-task wall clock, two review rounds, concurrency,
and the Claude plan's own usage limit as the backstop. There is no token budget in T3 (§2.6):
state this in the report and ask T3 for one (§8).

**Morning:** branches `overnight/<date>/<id>` sit unmerged; the report tells you which are green.
You merge the green ones into your feature branch (`git merge --ff-only` after a rebase, or a
`land.sh` that rebases each green branch in turn and re-runs typecheck, i.e. a one-machine
Refinery). Failed tasks keep their worktree for inspection; T3's `worktreeCleanup` handles the
rest.

**Prerequisites that are not optional:**
- Merge the `agentic/onboarding` branch's `t3.json` and AGENTS.md rules into the working branch:
  worktree setup, shared caches, hooks path (`2026-11-17-work-projects-review.md` P3–P8).
- Run the Maestro hermetic suite once by hand on butternut's AVD (it has never run on a device).
  Until it passes, Android tasks get typecheck and unit gates only.
- Isolation layers 3–4 from `2026-11-28-agent-isolation-research.md` (the `agent` user, egress
  allowlist) **before** the first unattended `runtimeMode: auto` night. Overnight full access
  under the owner's UID, with the sops primary key and passwordless `doas` in reach, is the one
  thing every factory above is careful about (Stripe's devboxes have no internet or production
  access; Gas Town's own proposal calls the host-UID model a credential-exfiltration risk).

### 6.2 Stage 2: weeks, make the gates real

- **Branch per task, MR per task.** Push each green overnight branch and open a draft MR with
  `glab`; routelab's CI `verify` then runs on it. Register **butternut as the self-managed GitLab
  runner** (`CI_RUNNER_TAG=routelab`, already designed in `infra/stack/src/ci/runner.ts` and
  `docs/ci.md`) so MR pipelines stop costing the Free tier's 400 minutes. This turns the local
  `verify.sh` into the real CI, removes the port of `lib.sh`, and gives the morning report MR
  links with pipeline status. GitLab Free has no merge trains, so landing stays a script or you.
- **Review as a CI job** (Cloudflare pattern): an `opencode`-driven job with two or three scoped
  reviewers (correctness, data/security, house rules) and a coordinator; the cheap passes on
  peacelily's Qwen 35B, the coordinator on Claude. Findings posted as MR notes; the overnight
  fixer reads them.
- **Scenario and screenshot gates for the observer:** hermetic Maestro flows on the butternut AVD
  for any task touching `apps/observer`, with the flow's screenshots diffed against the last
  green run (Maestro screenshots + a pixel/perceptual diff; `packages/scenarios` makes the
  states reproducible). This is routelab's small digital twin.
- **Preview environments:** `alchemy dev --stage dev_<branch>` against the local floci stack for
  a dashboard task, with the dashboard dev server on a free port, so the reviewer agent can
  drive it with Playwright. Real AWS preview stages cost money and time; keep them for release.
- **Spec gate:** a task is refused by the coordinator if its Accept list is empty or not
  runnable. This is the cheapest quality lever found in the research.

### 6.3 Stage 3: months, only if stage 2 pays

- **Factory-as-code:** express the queue as missions with gates (Fractal if it ships and runs on
  NixOS; otherwise a 200-line Effect program over T3's MCP tools using the same vocabulary).
- **Integration branch per epic** (Gas Town) with a batch-then-bisect landing script, so
  multi-task features land as one merge.
- **Cost telemetry:** parse Claude's JSONL transcripts under `~/.claude/projects/` per child
  session (what `gt costs record` does) into the report; alert when a night exceeds a budget.
- **Second host:** fern for CPU-only task classes (packages, gql-api, docs) when butternut is
  saturated, via T3 linked environments, keeping Android on butternut.

### 6.4 What to skip, and why

| Skip | Why |
|---|---|
| Gas Town / Beads | Dolt service, tmux, seven roles, host-UID workers, user reports of breakage and cost; T3 threads plus plan files already give the ledger and the roles you need |
| Vibe Kanban, Conductor, Sculptor | T3 is already the board/worktree manager; Conductor is macOS; Sculptor is experimental and container-shaped |
| container-use | dormant, Docker/Dagger-shaped; worktrees + the `agent` user do the job in a Nix repo |
| Claude cloud sessions / Projects / scheduled tasks / PR Steward | GitHub only; routelab is on GitLab. If TfC ever moves the repo to GitHub, Projects is the hosted version of stage 1 and worth a trial |
| Codex cloud, Tembo, Devin | would work with GitLab, but a second account/harness, repo access for a 35 GB working tree, and no budget visibility you don't already lack |
| StrongDM-style no human review | needs behavioural clones of every dependency and a four-figure daily token budget; field data at stake |
| Code knowledge graph | negative quality evidence (§4.3); use scoped AGENTS.md and `tsgo` |

---

## 7. Open questions for the user

1. **Merge policy.** Overnight branches stay unmerged (stage 1), or auto-land green ones onto
   the feature branch with a rebase + typecheck script? The second is what Gas Town's Refinery
   does; the first is what Stripe does.
2. **Merge requests at all?** The factory's value multiplies if each task becomes an MR and CI
   runs. That means pushing to GitLab nightly and either accepting the 400-minute budget or
   registering butternut as a runner. Is the self-managed runner acceptable to TfC?
3. **GitHub?** Moving routelab (or a mirror) to GitHub unlocks Claude Projects, scheduled tasks
   and PR Steward. A TfC decision, not a technical one.
4. **Budget.** Which Claude plan tier, and what is an acceptable nightly spend in plan usage?
   T3 has no token cap; the only hard caps are task count, wall clock and the plan limit.
5. **Isolation first or factory first?** The `agent` user and egress layers add a week before
   the first unattended night. Running stage 1 under your UID in `auto` mode is possible and
   risky.
6. **First task classes.** Suggested: docs and `docs/plans` upkeep, single-package dashboard
   components, projector tests, `CODEMAP.md` refresh. Android only after the hermetic suite runs.
7. **Review model.** Claude-only reviews, or Qwen 35B on peacelily for a first pass? Cloudflare's
   data says the coordinator needs the strong model; the scoped reviewers don't.
8. **Emulator GPU.** `-gpu host` vs swiftshader on butternut decides whether Maestro gates fit
   in a night (`2026-11-17-t3-devices-routelab.md` "To verify").

---

## 8. Feature requests worth filing against T3

1. A per-child **budget** on `delegate_task` (tokens or USD estimate), surfaced in `task_status`.
2. Token and cost counters per thread (also requested in
   `2026-11-22-thread-orchestration-research.md` §4.3).
3. A `schedule_task` run summary (threads started, finished, failed) the coordinator can read
   without re-reading transcripts.

---

## 9. Sources

Primary write-ups and docs
- StrongDM, *Software Factories and the Agentic Moment* (2026-02-06): https://factory.strongdm.ai/
- Simon Willison on it (2026-02-07): https://simonwillison.net/2026/Feb/7/software-factory/
- StrongDM Attractor specs: https://github.com/strongdm/attractor
- Stripe, *Minions* part 1: https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents and part 2: https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2
- Cloudflare, *Orchestrating AI code review at scale*: https://blog.cloudflare.com/ai-code-review/
- Anthropic, *Redesigning source control* (Scion): https://www.anthropic.com/engineering/redesigning-source-control
- Anthropic 80 % of production code (VentureBeat): https://venturebeat.com/technology/anthropic-says-80-of-its-new-production-code-is-now-authored-by-claude-how-your-enterprise-can-keep-up
- Fractal: https://fractal.how/ , https://fractal.how/llms.txt , demo repo https://github.com/compoundingtech/fractal-factory-demo ; Builder's Day 2026 session list: https://builders.day/stream
- Factory 2.0: https://factory.com/news/software-factory
- Hashnode, *Suddenly everyone is building an AI software factory*: https://hashnode.com/blog/ai-software-factory and *AI software factory tools in 2026*: https://hashnode.com/blog/ai-software-factory-tools
- awesome-software-factories: https://github.com/varun1505/awesome-software-factories
- Gas Town: https://github.com/gastownhall/gastown ; Beads: https://github.com/gastownhall/beads ; Maggie Appleton: https://maggieappleton.com/gastown ; Bill de hÓra: https://dehora.net/journal/2026/2/initial-thoughts-on-welcome-to-gas-town ; HN on v1.0: https://news.ycombinator.com/item?id=47770124 ; SE Daily: https://softwareengineeringdaily.com/2026/02/12/gas-town-beads-and-the-rise-of-agentic-development-with-steve-yegge/
- Ralph: https://ghuntley.com/ralph/ ; ralph-orchestrator: https://github.com/mikeyobrien/ralph-orchestrator
- Vibe Kanban: https://github.com/BloopAI/vibe-kanban ; shutdown: https://www.vibekanban.com/blog/shutdown
- container-use: https://github.com/dagger/container-use ; https://container-use.com/
- Sculptor: https://github.com/imbue-ai/sculptor ; Terragon: https://www.terragonlabs.com/ (shutdown page) ; Tembo: https://www.tembo.io/
- Claude Code docs: cloud sessions https://code.claude.com/docs/en/claude-code-on-the-web , scheduled tasks https://code.claude.com/docs/en/routines , Projects https://code.claude.com/docs/en/claude-projects , PR Steward https://code.claude.com/docs/en/pr-steward , self-hosted environments https://code.claude.com/docs/en/self-hosted-environments , Remote Control https://code.claude.com/docs/en/remote-control , GitLab CI/CD https://code.claude.com/docs/en/gitlab-ci-cd , CLI reference (`--max-budget-usd`, `--max-turns`, `--bg`) https://code.claude.com/docs/en/cli-reference
- OpenAI Codex cloud: https://learn.chatgpt.com/docs/cloud ; Codex app update 2026-04-16: https://openai.com/index/codex-for-almost-everything/ ; reusable environments (TechCrunch 2026-09-29): https://techcrunch.com/2026/09/29/openai-gives-codex-reusable-cloud-environments-that-work-across-devices/
- GitHub Agent HQ: https://github.blog/news-insights/company-news/welcome-home-agents/ ; mission control: https://github.blog/changelog/2025-11-27-a-mission-control-to-assign-steer-and-track-copilot-coding-agent-tasks/ ; Agents tab: https://github.blog/changelog/2026-01-26-introducing-the-agents-tab-in-your-repository
- GitLab Duo Agent Platform: https://docs.gitlab.com/user/duo_agent_platform/ ; GA: https://about.gitlab.com/blog/gitlab-duo-agent-platform-is-generally-available/ ; Free tier credits (18.10): https://about.gitlab.com/blog/gitlab-18-10-agentic-ai-now-open-to-even-more-teams-on-gitlab/
- Cursor Origin (InfoQ): https://infoq.com/news/2026/08/cursor-origin-alternative-github ; Cursor release notes: https://cursor.com/docs/release-notes/origin ; Scion/Origin analysis: https://hackernoon.com/ai-agents-are-killing-the-git-client-not-git-what-anthropics-scion-and-cursors-origin-show
- Devin 2.0 pricing (VentureBeat): https://venturebeat.com/technology/devin-2-0-is-here-cognition-slashes-price-of-ai-software-engineer-to-20-per-month-from-500 ; Cognition self-serve plans: https://cognition.ai/blog/new-self-serve-plans-for-devin
- Jules and background agents overview: https://ssojet.com/blog/background-coding-agents ; Amp pricing: https://tech-insider.org/amp-vs-claude-code-vs-cursor-2026/

Research
- METR, experienced OSS developer RCT (2025-07-10): https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/
- DORA 2025 *State of AI-assisted Software Development*: https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report
- RepoGraph (ICLR 2025): https://arxiv.org/abs/2410.14684
- Codebase-Memory (2026): https://arxiv.org/abs/2603.27277
- Amazon, *Keyword search is all you need*: https://arxiv.org/abs/2602.23368
- Boris Cherny on agentic search vs RAG: https://officechai.com/ai/claude-researcher-explains-how-agentic-search-performed-better-than-rag-for-code-generation/
- *Who Approved This?* (fintech merge-gate case study): https://arxiv.org/abs/2610.28683
- MergeGym / verifier-guided coordination: https://arxiv.org/abs/2610.04779
- Spec-driven development tools (Fowler): https://www.martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html

Routelab facts come from the read-only inspection described in §5 (paths relative to the repo:
`AGENTS.md`, `.gitlab-ci.yml`, `ci/check.yml`, `ci/rules.yml`, `ci/scripts/lib.sh`, `docs/ci.md`,
`docs/plans/2026-11-25-owner-decisions-and-reviews.md`, `docs/plans/2026-11-24-observer-e2e-suite.md`,
`docs/plans/2026-11-25-exports-and-gtfs-plan.md`, `agentic/onboarding:t3.json`, `git log`).
