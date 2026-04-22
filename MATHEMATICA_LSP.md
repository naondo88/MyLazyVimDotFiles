# Wolfram Language Support

This config supports Wolfram Language files through
`lua/plugins/wolfram.lua`. The setup is intentionally local to this
Neovim config and does not rely on Mason for the Wolfram LSP server.

## Filetypes

- `.wl` files are treated as `wolfram`.
- `.wls` files are treated as `wolfram`.
- `.m` files are only treated as `wolfram` when the first ten lines
  contain a Mathematica package marker:
  - `BeginPackage[`
  - `::Package::`

That content check avoids taking over MATLAB or Objective-C `.m` files.

## Tree-sitter

Wolfram highlighting uses `LumaKernel/tree-sitter-wolfram`, pinned to:

```text
ab3506a5b49b7d76a8ed06958d0b2b7be91a5d34
```

The parser is registered manually with `nvim-treesitter` because it is
not part of the default parser registry. It is also re-registered on the
`User TSUpdate` event because nvim-treesitter reloads its parser table
during updates.

The parser repo does not expose its highlight queries where Neovim picks
them up from the parser install directory, so this config carries a copy
at:

```text
queries/wolfram/highlights.scm
```

LazyVim installs the parser because `wolfram` is appended to
`nvim-treesitter`'s `ensure_installed` list.

## LSP

The Wolfram LSP is registered manually through `nvim-lspconfig` as a
server named `wolfram`. It is not installed by Mason.

The server command is:

```text
WolframKernel -noinit -noprompt -nopaclet -nostartuppaclets -noicon -run 'Needs["LSPServer`"]; LSPServer`StartServer[]'
```

When a project has a `middleware/` directory at the detected root, the
command prepends that directory to `$Path` before starting the server:

```text
PrependTo[$Path, "<root>/middleware"]; Needs["LSPServer`"]; LSPServer`StartServer[]
```

This lets project-local Wolfram packages under `middleware/` be found by
the kernel-backed language server.

## Project Roots

The root detector walks upward from the opened file and chooses the first
directory containing either:

- `middleware/`
- `.git/`

If neither exists, it falls back to the file's directory. Single-file
support is enabled.

## Neovim 0.12 Compatibility

The Wolfram LSPServer reports `semanticTokensProvider` as JSON null in a
way that can crash Neovim 0.12's semantic-token client. The config clears
that capability in `on_attach`:

```lua
client.server_capabilities.semanticTokensProvider = nil
```

## Requirements

- `WolframKernel` must be available on `PATH`.
- The Wolfram `LSPServer` paclet must be loadable by
  `Needs["LSPServer`"]`.
- Neovim must be recent enough for the current LazyVim and
  nvim-treesitter setup. This machine is using Neovim 0.12.2.

Mason currently manages editor tools such as `stylua`, `shfmt`, and
`tree-sitter-cli`; it does not manage `WolframKernel` or `LSPServer`.

## Verification

From `~/.config`:

```sh
nvim --headless '+Lazy! sync' '+qa'
nvim --headless '+lua print(vim.filetype.match({ filename = "test.wl" }))' '+qa'
```

Inside Neovim, open a `.wl` file and check:

```vim
:set filetype?
:LspInfo
:checkhealth lazyvim
```

For the Wolfram server itself, this command should start without a
missing-paclet error:

```sh
WolframKernel -noinit -noprompt -nopaclet -nostartuppaclets -noicon -run 'Needs["LSPServer`"]; Quit[]'
```

## Known Limitations

- Cross-file `gd` is limited; the current LSPServer behavior does not
  provide reliable workspace indexing.
- Tree-sitter support includes `highlights.scm` only. There are no local
  `locals.scm` or `injections.scm` queries.
- The tree-sitter parser is old and pinned, so future breakage should be
  handled conservatively rather than tracking its default branch.
