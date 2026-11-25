# Thread orchestration: replacing subagents with T3 threads (research, 2026-11-22)

Goal: run multi-step agent work as **T3 threads** (`delegate_task`, `t3_thread_launch`, …)
instead of Claude Code subagents, with a coordinator that writes a curated brief for each
thread. This doc covers what the evidence says, what T3 0.1.9 actually does, the
patterns to use, and a small proposal. No code changes.

Legend: **[S]** well supported (primary source or several independent studies),
**[V]** verified in T3 source or tool schemas, **[A]** anecdotal or my judgement.

> **"Are subagents still viable?"** See **§2.4**. The nested "Phone app 1/4" entry on
> mobile is a T3 `delegate_task` child. It is not a Claude Code subagent. T3 shows both
> kinds under the parent thread, but only `delegate_task` children are harness-neutral
> and can be managed through T3's tools. Short answer: the subagent *workflow* is viable,
> and T3 runs it natively. Claude Code's *Agent tool* is just the less portable way to get it.

---

## 1. Background review

### 1.1 Context length vs quality ("context rot")

- **Quality drops as input grows, even on easy tasks.** Chroma tested 18 models and found
  performance "grows increasingly unreliable as input length grows". The drop is steeper
  when the question and the needle share few words, and when distractors are present.
  [S] [Chroma, *Context Rot*](https://research.trychroma.com/context-rot) ([code](https://github.com/chroma-core/context-rot))
- **Needle-in-a-haystack overstates real capability.** NoLiMa removes literal word overlap.
  At 32K tokens, 11 of 13 models fell below half their short-context score (GPT-4o: 99.3% → 69.7%).
  [S] [Modarressi et al., ICML 2025](https://arxiv.org/abs/2502.05167)
- **Effective context is well below advertised context.** RULER found most models
  claiming 32K+ hold their quality only at a fraction of that. [S] [Hsieh et al., 2024](https://arxiv.org/abs/2404.06654)
- **Position matters.** Facts in the middle of a long prompt are used worse than facts at
  the start or end. [S] [Liu et al., *Lost in the Middle*](https://arxiv.org/abs/2307.03172)
- **Anthropic says the same about its own models.** Context is "a finite resource with
  diminishing marginal returns", and the goal is "the smallest possible set of high-signal
  tokens". [S] [Anthropic, *Effective context engineering for AI agents*](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- **Caveat.** Frontier models degrade more slowly with each generation. Anthropic markets
  Opus 5.5 / Fable 5.1 as strong at long-context retrieval across 1M tokens
  ([Opus 5.5 announcement](https://www.anthropic.com/news/claude-opus-5-5)). The published
  degradation curves come from older models and synthetic tasks. Nobody has published a
  "quality falls off a cliff at N tokens" figure for current Claude models. Specific
  thresholds you hear ("stay under 40% of the window") are folklore. [A]

**What this means for agent sessions [A, inferred from the above]:** a long coding session
is the hard case for these benchmarks. Its context is full of near-duplicate distractors
(old file versions, failed attempts, superseded plans), and the facts that matter are in
the middle. So degradation probably sets in earlier than retrieval benchmarks suggest.

### 1.2 Pricing: is there a threshold? (checked 2026-11-22)

Source: [Claude pricing docs](https://platform.claude.com/docs/en/about-claude/pricing). [S]

| Model | Input | Output | 5m cache write | 1h cache write | Cache read |
|---|---|---|---|---|---|
| Opus 5.5 | $4 | $20 | $5 | $8 | **$0.20 (0.05×)** |
| Sonnet 5 | $2 | $10 | $2.50 | $4 | $0.20 |
| Haiku 4.5 | $1 | $5 | $1.25 | $2 | $0.10 |

- **There is no long-context price tier on Opus 5.5.** The docs say: "Claude 4.6 and later
  models (except Claude Haiku 5.5) … include the full 1M token context window at standard
  pricing. (A 900k-token request is billed at the same per-token rate as a 9k-token request.)"
- **Where the recalled threshold comes from:** the earlier 1M beta (Sonnet 4/4.5) charged a
  premium above **200K** input tokens. Gemini Pro models still have a 200K tier. Today only
  **Haiku 5.5** has a tier (above 100K). So the "~300k" figure is wrong for current Opus.
- **Why long sessions still cost more:** each request re-sends the whole context. With
  caching, that history is billed at the cache-read rate on every request (every tool call
  is a request). So the cost of one request grows linearly with context, and the cost of a
  whole session grows roughly with the square of its turn count. Claude Code's
  [cost docs](https://code.claude.com/docs/en/costs) say so directly: "a one-line question
  in a session that has been open all day still draws usage for the whole conversation".
  The same applies to subscription plan limits, which are token-based.
- **Rough numbers (Opus 5.5, warm cache) [A, arithmetic]:**
  - A request at 300K context costs about $0.06 in cache reads. At 50K it costs about $0.01.
    Over 150 tool calls that is ~$9 against ~$1.50, before output.
  - Starting a fresh thread costs one cache write of its startup context. That is the
    harness system prompt, tool and MCP listings, CLAUDE.md (~3K tokens here) and the brief:
    roughly 20–40K tokens, so **$0.10–0.30 once**.
  - A cache miss, the first message after more than 5 minutes idle, re-writes the whole
    context at 1.25×. That costs ~$1.50 at 300K and ~$0.25 at 50K. Big idle sessions are
    expensive to resume.

**Conclusion:** the user's two beliefs are directionally right but need correcting.
- On price: there is no price cliff. Cost does grow superlinearly with session length, and
  fresh threads are cheap.
- On quality: degradation with length is well supported in general. No threshold is
  published for current Claude models.

### 1.3 Multi-agent / orchestrator–worker guidance

- **Anthropic's research system** [S] ([*How we built our multi-agent research system*](https://www.anthropic.com/engineering/multi-agent-research-system)):
  - A lead agent with worker subagents beat a single agent by 90.2% on research tasks.
  - It used ~15× the tokens of a chat (single agents use ~4×). Token usage alone explained 80% of the variance in results.
  - Every subagent needs "an objective, an output format, guidance on the tools and sources to use, and clear task boundaries".
  - Vague briefs made subagents "duplicate work, leave gaps, or fail to find necessary information".
  - Coding is a weaker fit: it has "fewer truly parallelizable tasks", and multi-agent struggles when agents must share context.
- **Cognition, *Don't build multi-agents*** [S, opinion from practitioners]
  ([link](https://cognition.com/blog/dont-build-multi-agents)):
  - "Actions carry implicit decisions." Parallel workers that can't see each other's choices produce work that doesn't fit together.
  - Prefer a single linear agent, plus compression for long tasks.
  - This is the strongest argument for **sequential threads over parallel ones** in coding.
- **Anthropic, *Effective harnesses for long-running agents*** [S]
  ([link](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)):
  - Work runs as a series of fresh sessions. Continuity lives in files: a feature list, a progress file and git history.
  - Each session reads them and makes one increment, then commits.
  - This is the "sequential threads on one branch" pattern, written up by Anthropic.
- **Claude Code docs** [S] ([costs](https://code.claude.com/docs/en/costs),
  [context window](https://code.claude.com/docs/en/context-window)):
  - "Clear between tasks." `/compact` is itself a large request, while `/clear` costs nothing.
  - Teammates "load CLAUDE.md, MCP servers, and skills automatically, but everything in the spawn prompt adds to their context". So **don't repeat CLAUDE.md in a brief**.

### 1.4 Compaction vs fresh sessions

| | Compaction (`/compact`, auto) | Fresh thread + curated brief |
|---|---|---|
| Who chooses what survives | a summarizer, in the moment (you can steer it with `/compact focus …`) | the coordinator, on purpose |
| Cost | one large request over the full context, then a smaller session | one small cache write |
| Risk | important details get summarized away; stale assumptions survive as "facts" | the brief misses something, so the child re-explores (and that is visible) |
| Best for | continuing *the same* task when it grew too long | starting a *new* unit of work |

[A] Use compaction as a safety net. The plan is to hand off before you need it.

### 1.5 What session length should I aim for?

[A, synthesis of the evidence above]

- **Size threads by task, not by tokens.** One thread should do **one reviewable unit**:
  one plan task, one commit, one research question.
- **Aim to finish under ~100–150K tokens of context.** For most coding tasks in this repo,
  that is 30–80 tool calls. Past ~200K, treat it as a smell: the task was too big, or the
  thread wandered. Check with `/context` or the T3 context meter.
- **Hand off at natural boundaries**: after a commit, after a design decision, or when the
  task changes type (research → implement → review). Don't wait for the window to fill.
- **Keep the coordinator small too.** It reads child summaries, not diffs or logs.
  Restart the coordinator itself (fresh thread plus a progress file) when it passes ~150K.

---

## 2. What T3 0.1.9 offers

### 2.1 The primitives

| Tool | What it creates | Context the new agent gets | Workspace | How results come back |
|---|---|---|---|---|
| `delegate_task` | **child thread** under the current run | only `task`, prefixed with "Act as the *role* sub-agent" when `role` ≠ general [V]; **no parent history** | `isolation:"shared"` (parent's checkout, the default) or `"worktree"` | async (default): parent is **woken** on completion; `mode:"wait"` blocks (10 min default; a timeout doesn't cancel). Result = the child's **last assistant message** (or its error), via `task_status` [V] |
| `t3_thread_launch` | **top-level thread** (own sidebar entry) | `message` (≤120K chars), attachments | `workspaceStrategy`: `root` / `existing_worktree` / `worktree` (with `baseRef`, `startFromOrigin`) | no wake-up; poll with `t3_thread_wait` / `t3_thread_read` |
| `create_threads` | up to 20 top-level threads in the current checkout | each one's prompt | inherited | as above |
| `t3_thread_send` | a new turn in an existing thread | the thread's history, **or none with `freshContext:true`** (like `/clear`) | that thread's | sending to a finished child starts a fresh task and returns a `taskId` |
| `t3_thread_transfer` | `fork`: a new thread with a *copy* of the context; `merge_back` | the full copied context (the opposite of a curated brief) | same setup | — |
| `t3_worktree_handoff` | moves *this* thread into a new worktree and branch | its own history, plus `continuationPrompt` | new worktree | — |
| `schedule_task` | recurring or one-off runs | `prompt`; `freshSession:true` for no carry-over | bound thread or new | posts in thread |
| `task_status` / `task_cancel` | read or stop a child | — | — | `workState`: working / waiting_for_children / result_available |
| `orchestrator_capabilities` | lists providers and models that can run child tasks | — | — | — |

Other facts from the tool schemas and source [V]:

- A child also loads **its own harness context**. Claude Code brings the system prompt,
  CLAUDE.md/AGENTS.md, auto-memory, skills and MCP listings. OpenCode reads the same
  AGENTS.md (our symlink) and `~/.claude/skills`. So the brief can assume the repo's
  standing rules are already loaded.
- A child **runs in the parent's runtime mode or a narrower one, never a broader one**. It
  cannot watch PRs ("Its parent thread owns the pull request").
- Children can delegate further: the parent then sees `waiting_for_children`. OpenCode
  allows `subagent_depth = 2` in our config.
- **Cross-provider children work today.** `orchestrator_capabilities` shows `claudeAgent`
  (Opus 5.5) and `opencode` (peacelily Qwen3.5 9B/35B-A3B, 32–64K windows), both with
  `canRunCrossProviderChildTask: true`. Use `target: {providerInstanceId:"opencode",
  model:"peacelily/qwen3.5:35b-a3b"}`. Codex, Cursor and the rest are disabled by policy.
- **Linked environments** (beta): `delegate_task` takes `target.environmentId` to run a
  child on another host. `isolation:"worktree"` is **refused** there. Use `t3_thread_launch`
  with `environmentId` and `workspaceStrategy` instead.

### 2.2 Isolation and chaining: what works, what doesn't

**`isolation:"worktree"` starts from the parent's commit** [V]. The server resolves
`HEAD` of the parent checkout, creates the child worktree at that SHA
(`startFromOrigin:false`), then runs the project setup script. Consequences:

- **Uncommitted edits and untracked files do not carry over.** That includes a plan doc you
  just wrote. In this repo it also breaks eval: flakes only see tracked files.
- **Workaround for read-only docs:** the child runs on the same machine, so the brief can
  point at the doc's **absolute path in the main checkout**
  (`/home/hfahmi/nixconf/docs/plans/x.md`). The child reads it there and never edits it.
- **Workaround for code:** commit it (a WIP commit is fine) before dispatching, or use
  `shared`.
- The child's work stays on its own branch. **The coordinator has to merge or cherry-pick
  it.** Nothing flows back except the summary.

**`isolation:"shared"` uses the parent's working tree.** The child sees uncommitted
state, and its edits appear in the parent's tree immediately. That is fine **when only
one agent edits at a time**. Running two editing children in `shared` causes index and
file races, the same hazard CLAUDE.md warns about. Reading in parallel in `shared` is fine.

**Sequential chaining on one branch** has three workable shapes:
1. **Coordinator + `shared` children, one at a time** (default, simplest). Each child
   commits its step and reports the SHA. The next brief cites that SHA and the interfaces
   it created.
2. **One worktree, many fresh children.** The coordinator itself sits in a worktree
   (`t3_worktree_handoff`, or launched with `workspaceStrategy:"worktree"`), then
   dispatches `shared` children. All steps land on that branch, and the main checkout
   stays untouched.
3. **One reused worker thread.** `t3_thread_send(freshContext:true, message: <next brief>)`
   keeps one sidebar entry for the whole chain. It is worth it only for UI tidiness.

What doesn't work:
- Parallel editing children in `shared`.
- Worktree children that depend on uncommitted parent work.
- Expecting a child's *reasoning* to reach the next child. Only what was committed or put
  in the final message carries over.

### 2.3 Cost of each option [A]

| Option | Fixed overhead | Notes |
|---|---|---|
| `delegate_task` shared | one startup cache write (~$0.10–0.30 on Opus 5.5) | cheapest real handoff |
| `delegate_task` worktree | as above, plus worktree creation and the setup script (this repo: cheap; d_abm/routelab: `pnpm install --offline`, direnv warm-up) | disk per worktree; merge work for the coordinator |
| `t3_thread_launch` | as above | user-visible stream; no auto-wake, so the coordinator has to poll or the user checks in |
| `t3_thread_send` fresh | as above | same thread, no history |
| `t3_thread_transfer fork` | **full context re-sent**, cache-cold in the new session | defeats the purpose; use only for "try an alternative with everything I know" |
| OpenCode/Qwen child | no API cost (local GPU) | small windows (32–64K) need even tighter briefs; good for mechanical edits, summaries and searches |

The coordinator pays to read each child's summary, so keep reports short (§3.2).

### 2.4 Three mechanisms: native subagents vs `delegate_task` children vs top-level threads

**What `features.appOwnedSubagents: true` means** [V]:
- T3's data model has one `subagent` record type with a field `origin`, which is either
  `"provider_native"` or `"app_owned"` (contracts schema; `ManagedEndpointRuntime` l.19596).
- **`app_owned`** = a `delegate_task` child. The flag means "this server can create and own
  child tasks itself". It is reported as a constant `true` in the capability block
  (`server-*.mjs` l.46068).
- **`provider_native`** = a subagent the *harness* spawned on its own, such as Claude
  Code's Agent tool. The Claude, Codex, OpenCode, Cursor and ACP adapters each translate
  their harness's subagent events into these records. For Claude, `ClaudeAdapterV2.ts`
  maps each Agent-tool task to a record with a derived `childThreadId` and the native task
  id as `nativeTaskRef`.
- So **T3 also displays Claude Code subagents as nested children**. But
  `task_status` / `task_cancel` / completion wake-ups only work on `app_owned` tasks. All
  their lookups filter on `origin === "app_owned"`.
- Native subagents can at most be *stopped*, and only if the provider supports it. The
  errors "The provider does not support stopping a native subagent" and "…has no owning
  provider session" exist in the source.
- Whether a native child's mirrored thread accepts a `t3_thread_send` was **not verified**.
  Assume it doesn't: the subagent's session belongs to the harness, not to T3.

| | 1. Claude Code Agent tool (native) | 2. T3 `delegate_task` child | 3. Top-level thread (`t3_thread_launch`) |
|---|---|---|---|
| **Harness portability** | Claude Code only. OpenCode has its own, different subagents (also shown by T3 as `provider_native`), so the workflow has to be rewritten per harness | **Harness-neutral**: the same tool from Claude or OpenCode coordinators. The child can be any enabled provider (here: Claude, or OpenCode/Qwen on peacelily) | Harness-neutral; any provider/model via `modelSelection` |
| **Context isolation** | Fresh context with the spawn prompt; built-in types may use a smaller model (Explore) | Fresh provider session with only `task`, plus the harness's own startup context (§2.1) | Fresh session with `message` |
| **Cost** | Startup context plus work; no extra T3 overhead. Shares the parent's subscription limits | Same order (one startup cache write). Can be **free** on local Qwen | Same as 2 |
| **How results return** | Synchronously into the parent's *current turn* as a tool result (background mode exists) | Last assistant message → `task_status.summary`; async children **wake the parent** with a completion notice; `mode:"wait"` blocks up to the timeout | Nothing automatic: the parent polls with `t3_thread_wait` / `t3_thread_read`, or the user relays |
| **User visibility & steering** (desktop + mobile) | Shown nested (mirrored thread), viewable live; stop at most; follow-up in T3 not verified | Shown nested under the parent ("Phone app 1/4"); a full thread: open it, read it, **message it**, interrupt it; `task_cancel` from the parent | Own sidebar entry; fully steerable; can be pinned, snoozed, settled |
| **Worktree / branch** | Parent's cwd; Claude Code's own `isolation: worktree` option is Claude-specific and invisible to T3's worktree management | `shared` (parent checkout) or `worktree` (T3-managed, from the parent's **HEAD commit**, setup script runs) | `root`, `existing_worktree`, or `worktree` from any `baseRef`, optionally from origin |
| **Lifetime** | Ends with its task; tied to the parent turn | Survives the parent's turn; a finished child can be re-tasked (`t3_thread_send`) | Independent of the creator |
| **Failure modes** | Lost if the parent session dies; not cancellable through T3; nests results into the parent context (can bloat it); not reproducible in other harnesses | Commit-before-dispatch trap with worktrees; `shared` edit races; a vague final message is the *only* result; only works in a parent run owned by a T3 MCP session ("Delegated tasks require an active run…") | No auto-wake (easy to forget); no parent/child cancellation cascade; more sidebar clutter |

### 2.5 What the literature says about subagents vs separate sessions

- **Separate contexts help when the work is reading-heavy and parallel.**
  - Anthropic: +90% on research with ~15× tokens ([research system](https://www.anthropic.com/engineering/multi-agent-research-system)).
  - Anthropic's later guide names three good reasons: **context protection, parallelization, specialization**. It puts the cost at "3-10x more tokens" and advises: "Start with the simplest approach that works" ([Claude blog, 2026-01-23](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them)). [S]
- **They hurt when the work is writing-heavy and shares decisions.** Cognition: "actions
  carry implicit decisions" ([link](https://cognition.com/blog/dont-build-multi-agents)).
  LangChain reconciles the two posts: multi-agent suits **reading**, writing needs one
  coherent context, and context engineering is the common core
  ([Chase, 2025](https://www.langchain.com/blog/how-and-when-to-build-multi-agent-systems)). [S]
- **Sequential fresh sessions with file-based continuity** are Anthropic's pattern for long
  coding tasks ([long-running harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)). [S]
- **These sources don't distinguish "subagent" from "separate session".** Whether the worker
  runs inside the harness or as a T3 thread doesn't change the findings. What matters is
  that each worker has a clean context, gets a precise brief, and returns a compact result.
  The mechanism choice is about **portability, visibility and control**, not quality. [A]

### 2.6 Recommendation: when to use which

> **Superseded 2026-11-25.** This section missed that T3 0.1.9 itself injects the
> policy (`provider-core/src/server/orchestrationInstructions.ts`): native foreground
> subagent for a same-model helper with no extra settings, `delegate_task` for another
> model, user-asked settings, a separate checkout or background work. Quality evidence
> doesn't separate the two (§2.5), so the user adopted T3's split, plus "ask the user
> when unclear" and "new top-level threads only on request". The rule now lives in the
> shared agent guidelines (`modules/nixos/features/agent-env/guidelines.md`,
> "Delegation (T3)"). The table below is kept for its per-situation reasoning.

| Situation | Use |
|---|---|
| Plan step, review pass, research question, anything the user may want to watch or steer from the phone | **`delegate_task`** (default). `shared` for sequential work, `worktree` for parallel or risky work |
| Work that should outlive the coordinator, be user-owned, or start from another base branch / host | **`t3_thread_launch`** |
| Cheap mechanical sweeps (grep-and-summarize, bulk renames) | `delegate_task` to **OpenCode/Qwen** |
| A few seconds of read-only lookup inside one turn ("find where X is defined") | Neither: do it inline. If it's verbose (big logs or test output), use a `shared` `delegate_task` with a short report |
| Claude Code Agent tool | **Not needed.** `delegate_task` covers every case with better visibility, cancellation and portability. The only edge it keeps is synchronous in-turn return with no MCP round trip. That doesn't justify a Claude-only workflow, so the user's "no Agent tool" rule stands |

So the user's goal (T3 threads above the harness) and the subagent workflow are not in
conflict. **`delegate_task` children are T3's harness-neutral subagents.**

---

## 3. Recreating the subagent workflow with threads

### 3.1 Patterns

**(a) Sequential plan execution** (the common case; implements a `docs/plans/*-plan.md`)
- Coordinator: reads the plan once, keeps a progress checklist (in the plan file or a
  `## Progress` section), and dispatches **one `shared` child per task**. It waits for
  completion, reads the report, checks the commit (`git show --stat <sha>`, `just check`
  if it's cheap), updates progress, and writes the next brief.
- Size: one plan task per child. If a task's brief needs more than ~1 page of facts, split it.
- Handoff: **commit at the end of every child.** The SHA plus the "interfaces created"
  section of the report are the input to the next brief.

**(b) Parallel independent streams**
- Use only when the streams touch disjoint files and share no undecided design choices.
  Cognition's point: settle the shared decisions *in the coordinator first* and write them
  into every brief.
- Use `isolation:"worktree"` per child. For long-lived or user-visible streams, use
  `t3_thread_launch` with a worktree instead.
- Commit everything the children need before dispatching.
- The coordinator merges the branches in a fixed order and runs `just check` after each merge.

**(c) Review / verification passes**
- Make every review a **new** child (`role:"review"`) with a fresh context, never a
  follow-up in the implementer's thread. The point is independent eyes.
- The brief gives:
  - what changed (SHA range),
  - the spec section it should satisfy,
  - the specific risks to check,
  - "verify each finding against the code before reporting; report confirmed or plausible only".
- Fix small findings in the coordinator, or send them to a new implementer child. Re-review
  with a new child that gets the findings and the fix SHA.
- Use a different model for diversity where it's cheap, e.g. Qwen 35B for a first lint-style
  pass. [A]

**(d) Research fan-out**
- Use N `shared` read-only children (parallel is safe because nobody edits), each with one
  question, the sources to use, and a word budget for the answer.
- The coordinator synthesizes. For big fan-outs, have children write findings to
  scratch files and return only paths plus a 5-line abstract. This keeps the
  coordinator's context small.
- Good use of local Qwen for "find every place X happens" sweeps.

### 3.2 Brief template

```markdown
# <Title: verb + object>            (role: implementation|research|review|test)

## Goal
<1–3 sentences: what "done" means, observable.>

## Read first (only these)
- <abs path>:<line range or §heading> — <why>
- <plan path> §Task N — the spec for this task
(Standing repo rules come from AGENTS.md/CLAUDE.md; do not re-read the whole repo.)

## Verified facts (don't re-check)
- <fact> — <how it was verified: command/source>
- Current HEAD: <sha>; branch <name>; tree clean / dirty files: <list>

## Interfaces from earlier steps
- <option/function/file> created in <sha>: <signature or shape>

## Do
1. <step>  2. <step>  (decisions already made: <list>)

## Don't
- <out-of-scope items, files not to touch, commands not to run>
- No subagents; no `git push`; <repo-specific denials if relevant>

## Verify
- <exact commands, e.g. `just eval hazel`, expected result>

## Finish
- Commit: `<message prefix>`; do not commit <files>.   (or: leave uncommitted)
- Final message = report, ≤ 25 lines:
  STATUS: done | blocked | partial
  COMMIT: <sha>
  CHANGED: <files>
  INTERFACES: <anything the next step needs, exact names>
  VERIFIED: <command → result>
  OPEN: <questions, risks, follow-ups>
```

Rules for the coordinator writing it [A, following the Anthropic sources in §1.3]:
- **Exact paths and sections.** "Read the T3 doc" makes the child re-explore; "§5.2" doesn't.
- **Pass verified facts *with their evidence*,** so the child can trust them and doesn't
  re-verify. Mark guesses as guesses.
- **State the decisions already made.** Implicit decisions are what break parallel and
  sequential work (Cognition).
- **Leave out** the conversation history, rejected options (unless the child is likely to
  re-propose them) and anything already in AGENTS.md.
- **Use the final-message contract.** T3 returns only the last assistant message, so the
  report format *is* the interface.
- Target length: **0.5–1.5 pages.** A brief longer than that means the task is too big or
  the plan file should carry the detail. Link the plan instead of pasting it.

### 3.3 When to commit to hand off

- **Always** before a `worktree` child or a parallel stream needs the code.
- **At the end of each sequential child**, so the next brief can cite a SHA and you can
  revert one step.
- **Untracked plan or design docs:** either commit them, or reference them by absolute path
  in the main checkout (read-only for the child). Remember `git add -N` if anything in Nix
  references them.
- **Do not commit** when the user asked for no commits. Then use `shared` children run
  strictly in sequence, and have each report its changed files instead of a SHA.

---

## 4. Proposal

### 4.1 One harness-neutral skill: `dispatch-thread`

- Put a `SKILL.md` in `~/.claude/skills/dispatch-thread/`, managed by `agent-common.nix`
  alongside the pinned Anthropic skills. Claude Code loads it, and OpenCode already reads
  `~/.claude/skills` (`agent-opencode.nix`), so it works in both.
- Contents, about 80 lines:
  1. When to dispatch: a new unit of work, a change of task type, or context past ~100K.
     Don't dispatch for edits under ~5 minutes.
  2. Picking the primitive: the decision table from §2.1–2.2, condensed (`shared` /
     `worktree` / `t3_thread_launch` / `freshContext`).
  3. Pre-flight checks:
     - Is the needed state committed, or referenced by absolute path?
     - Are the shared decisions settled?
     - Is anyone else editing this tree?
  4. The brief template from §3.2, verbatim.
  5. After completion:
     - Read the report and check the SHA.
     - Update the progress checklist.
     - Write the next brief from the report's INTERFACES section, not from memory.
  6. Coordinator hygiene: keep a progress file, and restart yourself past ~150K tokens.
- Keep tool names in one table so the skill degrades gracefully. A harness without T3 MCP
  falls back to "write the brief to a file and ask the user to start a thread with it".

### 4.2 Repo convention: optional, light

- **No `docs/agents/briefs/` directory by default.** Each brief is already stored as the
  child thread's first message in T3, so a file would duplicate it and go stale.
- **Write a brief to a file only when it's reused**: re-dispatch after failure, a review
  brief that several reviewers share, or one handed to another harness or person. Put it
  next to the plan as `docs/plans/<plan>-briefs/<task>.md`, untracked unless useful.
- **Do** add a `## Progress` section convention to `*-plan.md` files. That is the
  coordinator's external memory (the Anthropic long-running-harness pattern) and what a
  restarted coordinator reads first.

### 4.3 Worth asking T3 for (feature requests)

1. **`delegate_task` `baseRef` and "include working-tree changes"** for worktree isolation.
   This removes the commit-before-dispatch step.
2. **Per-thread token/context stats in `task_status`**, so thread sizes can be measured
   instead of guessed.
3. **An optional result schema on `delegate_task`**, validated against the final message,
   like the report contract in §3.2.
4. **"Continue in a fresh thread"** action: the agent writes a handoff brief and T3 opens a
   new thread with it, linked to the old one. That is compaction done as a handoff.

### 4.4 Next steps

- Write the skill (item 4.1). It's a small HM change in `agent-common.nix`; use
  `skill-creator` / `superpowers:writing-skills`.
- Trial it on the next plan (e.g. `2026-11-22-phone-dictation-keyboard-plan.md`). Note the
  coordinator size, the child sizes and the number of re-explorations, then tune the
  numbers in §1.5.
- Update CLAUDE.md "Agent hazards" with one line: "multi-step work: use the
  `dispatch-thread` skill; no Claude Code subagents".
