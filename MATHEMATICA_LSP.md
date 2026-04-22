Here is a high-level implementation plan you can hand to a coding agent.

## Goal

Set up **Wolfram Language support in Neovim/LazyVim** with:

1. basic filetype and syntax support,
2. optional Tree-sitter highlighting if available,
3. native Neovim LSP integration for the **official Wolfram LSP server**,
4. a clean separation between:

   * **editor tooling**,
   * **Wolfram kernel / LSP startup**, and
   * **project-local Mathematica packages** stored under `middleware/<package>`.

Assume the agent may web search for exact package names, current APIs, and current LazyVim / `nvim-lspconfig` conventions.

---

## Key facts already established

### Wolfram LSP

* The official Wolfram LSP exists.
* It is not typically a standard Mason one-click server.
* It is usually launched by starting the **Wolfram kernel** and loading the `LSPServer` paclet.
* Since the installed Wolfram Engine is `14.3`, the necessary LSP-related paclets are likely already present, but the agent should still verify that they can actually be loaded.

### Mason / LazyVim / lspconfig

* **Mason** is a tool installer and package manager for editor tooling.
* **mason-lspconfig.nvim** bridges Mason-installed servers into Neovim LSP setup.
* **LazyVim** is a higher-level orchestration layer over Neovim plugins and typically configures LSP through `nvim-lspconfig`.
* Mason only helps automatically when a server is represented in Mason’s registry and can be installed as a normal managed tool.
* Wolfram LSP likely needs **manual `lspconfig` wiring**, because the real server entrypoint is a Wolfram kernel invocation rather than a standard standalone binary.

### Local Mathematica packages

* Project-specific Mathematica / Wolfram packages are stored locally under:
  `middleware/<mathematica-package>`
* Example location:
  `~/Git/AgenticMathSolver/middleware/`
* The agent should therefore think about **project-local package discovery / `$Path` augmentation**, not global paclet installation for those local packages.

---

## Deliverables

The coding agent should aim to produce:

1. a working Neovim/LazyVim configuration for Wolfram files,
2. a native LSP config for the official Wolfram LSP,
4. a project-local Wolfram package path strategy for `middleware/*`,
5. a short verification checklist,
6. notes on caveats and fallback options.


1. **What exists already**

   * Wolfram Engine present
   * official Wolfram LSP likely present
   * Mason exists with NeoVim and a LazyVim installation

2. **Architecture**

   * LazyVim
   * Mason
   * mason-lspconfig
   * nvim-lspconfig
   * Wolfram kernel startup model
   * local `middleware/*` package path model

3. **Implementation steps**

   * filetype
   * syntax / Tree-sitter
   * manual LSP registration
   * project-root handling
   * middleware package path bootstrap
   * verification

---

## One-sentence summary for the agent

Implement Wolfram support in LazyVim by treating the official Wolfram LSP as a **manual kernel-launched `lspconfig` server**, not a normal Mason-managed server, and make project-local Mathematica packages under `middleware/*` discoverable through explicit project-root-relative path bootstrapping.
