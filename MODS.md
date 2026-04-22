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

Added a `StripCarriageReturns` autocmd group: on `BufWritePre` for every
pattern, strips `\r` characters from the buffer while preserving cursor
position. Everything else in the file is stock LazyVim boilerplate.

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

## Meta files (non-config)

- `MATHEMATICA_LSP.md` — original planning doc for the Wolfram LSP setup.
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
