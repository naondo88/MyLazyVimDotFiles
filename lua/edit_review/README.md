# Edit Review

An in-neovim AI-edit / code-review workflow: side-by-side diffs, a picker of
changed files, mark-as-reviewed tracking that persists, per-hunk comments, and a
paste-ready markdown report. Design rationale lives in `EDIT_VIEWER_SPEC.md` at
the repo root.

Foundation is [diffview.nvim](https://github.com/sindrets/diffview.nvim) (the
side-by-side red/green view + file panel) driving neovim's native diff engine.
The custom review-tracking layer is `lua/edit_review/init.lua`.

## Keybindings

All under the `<leader>r` ("+review") group.

| Key          | Action                                                        |
| ------------ | ------------------------------------------------------------- |
| `<leader>ro` | **Open** the review diff (diffview: HEAD vs working tree)     |
| `<leader>rf` | **Files** — snacks picker of changed, *unreviewed* files      |
| `<leader>rn` | **Next** unreviewed file                                      |
| `<leader>rp` | **Prev** unreviewed file                                      |
| `<leader>rm` | **Mark** the current file reviewed (toggle)                   |
| `<leader>rc` | **Comment** on the hunk under the cursor (opens report.md)    |
| `<leader>rC` | Finish comment → return to the code line (+ jumplist)         |
| `<leader>rg` | Open the **report** (`report.md`, paste-ready)                |
| `<leader>rd` | **difftastic** structural view of the current file            |
| `<leader>rq` | **Quit** the review (closes diffview)                         |

Inside the picker (`<leader>rf`):

| Key     | Action                                  |
| ------- | --------------------------------------- |
| `<CR>`  | Open that file's diff in diffview       |
| `<a-v>` | Mark the file reviewed (drops from list)|

### Closing the diff viewer

Use **`<leader>rq`** (or `:DiffviewClose`, or `:tabclose`). Do **not** use
`<leader>bd` — diffview opens a multi-window layout in its own tab page, and a
buffer-delete leaves it half-broken.

## How review data is stored

Per project, under neovim's state dir, keyed by a per-session UUID:

```
~/.local/state/nvim/edit-review/<project>/
├── current                       # pointer: path to the active review dir
└── staged-<uuid>/
    ├── meta.json                 # review identity + reviewed flags
    └── report.md                 # comments (also the human report)
```

### `meta.json` — JSON, the nice format for Lua

JSON is the sweet spot here: `vim.json.decode` turns the file into a plain Lua
table in one call (and `vim.json.encode` writes it back) — both are built into
neovim, no dependency. It's also human-readable and git-diffable, unlike a binary
format like `vim.mpack`. (A Lua `return {...}` file would be even more native to
load, but JSON stays friendly to non-Lua tooling and is safer to read untrusted.)

Shape:

```json
{
  "proj": "myrepo",
  "uuid": "staged-93988e1b-...",
  "created": "2026-06-05T14:02:11",
  "baseA_ref": "HEAD",
  "baseA_sha": "cacf5c4",
  "baseB": "WORKTREE",
  "reviewed": {
    "/abs/path/to/file.lua": { "hash": "<sha256>", "at": "2026-06-05T14:05:33" }
  }
}
```

The `reviewed` map is keyed by absolute path. Each entry stores the **content
hash** at review time, so `is_reviewed()` only returns true while the file still
matches — re-edit a reviewed file and it re-surfaces in the picker. The `baseB`
sentinel (`WORKTREE`) is where forward-compat lives: a future PR review just
records two SHAs instead, with no schema change.

### `report.md` — comments + report in one file

The comment buffer *is* this file. Each comment is a section anchored by an
invisible HTML comment (`<!-- id: <abs-path>:<hunk-start-line> -->`) so re-opening
a hunk edits in place instead of duplicating. Code fences grow dynamically (3
backticks, or longer if the quoted code itself contains backticks) so nothing
breaks the markdown. Because the anchors are HTML comments, the file renders
clean — copy/paste it straight into a PR, an issue, or chat.
