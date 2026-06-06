# Edit Review

An in-neovim AI-edit / code-review workflow: side-by-side diffs, a picker of
changed files, mark-as-reviewed tracking that persists, per-hunk comments, and a
paste-ready markdown report. Design rationale lives in `EDIT_VIEWER_SPEC.md` at
the repo root.

The diff is neovim's **native side-by-side `:diff`, opened right in your normal
tab** — no separate UI, no extra "mode" to escape. neo-tree, bufferline,
lualine, `<leader>db`, etc. all stay stock LazyVim because you never leave your
layout. The left window is the base (read-only); the right is the new side. For
an **uncommitted** review the right side is your *real, editable working-tree
file*; for a **committed-range** review both sides are read-only blobs (you can't
rewrite history). All logic lives in `lua/edit_review/init.lua`; the `<leader>r*`
keymaps are in `lua/config/keymaps.lua`.

> diffview.nvim is still installed (see `lua/plugins/edit-review.lua`) but is
> **not** part of this flow — it's just kept around for ad-hoc `:DiffviewOpen`.

## Keybindings

All under the `<leader>r` ("+review") group.

| Key          | Action                                                        |
| ------------ | ------------------------------------------------------------- |
| `<leader>ro` | **Open** the review — pick a base (see *Review bases* below)  |
| `<leader>rl` | **Reflog** — pick two commits to review a range               |
| `<leader>rf` | **Files** — snacks picker of changed, *unreviewed* files      |
| `<leader>rn` | **Next** unreviewed file                                      |
| `<leader>rN` | **Prev** unreviewed file                                      |
| `<leader>rm` | **Mark** the current file reviewed (toggle)                   |
| `<leader>rh` | Mark the **hunk** under the cursor reviewed (toggle)          |
| `<leader>rc` | **Comment** on the hunk under the cursor (opens report.md)    |
| `<leader>rC` | Finish comment → return to the code line (+ jumplist)         |
| `<leader>rg` | Open the **report** (`report.md`, paste-ready)                |
| `<leader>rd` | **difftastic** structural view of the current file            |
| `<leader>rq` | **Quit** the review (closes the diff split)                   |

Inside the diff, on the **right (new) side**:

| Key          | Action                                          |
| ------------ | ----------------------------------------------- |
| `]c` / `[c`  | Next / prev **change**, centered (`zz`); also `]h`/`[h` |
| `<leader>rc` | Comment on the hunk under the cursor            |
| `<leader>uw` | Toggle word-wrap on **both** panes together     |

`]c`/`[c` are normally treesitter "next class" and `]h`/`[h` gitsigns hunks; this
feature rebinds all four to the native change-jump **only inside the review diff
buffers** (restored on `<leader>rq`).

**Word wrap:** vimdiff aligns the two panes by *buffer line*, so turning wrap on
in just one pane (stock `<leader>uw`) misaligns every long line. Inside the
review diff, `<leader>uw` is shadowed to toggle wrap on **both** panes at once —
identical lines then wrap identically and stay aligned; only genuinely-different
lines drift. (`diffopt+=followwrap` keeps the setting across diff refreshes.)
It's not pixel-perfect — that's a fundamental vimdiff limitation — but it's
usable. The override is removed on `<leader>rq`.

Inside the file picker (`<leader>rf`):

| Key     | Action                                  |
| ------- | --------------------------------------- |
| `<CR>`  | Open that file's native diff            |
| `<a-v>` | Mark the file reviewed (drops from list)|

## Review bases

`<leader>ro` asks what to review. There are two kinds of review, both tracked
the same way (reviewed flags + comments persist, deduped per base):

| Choice                                   | Compares                          | Comment hunks |
| ---------------------------------------- | --------------------------------- | ------------- |
| **Reopen current review**                | whatever was active last          | —             |
| **Uncommitted** — HEAD ↔ working tree    | `HEAD` vs your working tree        | gitsigns      |
| **Branch vs branch (A..B)**              | two refs, two-dot                 | `git diff`    |
| **PR / topic vs base (base...HEAD)**     | merge-base of base & HEAD → HEAD  | `git diff`    |
| **Pick two commits (reflog)**            | two commits A..B                  | `git diff`    |

The **uncommitted** review uses gitsigns for the hunk under the cursor (so it
reflects unsaved edits). **Committed-range** reviews (the bottom three) are a
snapshot of two commits: meta.json records both SHAs, and `<leader>rc` parses
the hunk straight from `git diff` since gitsigns can't attach to committed blobs.
Re-picking the same base resumes that review; a different base is its own review.

### Reflog commit picker (`<leader>rl`)

For "I want to diff *these two* commits" without typing SHAs: `<leader>rl` (also
the *Pick two commits (reflog)* entry in the `<leader>ro` menu) walks you through
two single-select snacks pickers over `git reflog`, each previewing the commit's
diff with `git show`. `<Tab>` or `<CR>` accepts the highlighted commit (no
multi-select):

1. **Pick the newer commit** (B, right side) — it's at the top of the reflog.
2. **Pick the older commit** (A, left side) — this picker lists **only commits
   before your first pick**, so the pair always reads old → new.

That reviews `A..B` (two-dot, direct diff). For the three-dot (merge-base /
PR-style) view, use the **PR / topic vs base** entry instead. The result is an
ordinary committed-range review — reviewed flags + comments persist and dedup by
the SHA pair like the other range bases.

### Closing the diff

Use **`<leader>rq`** — it runs `:diffoff`, closes the base split, restores the
`]c`/`[c` mappings, and returns the window to a normal buffer: a worktree review
ends on your real editable file; a committed-range review (whose panes are
read-only scratch blobs) returns to whatever buffer you had before the review, or
an empty one — never a stranded scratch window. The diff is also always built in
a real editor window (not neo-tree / a picker / a float).

### Per-hunk review

Beyond marking whole files (`<leader>rm`), you can resolve **individual hunks**:

- `<leader>rh` toggles the hunk under the cursor reviewed/unreviewed. A reviewed
  hunk gets a green **`✓` in the sign column** on its changed lines (both panes).
- A hunk's identity is a content-hash of its old+new text, so it survives line
  shifts elsewhere — and **re-editing a hunk re-surfaces it** as unreviewed.
- **Auto-complete:** when every hunk in a file is reviewed, the file is
  automatically marked reviewed too, so it drops from the `<leader>rf` picker and
  `<leader>rn/rN` nav. Unmark any hunk and the file comes back.
- **Auto-advance:** marking a hunk reviewed jumps to the next unreviewed hunk;
  resolving a file's last hunk advances to the next unreviewed file. Likewise
  `<leader>rm` (mark file) jumps to the next file. When nothing is left, the diff
  closes and the **report** opens — you're done.
- **Land on the first edit:** opening any file — via the `<leader>rf` picker,
  `<leader>rn/rN`, or auto-advance — drops the cursor on that file's first change
  (centered), so you start reviewing immediately instead of at line 1.

Stored in `meta.json` under `reviewed_hunks[abs_path][hash]`, parallel to the
file-level `reviewed` map.

### Diff colors

Two layers, because catppuccin (and most themes) paint diffs too faintly to scan:

- **Review diff — side-coded red/green.** The two review panes are colored per
  window via `winhighlight`: the **left (old)** side shows changes in **red**, the
  **right (new)** side in **green** (GitHub / VS Code split style), with the
  changed *word* a bold vivid block. Defined in `define_side_hls()` /
  `WINHL_OLD` / `WINHL_NEW` in `lua/edit_review/init.lua`; cleared on
  `<leader>rq`.
- **All other diffs — global amber.** `lua/config/autocmds.lua` also overrides
  the four native `Diff*` groups globally (added=green, deleted=red, changed
  line=subtle, changed word=amber+bold) via a `ColorScheme` autocmd, so gitsigns
  inline diffs and any `:diffsplit` are legible too. (Single-window diffs can't
  be side-coded, hence amber there.) Tune in `override_diff_colors()`.

## How review data is stored

Per project, under neovim's state dir, keyed by a per-session UUID:

```
~/.local/state/nvim/edit-review/<project>/
├── current                       # pointer: path to the active review dir
├── staged-<uuid>/                # an uncommitted (worktree) review
│   ├── meta.json                 # review identity + reviewed flags
│   └── report.md                 # comments (also the human report)
└── range-<uuid>/                 # a committed-range review (branch/PR/custom)
    ├── meta.json
    └── report.md
```

A project can hold several reviews at once (one worktree review, plus a `range-`
dir per distinct A/B base pair). Reviews are deduped by their base, so reopening
the same comparison resumes the same dir. The `current` pointer names the active
one; `<leader>r*` actions operate on it.

### `meta.json` — JSON, the nice format for Lua

JSON is the sweet spot here: `vim.json.decode` turns the file into a plain Lua
table in one call (and `vim.json.encode` writes it back) — both are built into
neovim, no dependency. It's also human-readable and git-diffable, unlike a binary
format like `vim.mpack`. (A Lua `return {...}` file would be even more native to
load, but JSON stays friendly to non-Lua tooling and is safer to read untrusted.)

Shape — an **uncommitted (worktree)** review:

```json
{
  "proj": "myrepo",
  "uuid": "staged-93988e1b-...",
  "created": "2026-06-05T14:02:11",
  "kind": "worktree",
  "baseA_ref": "HEAD",
  "baseA_sha": "cacf5c4",
  "baseB": "WORKTREE",
  "label": "HEAD .. working tree",
  "speckey": "worktree",
  "reviewed": {
    "/abs/path/to/file.lua": { "hash": "<sha256>", "at": "2026-06-05T14:05:33" }
  },
  "reviewed_hunks": {
    "/abs/path/to/file.lua": { "<hunk-sha256>": { "at": "2026-06-05T14:06:02" } }
  }
}
```

And a **committed-range** review (branch-vs-branch / PR / custom) — same shape,
but `baseB` is a real ref and both sides carry a SHA:

```json
{
  "kind": "range",
  "baseA_ref": "main",  "baseA_sha": "329d3e6",
  "baseB": "feature",   "baseB_sha": "79c9930",
  "range": "two-dot",                       // or "three-dot" for A...B (PR)
  "label": "main..feature",
  "speckey": "main..feature",
  "reviewed": { }
}
```

The `reviewed` map is keyed by absolute path. Each entry stores the **content
hash** at review time, so `is_reviewed()` only returns true while the file still
matches — re-edit a reviewed file and it re-surfaces in the picker.

`kind` + the SHA pair are what generalized the original worktree-only design: the
`WORKTREE` sentinel was where forward-compat was promised, and a committed range
just records two SHAs instead, with no migration. `speckey` is the dedup key —
`"worktree"` or `"<A><dots><B>"` — so reopening the same comparison resumes its
review dir. Legacy metas (pre-`kind`) are read as worktree reviews.

### `report.md` — comments + report in one file

The comment buffer *is* this file. Each comment is a section anchored by an
invisible HTML comment (`<!-- id: <abs-path>:<hunk-start-line> -->`) so re-opening
a hunk edits in place instead of duplicating. Code fences grow dynamically (3
backticks, or longer if the quoted code itself contains backticks) so nothing
breaks the markdown. Because the anchors are HTML comments, the file renders
clean — copy/paste it straight into a PR, an issue, or chat.
