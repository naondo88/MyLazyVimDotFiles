# Edit Viewer — Design Spec

A living design doc for an in-neovim AI-edit / code-review workflow. The aim:
review AI (and human) changes locally in a fast TUI — side-by-side diffs, a list
of *which* files changed, jump-to-next-edit navigation, and a GitHub-style
"mark file as viewed" layer that persists. No round-tripping through GitHub's UI.

Decisions are recorded inline. Each open or settled question is tagged:

- `<DESIGN-QUESTION>...</DESIGN-QUESTION>` — the question on the table.
- `<USER-CHOICE>...</USER-CHOICE>` — the user's decision (authoritative).

---

## Implementation status — v1 BUILT

Implemented and verified (headless, against live gitsigns hunks):

- `lua/plugins/edit-review.lua` — installs `sindrets/diffview.nvim` (pinned in
  lazy-lock.json), wires the `<leader>r` keymaps, registers the which-key group.
- `lua/edit_review/init.lua` — the custom review layer:
  - UUID-keyed session under `stdpath("state")/edit-review/<proj>/staged-<uuid>/`
    with `meta.json` (baseA=HEAD, baseB=WORKTREE, reviewed flags) + `report.md`.
  - changed-files enumeration (tracked vs HEAD + untracked).
  - reviewed flags with content-hash (re-edited files re-surface). VERIFIED.
  - snacks.picker of unreviewed changed files; `<a-v>` marks reviewed in-picker.
  - cross-file next/prev unreviewed navigation.
  - per-hunk comments via gitsigns -> anchored sections in report.md, dynamic
    backtick fences (VERIFIED: ``` content -> ```` fence), jumplist return.
  - difftastic terminal view (`<leader>rd`), guarded on `difft` being installed.
- `lua/config/options.lua` — `diffopt` histogram + linematch:60 (user tried it;
  verdict: subtle but kept, set-and-forget).

KNOWN LIMITATIONS / next steps (see parking lot):
- Comment hunks come from gitsigns, which diffs against the index, not strictly
  HEAD — fine for typical unstaged AI edits; revisit if staged-file review drifts.
- baseB = WORKTREE only (no committed-range / PR review yet); structure
  generalizes without migration.
- No re-anchor yet when a reviewed working-tree edit later gets committed.

---

## Goal (from the user)

- Get closer to the code again after a lot of vibe-coding; be active in review.
- Cursor-style edit-diff experience, but native to neovim, driven by kb shortcuts.
- Work happens mostly on **git worktrees** (main worktree vs. branch worktree),
  and also local staged/branch changes. Need diffs between an arbitrary A and B.
- Side-by-side view: removed/old on the **left in red**, new/added on the
  **right in green**, line by line (analogous to VS Code "compare with").
- A picker listing **which files changed**, with:
  - `n`/`N`-style jump to next/previous edit,
  - mark a file as **viewed** (persisted somewhere) so it leaves the list,
  - move on to the next item.
- Dual-purpose bonus: same tooling reviews other people's PRs on the same stack.
- Out of scope (for now): importance-sorted "top edits" list; GitHub integration.

---

## Decisions so far

### Foundation: diffview.nvim + native diff engine

<DESIGN-QUESTION>
Build the diff viewer + file panel on the mature diffview.nvim plugin, or build
a custom viewer on gitsigns + native diff?
</DESIGN-QUESTION>

<USER-CHOICE>
Use **neovim's native diff engine** as the rendering backbone and try it out
first. diffview.nvim is the orchestration layer of choice (file panel, A...B
rev ranges, PR review) since it drives that same native engine — nothing custom
to render. gitsigns (`:Gitsigns diffthis [base]`) is already installed and gives
quick single-file-vs-base dual-buffer diffs using the same engine.
</USER-CHOICE>

Rationale captured during discussion:
- diffview.nvim is not a custom *renderer* — it orchestrates neovim's built-in
  `:diffsplit`. Same red/green output as gitsigns; it adds the file panel,
  arbitrary `A...B` ranges (incl. branch-vs-branch / worktree-vs-worktree, which
  is just a rev range since worktrees share one `.git`), and PR review.
- gitsigns `diffthis` is single-file-vs-base only — no changeset panel.
- ~80% of the original pitch is already solved by these tools; the genuinely
  custom part is the **review-tracking layer** (see below).

### Native diff tuning — IMPLEMENTED, trying out

<DESIGN-QUESTION>
How do we get "meaningful" diffs without difftastic driving the view?
</DESIGN-QUESTION>

<USER-CHOICE>
Set up neovim's newest native diff features and try them before deciding how
much difftastic we still want. Implemented in `lua/config/options.lua`:
`vim.opt.diffopt:append({ "algorithm:histogram", "linematch:60" })`.
</USER-CHOICE>

- `algorithm:histogram` — cleaner hunk boundaries than default Myers (fixes the
  classic "matched the wrong brace" noisy diffs).
- `linematch:60` — neovim's newer feature; re-aligns lines *within* a hunk for
  much sharper intra-line red/green highlighting. Closest native gets to
  difftastic's token-level clarity.
- **STATUS: try this out.** Evaluate whether this alone makes diffs feel good.

### difftastic: optional read-only toggle, NOT the main view

<DESIGN-QUESTION>
How should difftastic be wired in — primary view, optional toggle, or skipped?
</DESIGN-QUESTION>

<USER-CHOICE>
NOT the main side-by-side view. difftastic's structural output can't drive a
two-buffer left/right view without parsing its rendered output and re-deriving
alignment — fragile and dangerous. Keep it (if at all) as a one-key, read-only
"cut through the noise" lens in a terminal split, fired per-file when a diff
looks like formatter churn. Final extent TBD after trying native diff tuning.
</USER-CHOICE>

What difftastic would buy us (its one real strength here): immunity to
reformatting/reflow noise when reviewing AI edits. What it can't do: drive an
editable/navigable two-buffer view, produce a patch, stage hunks, or navigate
like native diff. Wolfram support is irrelevant (user is dropping active Wolfram
use; keeping the config around but not relying on it).

### Picker: snacks.picker (native to this config), NOT Telescope

<DESIGN-QUESTION>
The user said "Telescope" — but this config runs snacks.picker. Which to use?
</DESIGN-QUESTION>

<USER-CHOICE>
**Confirmed: use snacks.picker, not Telescope.** "Whatever LazyVim is using is
what I want" — that's snacks.picker, already the default in this config (the only
Telescope reference is commented-out boilerplate in `lua/plugins/example.lua`).
No new picker dependency.
</USER-CHOICE>

### Review-tracking layer: the genuinely custom part — Phase 2

<DESIGN-QUESTION>
Build the viewer first, then the mark-as-viewed/persistence layer, or all at once?
</DESIGN-QUESTION>

<USER-CHOICE>
Phase the work — viewer first, then the review-tracking layer (leaning toward
this; to be confirmed after we've chatted through the design).
</USER-CHOICE>

This is the ~20% no plugin does well — the part worth building:
- A picker (changed-files list) filtered by a persisted "reviewed" set.
- Toggle a file reviewed; it leaves the list.
- Persist `{diff-range -> {file -> {reviewed, content-hash}}}` in
  `stdpath("state")`. Content-hash so a file *re-appears* if it changes after
  review (better than GitHub's static checkbox).
- Cross-file "jump to next unreviewed edit" (diffview doesn't quite do this).

---

## Keymap namespace (strawman — letters not final)

<DESIGN-QUESTION>
What `<leader>`-prefixed namespace, and what command letters? Must "feel good" —
the user wants a custom, consistent set.
</DESIGN-QUESTION>

<USER-CHOICE>
(Open.) `<leader>r` ("review") proposed — unclaimed in this LazyVim stack
(`<leader>g` is git, `<leader>d` is the DAP/debug prefix and thus avoided).
Strawman commands below; bikeshed once the commands are real.
</USER-CHOICE>

```
<leader>r    +review (which-key group)
<leader>ro   review open   (pick base: staged / branch / worktree)
<leader>rf   review files  (snacks picker of changed files)
<leader>rn   next unreviewed edit (cross-file)
<leader>rp   prev unreviewed edit
<leader>rm   mark current file reviewed (toggle)
<leader>rc   add/edit comment on hunk-under-cursor (opens comment buffer)
<leader>rC   finish comment -> return to the code line (+ push jumplist)
<leader>rg   open the review's report.md (it IS the report; paste-ready)
<leader>rd   difftastic structural view of current file
<leader>rq   quit review session
]r / [r      next / prev edit while inside the diff (home-row n/N analog)
```

### Review comments + report generation — Phase 2 (part of review layer)

<DESIGN-QUESTION>
While reviewing, allow attaching comments to edits, then generate a copy/pasteable
markdown report into a new buffer, appended as the user goes.
</DESIGN-QUESTION>

<USER-CHOICE>
Yes — add this. Store per-comment: `{file uri, BEFORE code, CHANGED code,
USER COMMENT}` (a point-in-time snapshot of the old/new text, not just line
numbers, so comments stay meaningful even if the diff shifts). Render to a
markdown buffer the user can copy/paste, kept appended as review progresses.
</USER-CHOICE>

Data model: each comment is a snapshot record
`{file, line_range, before_text, changed_text, comment, timestamp}` stored in the
same persistence store as review state, keyed by diff-range -> file -> [comments].
The report buffer is a *rendering* of the store (source of truth = store).

Canonical report render (note the fence choice — see sub-question 4):

    ### `src/foo/bar.ts`  ·  L42-58

    **BEFORE**
    ~~~~ts
    old code here
    ~~~~

    **CHANGED**
    ~~~~ts
    edited code here
    ~~~~

    **COMMENT**
    > my comments here

Sub-questions — ALL DECIDED:

<DESIGN-QUESTION>
(1) Comment granularity & trigger.
(2) Comment input UI and edit/return flow.
(3) Persistence: where stored, how keyed.
(4) Fenced-code safety for code that contains backticks.
</DESIGN-QUESTION>

<USER-CHOICE>
(1) **Per-hunk.** A key combo ending in `c` (`<leader>rc`) on the hunk under the
    cursor opens a dedicated comment buffer, auto-populated with the format
    (BEFORE/CHANGED filled from the hunk).

(2) **The comment buffer IS the on-disk report file — opened directly, edited,
    `:w`-saved. No separate scratch buffer or buffer<->store sync step.**
    - Comment identity = **absolute file path + hunk start line** (within the
      current review), encoded as an anchor in the report file: an invisible
      HTML-comment marker, e.g. `<!-- id: <abs-path>:42 -->` (renders to nothing,
      so the file stays paste-ready).
    - On `<leader>rc`: open the review's `report.md`. If NO section exists for
      this hunk's id yet, append a new templated section (BEFORE/CHANGED filled
      from the hunk, empty COMMENT area) and drop the cursor in the COMMENT area.
      If a section ALREADY exists, jump the cursor to its COMMENT area (edit in
      place). `:w` persists — the file is the source of truth.
    - `<leader>rC` finishes: leaves the report file, returns the cursor to the
      original code line, and **pushes the prior position onto the jumplist** so
      `<C-o>`/`<C-i>` navigation stays coherent.

(3) **SUPERSEDES the earlier "key by shaA__shaB" idea — reviews are keyed by a
    per-session UUID, not the SHA pair.** Reason: side B is often the uncommitted
    working tree, which has no SHA. A UUID sidesteps that and is forward-compatible
    with every future comparison type.
    - Layout under `stdpath("state")`:
      `edit-review/<ProjFolderName>/staged-<uuid>/`
        - `meta.json` — what this review compares + review state:
          `{ proj, uuid, created, baseA, baseB, reviewed: {abs_path: {hash, at}} }`
          where `baseA`/`baseB` hold SHAs, a symbolic ref, OR the `WORKTREE`
          sentinel for the uncommitted side. THIS is where forward-compat lives:
          a future PR review records two SHAs; a worktree review records `WORKTREE`.
          No schema change, no migration.
        - `report.md` — the comments document from (2); opened directly, the single
          source of truth for comment text + BEFORE/CHANGED snapshots.
    - `<ProjFolderName>` (human-browsable, not a repo hash). Worktrees of one
      project share `.git`, so they can resolve to the same review dir.
    - DOWN-SCOPED for v1: a single in-progress "staged" review per project
      (`baseB = WORKTREE`). The UUID + meta.json structure generalizes to committed
      SHA ranges, PR review, and multiple concurrent reviews later WITHOUT
      migration — the explicit guard requested ("don't pick something that won't
      work for future features").

(4) **Dynamic backtick fences.** Scan the hunk text for the longest run of
    backticks; use that length + 1 for the fence (minimum 3), capped at a sensible
    limit (~10). So ``` in content -> ```` fence, ```` -> 5, etc. All-backtick,
    no tildes. Always include the language tag for syntax highlighting.
</USER-CHOICE>

---

## Open questions / parking lot

- ~~Confirm snacks.picker over Telescope explicitly.~~ DONE — snacks.picker.
- Final keymap letters.
- Persistence key design: RESOLVED — reviews keyed by per-session UUID under
  `<ProjFolderName>/staged-<uuid>/`, with `meta.json` recording `baseA`/`baseB`
  (SHAs, symbolic refs, or `WORKTREE`). Sidesteps "B has no SHA"; forward-compat
  for PR/SHA reviews with no migration. v1 down-scoped to one working-tree review
  per project. STILL OPEN: (a) reviewed-flag stability when the working tree is
  re-edited after review — content-hash so a changed file re-surfaces (the
  before/changed snapshot already keeps comments meaningful); (b) re-anchoring a
  WORKTREE review's comments if/when those edits get committed (B gains a SHA).
- Whether difftastic earns its keep after native `linematch` tuning is tried.
- (Future / out of scope) importance-sorted "top edits" list; GitHub integration.

---

## Handoff — picking this up on another machine

Everything below is what a fresh agent (or future-you) needs to get this running,
verify it, and continue the work. The design rationale is above; this is the
operational layer.

### What's on disk (the whole feature)

| Path | Role |
| --- | --- |
| `lua/plugins/edit-review.lua` | Lazy plugin spec: installs diffview.nvim, wires all `<leader>r*` keys, registers the which-key group, calls `require("edit_review").setup()`. |
| `lua/edit_review/init.lua` | The custom review layer (sessions, reviewed flags, picker, nav, comments, report, difftastic). ~500 lines, no external deps beyond what's below. |
| `lua/edit_review/README.md` | User-facing keybindings + storage-format reference. |
| `lua/config/options.lua` | One line: `diffopt:append({ "algorithm:histogram", "linematch:60" })`. |
| `EDIT_VIEWER_SPEC.md` | This file — design + decision log + handoff. |
| `MODS.md` | Port-forward checklist; has entries for all of the above. |

There is **no** machine-specific config in any of these — they're pure config,
safe to `git pull` onto any box.

### Dependencies

| Dependency | Status | Notes |
| --- | --- | --- |
| **neovim ≥ 0.12** | required | `linematch` in `diffopt` needs it; LazyVim on this config already wants 0.12 (see MODS.md "System-level changes"). |
| **diffview.nvim** | auto | Lazy installs it on first `:Lazy sync`, pinned in `lazy-lock.json` at `4516612fe98ff56ae0415a259ff6361a89419b0a`. |
| **gitsigns.nvim** | already in LazyVim | Source of hunks for `<leader>rc`. No setup needed. |
| **snacks.nvim** (picker) | already in LazyVim | Backs `<leader>rf`. No setup needed. |
| **git** | required | All change-detection shells out to `git`. |
| **uuidgen** | optional | Session id; there's a `os.time()+random` fallback if absent. |
| **difftastic (`difft`)** | optional | Only for `<leader>rd`; guarded — feature degrades to a notify if missing. Install: `cargo install difftastic` or your package manager's `difftastic`. |
| A **Nerd Font** | cosmetic | The which-key group icon `󰊢` renders as tofu without one. Harmless. |

### First-run setup on the new machine

1. `git pull` the config (these files are committed — see the commit note below).
2. Launch `nvim`, run `:Lazy sync`. This clones diffview.nvim at the pinned
   commit. (If `lazy-lock.json` is committed, you get the exact pin; if not,
   you get diffview HEAD — fine, but pin it back with `:Lazy lock` for parity.)
3. Restart nvim. Confirm the plugin loaded lazily: `:DiffviewOpen` should exist
   as a command, and `<leader>r` should show the "+review" which-key menu.
4. (Optional) install `difft` if you want `<leader>rd`.

### 90-second smoke test (manual, in a repo with uncommitted changes)

Do this in any git repo that has at least one modified + one untracked file:

1. `<leader>ro` — diffview opens, red(left)/green(right), file panel on the side.
2. `<leader>rf` — snacks picker lists the changed files. `<CR>` opens one.
3. In the picker, `<a-v>` on a file — it drops off the list (marked reviewed).
4. `<leader>rn` / `<leader>rp` — jumps to next/prev *unreviewed* file.
5. Put the cursor on a changed hunk, `<leader>rc` — `report.md` opens in a right
   split with a BEFORE/CHANGED section pre-filled; cursor lands under
   `**COMMENT**` in insert mode. Type a note.
6. `<leader>rC` — saves, closes the split, returns to the exact code line
   (and `<C-o>` jumps back, proving the jumplist push).
7. `<leader>rg` — opens the full `report.md`; it's clean paste-ready markdown.
8. `<leader>rq` — closes diffview cleanly (the whole tab, not a stuck split).

If all 8 pass, the feature is healthy on that machine.

### Headless test recipe (for an agent — what works, what doesn't)

When iterating without a TTY, **do not** use `nvim --headless +"lua << EOF ..."`
— a `lua` heredoc is only valid inside a *script*, not as a `+command`, and you
get `E5107: unexpected symbol near '<'`. Instead write the test to a file and
`luafile` it:

```sh
# /tmp/ertest.lua contains the test body
nvim --headless -c "luafile /tmp/ertest.lua" -c "qa!"
```

The comment flow was verified this way against **live gitsigns hunks** in a
throwaway git repo (init repo, commit a file, edit it, open the buffer so
gitsigns attaches, then call `require("edit_review").comment()` and assert on
`report.md`). Re-use that harness when touching `build_section`/`comment`.

### Code map / data flow (so you don't have to re-derive it)

- **Session** (`M.get_session`): resolves git root → project name = basename →
  `stdpath("state")/edit-review/<proj>/`. A `current` pointer file names the
  active `staged-<uuid>/` dir. First run writes `meta.json` + a `report.md`
  header. Cached in `M._session` (keyed by root, so `:cd` across repos is safe).
- **Reviewed flags** live in `meta.json#reviewed` keyed by **absolute path**,
  each `{ hash, at }`. `is_reviewed` returns true only if the file's current
  sha256 still equals the stored `hash` — that's the "re-edited file
  re-surfaces" behavior. Toggling re-saves `meta.json` immediately.
- **Changed files** (`M.changed_files`): `git diff --name-only
  --diff-filter=ACMRD HEAD` (tracked) ∪ `git ls-files --others
  --exclude-standard` (untracked), deduped + sorted.
- **Picker** is `Snacks.picker.pick` with a `finder` that filters out reviewed
  files; `<a-v>` → custom `er_mark_reviewed` action → toggle + `picker:find()`
  (live refresh). `confirm` (`<CR>`) closes + `DiffviewOpen HEAD -- <rel>`.
- **Comments**: hunk under cursor comes from `gitsigns.get_hunks(buf)`; anchor =
  `<abspath>:<hunk.added.start>`. `report.md` opened in a `botright vsplit`; an
  existing `<!-- id: ... -->` marker → jump in place, else append a templated
  section. `M._return`/`M._report_win` carry the round-trip state for
  `finish_comment` (save → close split → `<line>G` back into the jumplist).
- **difftastic** (`<leader>rd`): runs `GIT_EXTERNAL_DIFF=difft git diff HEAD --
  <rel>` in a `termopen` split. Pure read-only lens, never drives the 2-buffer
  view (see the difftastic decision above for why).

### Sharp edges the next agent should know

- **gitsigns diffs against the git *index*, not strictly HEAD.** So if you `git
  add` a file, `<leader>rc` may see no hunk for the staged portion. Fine for the
  common case (unstaged AI edits); revisit if you start reviewing staged work.
  diffview itself *does* compare against HEAD (`DiffviewOpen HEAD`), so the
  viewer and the comment-hunk source can diverge for staged files — a known
  seam, not a bug to "fix" blindly.
- **`baseB = WORKTREE` only.** No committed-range / branch-vs-branch / PR review
  is wired yet, even though `meta.json` is shaped for it (record two SHAs instead
  of the `WORKTREE` sentinel; no migration). This is the single biggest piece of
  intended-but-unbuilt scope — see parking lot item on PR review.
- **No re-anchoring** when a reviewed working-tree edit later gets committed (the
  before/changed snapshot in `report.md` keeps the comment meaningful, but the
  `<abspath>:<line>` anchor can go stale). Parking-lot item (b).
- **State is machine-local and disposable.** `rm -rf
  ~/.local/state/nvim/edit-review/<proj>` resets all review state for a project
  with zero risk to the repo. Handy when testing.
- **Don't close diffview with `<leader>bd`.** It's a multi-window tab layout;
  buffer-delete strands it. Use `<leader>rq` / `:DiffviewClose` / `:tabclose`.

### Commit state

As of this writing the feature was left **uncommitted** in the working tree for
review. Before moving machines, commit it (or it won't `git pull` over). Suggested:

```sh
git add lua/plugins/edit-review.lua lua/edit_review/ lua/config/options.lua \
        EDIT_VIEWER_SPEC.md MODS.md lazy-lock.json
git commit -m "Add Edit Review: in-nvim AI-edit / code-review workflow"
```

Include `lazy-lock.json` so the diffview pin travels with it.
