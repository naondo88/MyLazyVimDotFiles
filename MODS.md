# Mods to the vanilla LazyVim starter

Checklist of everything in this config that is *not* from the
`LazyVim/starter` template. Port these forward when re-basing onto a
fresh LazyVim config.

## Git workflow

This checkout tracks personal dotfiles at:

- `origin = git@github.com:naondo88/MyLazyVimDotFiles.git`
- `upstream = git@github.com:LazyVim/starter.git`

To refresh from upstream:

```sh
git fetch upstream
git rebase upstream/main
git push origin main --force-with-lease
```

## Files

### `lua/config/autocmds.lua`

Two additions beyond stock LazyVim boilerplate:

- A `StripCarriageReturns` autocmd group: on `BufWritePre` for every
  pattern, strips `\r` characters from the buffer while preserving cursor
  position.
- An `EditReviewDiffColors` group: a `ColorScheme` autocmd (re-applied on
  every theme switch, plus once at load) that overrides the native diff
  highlights `DiffAdd`/`DiffChange`/`DiffDelete`/`DiffText` with louder
  colors — added=green, deleted=red, changed line=subtle, **changed word
  (`DiffText`)=vivid amber + bold**. catppuccin (and many themes) paint
  these so faintly that a one-word edit is nearly invisible; this makes
  Edit Review's native `:diff` (and all other diffs) legible. Tune the
  hexes in `override_diff_colors()`.

### `lua/plugins/orgmode.lua`

New file. Configures `nvim-orgmode/orgmode` with project-root-relative
paths:

- `org_agenda_files = { <cwd>/notes/**/* }`
- `org_default_notes_file = <cwd>/notes/inbox.org`

Intentional reliance on `vim.uv.cwd()` — works best when nvim is
launched from the repo root (`nvim .`).

### `lua/plugins/wolfram.lua`

New file. Wolfram Language support, three concerns:

1. **Filetype detection** — `.wl` / `.wls` unconditionally map to
   `wolfram`; `.m` is content-sniffed for `BeginPackage[` or `::Package::`
   markers so MATLAB `.m` files aren't hijacked.
2. **Tree-sitter parser** — registers `LumaKernel/tree-sitter-wolfram`
   (pinned to commit `ab3506a5b49b7d76a8ed06958d0b2b7be91a5d34`) via
   `require("nvim-treesitter.parsers").wolfram = { install_info = ... }`.
   Re-registration fires on the `User TSUpdate` event because
   nvim-treesitter's `reload_parsers()` wipes the cached module and
   expects parsers to re-register themselves on the event. Appends
   `"wolfram"` to `opts.ensure_installed`.
3. **LSP** — manual `lspconfig.configs.wolfram` registration (not in
   upstream registry, not installable via Mason). Launches
   `WolframKernel` with kernel flags and `-run 'Needs["LSPServer\`"];
   LSPServer\`StartServer[]'`. `root_dir` walks up for `middleware/` or
   `.git`. `on_new_config` rewrites `cmd` to prepend `<root>/middleware`
   to `$Path` when that dir exists. `on_attach` nulls out
   `semanticTokensProvider` because LSPServer returns it as JSON null
   and nvim 0.12's semantic-tokens client crashes trying to index it.

### `queries/wolfram/highlights.scm`

Copy of `queries/highlights.scm` from `LumaKernel/tree-sitter-wolfram`.
Lives under the config's own rtp at `queries/wolfram/highlights.scm`
(the repo ships its queries at the wrong path for nvim to pick up via
the parser-install dir alone). 94 lines.

### `lua/plugins/edit-review.lua`

New file. Part of the Edit Review feature (in-neovim AI-edit / code-review
workflow). Registers the `<leader>r` ("review") which-key group and keeps
`sindrets/diffview.nvim` installed as an **optional** standalone tool
(lazy on its `Diffview*` commands, `enhanced_diff_hl` on) — diffview is
**not** part of the review flow (that uses native `:diff`); it's just there
for ad-hoc `:DiffviewOpen`. Safe to delete the diffview block if unwanted.

### `lua/config/keymaps.lua`

Beyond the stock LazyVim boilerplate + the `<leader>sa`/`<leader>yc`/`yC`
helpers, defines the Edit Review `<leader>r*` keymaps. Each lazily
`require("edit_review")` on first press.

### `lua/edit_review/init.lua`

New file. The review layer. The diff is neovim's **native side-by-side
`:diff` in the current tab** (no diffview): LEFT = base blob from
`git show <rev>:<path>` (read-only scratch), RIGHT = the new side (the real
editable working file for worktree reviews, a read-only B-blob for ranges).
UUID-keyed review sessions under `stdpath("state")/edit-review/<proj>/`,
deduped per project by base pair. Two kinds: **worktree** (`staged-<uuid>/`,
HEAD vs working tree, gitsigns hunks) and **committed-range**
(`range-<uuid>/`, an `A..B`/`A...B` branch / PR / commit range, two SHAs in
`meta.json`, hunks parsed from `git diff`). `<leader>ro` opens a base
picker (`choose_base`); `<leader>rl` opens a two-step reflog commit picker
(`pick_commits`, `git_show` preview). `]c`/`[c`/`]h`/`[h` are rebound
buffer-locally inside the diff to the native change-jump (centered with
`zz`); `<leader>uw` toggles wrap on both panes. **Per-hunk review**:
`<leader>rh` toggles the hunk under the cursor (content-hashed id), shows a
green `✓` gutter sign, and auto-marks the whole file reviewed once all its
hunks are. Left pane (old) is colored red, right (new) green via
per-window `winhighlight`. `meta.json` (JSON via `vim.json`) holds
kind/baseA/baseB/speckey + content-hashed `reviewed` (file) and
`reviewed_hunks` maps; `report.md` holds per-hunk comments (anchored by
HTML comment, dynamic backtick fences). Picker is snacks.picker. See
`lua/edit_review/README.md` for keybindings + storage format.

### `lua/config/options.lua`

Appends `diffopt` with `algorithm:histogram,linematch:60` (sharper native
diffs; shared by gitsigns and Edit Review's native `:diff`). Otherwise stock.

## Meta files (non-config)

- `MATHEMATICA_LSP.md` — operational notes for the implemented Wolfram
  filetype, Tree-sitter, and LSP setup.
- `EDIT_VIEWER_SPEC.md` — design spec + decision log for Edit Review.
- `lua/edit_review/README.md` — Edit Review keybindings + storage format.
- `MODS.md` — this file.
- `.codex` — empty marker file (Codex CLI sentinel).

## System-level changes (not in this repo)

- `nvim` binary upgraded from 0.11.5 → 0.12.2 (AppImage at
  `/usr/local/bin/nvim`). Required so LazyVim's treesitter pin lifts
  and `vim.list.unique` is available in the nvim-treesitter main
  branch.
- `~/.local/share/nvim/site/parser/wolfram.so` is auto-built by
  nvim-treesitter on first run; nothing to port.

## Known limitations carried forward

- No cross-file `gd` for Wolfram — LSPServer does not index the
  workspace; definitions resolve only within the current buffer.
- Tree-sitter queries are `highlights.scm` only (no `locals.scm`,
  `injections.scm`). Highlights use overly-specific capture names like
  `@variable.user_symbol`; nvim's capture hierarchy falls them back to
  standard groups so most colorschemes still paint correctly.
- The parser repo is dormant (last push 2022); revision is pinned.
