-- edit_review: an in-neovim AI-edit / code-review workflow.
-- See EDIT_VIEWER_SPEC.md for the design and decisions behind this module.
--
-- Two review kinds, both UUID-keyed under stdpath("state") with a meta.json
-- recording what is compared:
--   * worktree review — HEAD (baseA) vs the working tree (baseB = WORKTREE).
--     Hunks for comments come from gitsigns (live, reflects unsaved edits).
--   * range review — an arbitrary committed range A..B / A...B (branch-vs-branch
--     or PR-style base...HEAD). Both sides are commits, so meta.json records two
--     SHAs; hunks for comments are parsed from `git diff` (gitsigns can't attach
--     to committed blobs).
-- Reviews are deduped per project by their base pair, so reopening the same
-- comparison resumes its reviewed flags + comments.

local M = {}

local STATE_ROOT = vim.fn.stdpath("state") .. "/edit-review"

-- Seed once at load; only the uuid() fallback (no `uuidgen`) uses math.random.
math.randomseed(os.time())

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Edit Review" })
end

local function git_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
    return nil
  end
  return out[1]
end

--- Resolve a committish to a short SHA (nil if it doesn't resolve).
local function resolve_ref(root, ref)
  local out = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--short", ref })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
    return nil
  end
  return out[1]
end

local function relpath(root, abs)
  local r = root:gsub("/$", "") .. "/"
  if abs:sub(1, #r) == r then
    return abs:sub(#r + 1)
  end
  return vim.fn.fnamemodify(abs, ":.")
end

local function file_hash(abs)
  if vim.fn.filereadable(abs) == 0 then
    return ""
  end
  return vim.fn.sha256(table.concat(vim.fn.readfile(abs), "\n"))
end

local function uuid()
  if vim.fn.executable("uuidgen") == 1 then
    local u = vim.fn.systemlist("uuidgen")[1]
    if u and #u > 0 then
      return (u:gsub("%s", ""))
    end
  end
  return tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
end

local function read_json(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, res = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and res or nil
end

local function write_json(path, tbl)
  -- Recreate the parent dir if it vanished (e.g. the state dir was rm -rf'd for
  -- a reset while a session is still cached in memory) so the save self-heals.
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(vim.json.encode(tbl), "\n"), path)
end

-- Pick a fence longer than any backtick run inside the quoted code (min 3,
-- capped at 10) so code containing ``` doesn't break the markdown report.
local function fence(lines)
  local maxrun = 0
  for _, l in ipairs(lines) do
    for run in l:gmatch("`+") do
      maxrun = math.max(maxrun, #run)
    end
  end
  return string.rep("`", math.min(math.max(3, maxrun + 1), 10))
end

-- Namespace for the per-hunk "reviewed" gutter signs.
local SIGN_NS = vim.api.nvim_create_namespace("edit_review_hunk_signs")

-- Stable identity for a hunk: a hash of its old+new text. Survives line shifts
-- elsewhere in the file, and a re-edit of the hunk changes the hash (so it
-- re-surfaces as unreviewed) — same content-hash philosophy as file review.
local function hunk_id(h)
  local rm = (h.removed and h.removed.lines) or {}
  local ad = (h.added and h.added.lines) or {}
  return vim.fn.sha256(table.concat(rm, "\n") .. "\0" .. table.concat(ad, "\n"))
end

-- The hunks for a file in the current review: gitsigns for a worktree review
-- (live, reflects unsaved edits), parsed `git diff` for a committed range.
local function hunks_for(s, rel, buf)
  if s.kind == "range" then
    return M.git_hunks(s.root, s.revspec, rel)
  end
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    return {}
  end
  return gs.get_hunks(buf) or {}
end

-- ---------------------------------------------------------------------------
-- review identity: spec -> meta -> session
--
-- A "spec" describes the comparison the user asked for:
--   { kind = "worktree" }
--   { kind = "range", a = <ref>, b = <ref>, dotted = <bool> }  -- A..B / A...B
-- A "session" is the loaded review: root, dir, meta, plus the derived `kind`
-- and `revspec` (the string handed to `git diff` for range reviews).
-- ---------------------------------------------------------------------------

--- Stable per-project key for a spec, used to dedup review dirs.
local function spec_key(spec)
  if spec.kind == "worktree" then
    return "worktree"
  end
  return spec.a .. (spec.dotted and "..." or "..") .. spec.b
end

--- The same key, recovered from an on-disk meta.json (handles legacy metas that
--- predate `speckey`/`kind` — those were always worktree reviews).
local function meta_key(meta)
  if meta.speckey then
    return meta.speckey
  end
  if meta.kind == "range" then
    return meta.baseA_ref .. (meta.range == "three-dot" and "..." or "..") .. meta.baseB
  end
  return "worktree"
end

--- Derive (kind, revspec) from a meta table.
local function derive(meta)
  if meta.kind == "range" then
    local dot = meta.range == "three-dot" and "..." or ".."
    return "range", (meta.baseA_sha or meta.baseA_ref) .. dot .. (meta.baseB_sha or meta.baseB)
  end
  return "worktree", (meta.baseA_ref or "HEAD")
end

local function save_meta(session)
  write_json(session.dir .. "/meta.json", session.meta)
end

--- Build a fresh meta table + the report.md header for a spec. Returns the meta,
--- or nil + message on failure (e.g. a ref that doesn't resolve).
local function build_meta(root, proj, dir, spec)
  local now = os.date("%Y-%m-%dT%H:%M:%S")
  local meta, header
  if spec.kind == "range" then
    local sa, sb = resolve_ref(root, spec.a), resolve_ref(root, spec.b)
    if not sa then
      return nil, "Base A '" .. spec.a .. "' did not resolve"
    end
    if not sb then
      return nil, "Base B '" .. spec.b .. "' did not resolve"
    end
    local dot = spec.dotted and "..." or ".."
    local label = spec.a .. dot .. spec.b
    meta = {
      proj = proj,
      uuid = vim.fn.fnamemodify(dir, ":t"),
      created = now,
      kind = "range",
      baseA_ref = spec.a,
      baseA_sha = sa,
      baseB = spec.b,
      baseB_sha = sb,
      range = spec.dotted and "three-dot" or "two-dot",
      label = label,
      speckey = spec_key(spec),
      reviewed = vim.empty_dict(),
    }
    header = string.format("_Base A: %s (%s)  %s  Base B: %s (%s)_", spec.a, sa, dot, spec.b, sb)
  else
    local sha = resolve_ref(root, "HEAD") or "?"
    meta = {
      proj = proj,
      uuid = vim.fn.fnamemodify(dir, ":t"),
      created = now,
      kind = "worktree",
      baseA_ref = "HEAD",
      baseA_sha = sha,
      baseB = "WORKTREE",
      label = "HEAD .. working tree",
      speckey = "worktree",
      reviewed = vim.empty_dict(),
    }
    header = "_Base A: HEAD (" .. sha .. ")  ·  Base B: WORKTREE_"
  end
  write_json(dir .. "/meta.json", meta)
  vim.fn.writefile({
    "# Review report — " .. proj .. "  ·  " .. meta.label,
    "",
    header,
    "",
  }, dir .. "/report.md")
  return meta
end

--- Find an existing review dir in `base` whose meta matches `speckey`.
local function find_review_dir(base, speckey)
  for _, name in ipairs(vim.fn.readdir(base) or {}) do
    if name:match("^staged%-") or name:match("^range%-") then
      local d = base .. "/" .. name
      if vim.fn.isdirectory(d) == 1 then
        local m = read_json(d .. "/meta.json")
        if m and meta_key(m) == speckey then
          return d
        end
      end
    end
  end
end

--- Load a review dir into a session table (no side effects beyond reading).
local function load_session(root, proj, dir)
  local meta = read_json(dir .. "/meta.json") or {}
  meta.reviewed = meta.reviewed or {}
  local kind, revspec = derive(meta)
  return {
    root = root,
    proj = proj,
    dir = dir,
    meta = meta,
    kind = kind,
    revspec = revspec,
    -- baseA kept for back-compat callers; equals the worktree revspec.
    baseA = meta.baseA_ref or "HEAD",
  }
end

--- Start (or resume) the review described by `spec`, make it the current
--- review, and return the loaded session. Reuses an existing matching review
--- dir so reviewed flags + comments persist across reopen.
function M.start_review(spec)
  local root = git_root()
  if not root then
    notify("Not in a git repository", vim.log.levels.WARN)
    return nil
  end
  local proj = vim.fn.fnamemodify(root, ":t")
  local base = STATE_ROOT .. "/" .. proj
  vim.fn.mkdir(base, "p")

  local key = spec_key(spec)
  local dir = find_review_dir(base, key)
  if not dir then
    local prefix = spec.kind == "range" and "range-" or "staged-"
    dir = base .. "/" .. prefix .. uuid()
    vim.fn.mkdir(dir, "p")
    local meta, err = build_meta(root, proj, dir, spec)
    if not meta then
      vim.fn.delete(dir, "rf")
      notify(err or "Could not start review", vim.log.levels.WARN)
      return nil
    end
  end

  vim.fn.writefile({ dir }, base .. "/current")
  M._session = load_session(root, proj, dir)
  return M._session
end

--- Get (or lazily create) the current review session for the project. Defaults
--- to a worktree review when none is active yet.
function M.get_session()
  local root = git_root()
  if not root then
    notify("Not in a git repository", vim.log.levels.WARN)
    return nil
  end
  if M._session and M._session.root == root then
    return M._session
  end

  local proj = vim.fn.fnamemodify(root, ":t")
  local base = STATE_ROOT .. "/" .. proj
  local pointer = base .. "/current"
  if vim.fn.filereadable(pointer) == 1 then
    local p = vim.fn.readfile(pointer)[1]
    if p and vim.fn.isdirectory(p) == 1 then
      M._session = load_session(root, proj, p)
      return M._session
    end
  end

  return M.start_review({ kind = "worktree" })
end

--- Reset the current review (clears its reviewed flags + comments) and start a
--- fresh worktree review.
function M.new_session()
  local root = git_root()
  if not root then
    notify("Not in a git repository", vim.log.levels.WARN)
    return
  end
  local proj = vim.fn.fnamemodify(root, ":t")
  local base = STATE_ROOT .. "/" .. proj
  local pointer = base .. "/current"
  if vim.fn.filereadable(pointer) == 1 then
    local p = vim.fn.readfile(pointer)[1]
    -- Only ever delete inside our own state dir.
    if p and vim.startswith(p, STATE_ROOT .. "/") and vim.fn.isdirectory(p) == 1 then
      vim.fn.delete(p, "rf")
    end
  end
  vim.fn.delete(pointer)
  M._session = nil
  M.start_review({ kind = "worktree" })
  notify("Started a new review session")
end

-- ---------------------------------------------------------------------------
-- base picker (which comparison to review)
-- ---------------------------------------------------------------------------

--- All local/remote branches + tags, for ref selection.
local function all_refs(root)
  local refs = vim.fn.systemlist({
    "git", "-C", root, "for-each-ref", "--format=%(refname:short)",
    "refs/heads", "refs/remotes", "refs/tags",
  })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return refs
end

local function pick_ref(root, prompt, cb)
  local refs = all_refs(root)
  if #refs == 0 then
    notify("No refs found", vim.log.levels.WARN)
    return
  end
  vim.ui.select(refs, { prompt = prompt }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

--- `<leader>ro`: choose what to review, then open it.
function M.choose_base()
  local root = git_root()
  if not root then
    notify("Not in a git repository", vim.log.levels.WARN)
    return
  end
  local items = {
    { label = "Reopen current review", action = "current" },
    { label = "Uncommitted — HEAD ↔ working tree", spec = { kind = "worktree" } },
    { label = "Branch vs branch (A..B)…", action = "branch2" },
    { label = "PR / topic vs base (base...HEAD)…", action = "pr" },
    { label = "Pick two commits (reflog)…", action = "reflog" },
  }
  vim.ui.select(items, {
    prompt = "Edit Review — choose base",
    format_item = function(i)
      return i.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.spec then
      if M.start_review(choice.spec) then
        M.open_review()
      end
    elseif choice.action == "current" then
      M.open_review()
    elseif choice.action == "branch2" then
      pick_ref(root, "Base A (old side)", function(a)
        pick_ref(root, "Base B (new side)", function(b)
          if M.start_review({ kind = "range", a = a, b = b, dotted = false }) then
            M.open_review()
          end
        end)
      end)
    elseif choice.action == "pr" then
      pick_ref(root, "Base branch (merge-base vs HEAD)", function(a)
        if M.start_review({ kind = "range", a = a, b = "HEAD", dotted = true }) then
          M.open_review()
        end
      end)
    elseif choice.action == "reflog" then
      M.pick_commits()
    end
  end)
end

--- A single-select snacks picker over the reflog, previewing each commit with
--- `git show`. Calls `cb(item)` with the chosen commit (item.sha + meta).
--- If `before_ct` is set, only commits strictly older than that commit-time are
--- listed (used for the second pick, so the A..B pair reads old → new).
local function pick_one_commit(root, title, before_ct, cb)
  local Snacks = require("snacks")
  local US = "\31" -- unit separator: safe field delimiter for git --format
  Snacks.picker.pick({
    source = "edit_review_reflog",
    title = title,
    -- Preview the commit under the cursor with `git show` (uses item.commit).
    -- Without this, snacks' default *file* previewer errors ("Item has no
    -- `file`") on every cursor move, since reflog entries aren't files.
    preview = "git_show",
    finder = function()
      local out = {}
      local raw = vim.fn.systemlist({
        "git", "-C", root, "reflog", "--date=short",
        "--format=%h" .. US .. "%gd" .. US .. "%cd" .. US .. "%ct" .. US .. "%gs",
      })
      for _, line in ipairs(raw) do
        local sha, sel, date, ct, subj = line:match("^(.-)\31(.-)\31(.-)\31(.-)\31(.*)$")
        local ctn = tonumber(ct) or 0
        if sha and (not before_ct or ctn < before_ct) then
          out[#out + 1] = {
            text = table.concat({ sha, sel, subj }, " "),
            sha = sha,
            commit = sha, -- consumed by the "git_show" previewer
            sel = sel,
            date = date,
            ct = ctn,
            msg = subj,
          }
        end
      end
      return out
    end,
    format = function(item)
      local a = Snacks.picker.util.align
      return {
        { a(item.sha, 9, { truncate = true }), "SnacksPickerGitCommit" },
        { " " },
        { a(item.sel, 12, { truncate = true }), "SnacksPickerGitBranch" },
        { " " },
        { a(item.date, 10), "SnacksPickerGitDate" },
        { " " },
        { item.msg, "SnacksPickerGitMsg" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      -- Defer: opening the next picker synchronously from inside this confirm
      -- (close + reopen in the same tick) can wedge snacks. schedule() runs it
      -- on the next loop iteration, after this picker has fully torn down.
      if item then
        vim.schedule(function()
          cb(item)
        end)
      end
    end,
    win = {
      -- Single-pick flow: <Tab> *accepts* the highlighted commit, and the
      -- multi-select binds are removed so you can't mark several. (confirm only
      -- ever uses the commit under the cursor, so marks were ignored anyway —
      -- this just stops the confusing visual.)
      input = {
        keys = {
          ["<Tab>"] = { "confirm", mode = { "i", "n" } },
          ["<S-Tab>"] = false,
        },
      },
      list = {
        keys = {
          ["<Tab>"] = "confirm",
          ["<S-Tab>"] = false,
        },
      },
    },
  })
end

--- `<leader>rl`: pick two commits to review, one at a time. Pick the NEWER
--- endpoint first (B, right side); the second picker then lists only commits
--- *older* than it, from which you pick the base (A, left side). Reviews `A..B`
--- (old → new). Each step previews the commit's diff.
function M.pick_commits()
  local root = git_root()
  if not root then
    notify("Not in a git repository", vim.log.levels.WARN)
    return
  end
  pick_one_commit(root, "Edit Review — newer commit (B · right side)", nil, function(b)
    pick_one_commit(root, "Edit Review — older commit (A · left side, before " .. b.sha .. ")", b.ct, function(a)
      if a.sha == b.sha then
        notify("Both picks are the same commit", vim.log.levels.WARN)
        return
      end
      if M.start_review({ kind = "range", a = a.sha, b = b.sha, dotted = false }) then
        M.open_review()
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- changed files + reviewed state
-- ---------------------------------------------------------------------------

--- List files changed in the current review.
--- Returns a sorted list of { rel = <relpath>, abs = <abspath> }.
function M.changed_files(s)
  local root = s.root
  local seen, files = {}, {}
  local function add(rel)
    if rel and rel ~= "" and not seen[rel] then
      seen[rel] = true
      files[#files + 1] = { rel = rel, abs = root .. "/" .. rel }
    end
  end
  if s.kind == "range" then
    for _, rel in ipairs(vim.fn.systemlist({
      "git", "-C", root, "diff", "--name-only", "--diff-filter=ACMRD", s.revspec,
    })) do
      add(rel)
    end
  else
    for _, rel in ipairs(vim.fn.systemlist({
      "git", "-C", root, "diff", "--name-only", "--diff-filter=ACMRD", "HEAD",
    })) do
      add(rel)
    end
    for _, rel in ipairs(vim.fn.systemlist({
      "git", "-C", root, "ls-files", "--others", "--exclude-standard",
    })) do
      add(rel)
    end
  end
  table.sort(files, function(a, b)
    return a.rel < b.rel
  end)
  return files
end

--- A file is "reviewed" only if recorded AND its content still matches the hash
--- captured at review time — so a file re-edited after review re-surfaces.
function M.is_reviewed(abs)
  local s = M._session or M.get_session()
  if not s then
    return false
  end
  local rec = s.meta.reviewed[abs]
  return rec ~= nil and rec.hash == file_hash(abs)
end

function M.toggle_reviewed(abs)
  local s = M.get_session()
  if not s then
    return
  end
  if M.is_reviewed(abs) then
    s.meta.reviewed[abs] = nil
  else
    s.meta.reviewed[abs] = { hash = file_hash(abs), at = os.date("%Y-%m-%dT%H:%M:%S") }
  end
  save_meta(s)
end

function M.toggle_current_reviewed()
  -- Inside a review diff the buffer may be a scratch blob, so prefer the
  -- review's file; otherwise fall back to the current buffer's path.
  local abs = (M._review and M._review.abs) or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  if not abs or abs == "" then
    return
  end
  M.toggle_reviewed(abs)
  local now_reviewed = M.is_reviewed(abs)
  notify((now_reviewed and "Marked reviewed: " or "Unmarked: ") .. vim.fn.fnamemodify(abs, ":t"))
  if now_reviewed then
    M.next_unreviewed() -- jump to the next file (or finish + open the report)
  end
end

-- ---------------------------------------------------------------------------
-- diff viewing — native side-by-side :diff in the current tab (no diffview)
--
-- We open a 2-window vertical diff right in your normal layout/tab:
--   * worktree review: LEFT = HEAD blob (read-only scratch), RIGHT = the real
--     working-tree file (editable; gitsigns stays attached to it).
--   * range review:     LEFT = A blob, RIGHT = B blob (both read-only scratch).
-- `M._review` tracks the open diff so comments/marks anchor to the right (new)
-- side and the split tears down cleanly. Everything else (neo-tree, bufferline,
-- lualine, <leader>db, …) stays stock LazyVim because we never leave the tab.
-- ---------------------------------------------------------------------------

--- File contents at a git revision. Empty list if the path is absent there
--- (an added file has no A-side; a deleted file has no B-side).
local function git_show_lines(root, rev, rel)
  local out = vim.fn.systemlist({ "git", "-C", root, "show", rev .. ":" .. rel })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return out
end

--- A read-only scratch buffer holding `lines`, named `name`, syntax-highlighted
--- by inferring the filetype from `rel`. bufhidden=wipe so it self-cleans.
local function make_blob_buf(name, lines, rel)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  local ft = vim.filetype.match({ filename = rel })
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  return buf
end

-- `]c`/`[c` are taken by treesitter (class) and `]h`/`[h` by gitsigns; LazyVim's
-- diff-fallback for them isn't reliable in scratch/diff buffers. So inside a
-- review diff we bind all four, buffer-locally, straight to the native
-- change-jump — and remove them again on teardown.
local DIFF_JUMP = { ["]c"] = "]c", ["[c"] = "[c", ["]h"] = "]c", ["[h"] = "[c" }

local function set_diff_maps(buf)
  for lhs, native in pairs(DIFF_JUMP) do
    vim.keymap.set("n", lhs, function()
      pcall(vim.cmd.normal, { native, bang = true }) -- jump to the change
      vim.cmd.normal({ "zz", bang = true }) -- and center it on screen
    end, { buffer = buf, silent = true, desc = "Diff: " .. (native == "]c" and "next" or "prev") .. " change (centered)" })
  end
end

local function clear_diff_maps(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  for lhs in pairs(DIFF_JUMP) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  pcall(vim.keymap.del, "n", "<leader>uw", { buffer = buf })
end

local function clear_review_maps(r)
  if not r then
    return
  end
  clear_diff_maps(r.left_buf)
  if r.right_buf ~= r.left_buf then
    clear_diff_maps(r.right_buf)
  end
end

-- vimdiff aligns panes by *buffer line*, so 'wrap' on only one side instantly
-- misaligns every long line. Toggle it on BOTH panes together: identical lines
-- then wrap identically and stay aligned; only genuinely-different lines drift
-- (and 'followwrap' in diffopt keeps the setting across diff refreshes). This
-- shadows LazyVim's window-local <leader>uw, but only inside the review diff.
local function toggle_review_wrap(left_win, right_win)
  local ref = vim.api.nvim_win_is_valid(right_win) and right_win or left_win
  if not vim.api.nvim_win_is_valid(ref) then
    return
  end
  local on = not vim.wo[ref].wrap
  for _, w in ipairs({ left_win, right_win }) do
    if vim.api.nvim_win_is_valid(w) then
      vim.wo[w].wrap = on
    end
  end
  notify("Diff word-wrap " .. (on and "ON (both panes)" or "OFF"))
end

-- Side-coded diff colors: the LEFT (old) pane shows changes in RED, the RIGHT
-- (new) pane in GREEN (GitHub / VS Code split style). Native vimdiff shares one
-- set of Diff* groups across both windows, so we remap them per-window via
-- 'winhighlight' onto these custom groups. nvim_set_hl groups persist across
-- :colorscheme (the theme doesn't know these names), and we redefine them on
-- every open_file anyway, so they always reflect the palette below.
local function define_side_hls()
  -- LEFT / old = red
  vim.api.nvim_set_hl(0, "ERDiffOldAdd", { bg = "#4b2730" }) -- old-only (removed) line
  vim.api.nvim_set_hl(0, "ERDiffOldChange", { bg = "#3a2630" }) -- changed line (old)
  vim.api.nvim_set_hl(0, "ERDiffOldText", { bg = "#e0556a", fg = "#1e1e2e", bold = true }) -- changed word
  -- RIGHT / new = green
  vim.api.nvim_set_hl(0, "ERDiffNewAdd", { bg = "#284b2e" }) -- new-only (added) line
  vim.api.nvim_set_hl(0, "ERDiffNewChange", { bg = "#26392b" }) -- changed line (new)
  vim.api.nvim_set_hl(0, "ERDiffNewText", { bg = "#6cc24a", fg = "#1e1e2e", bold = true }) -- changed word
  -- filler (placeholder where the other side has lines) — muted on both
  vim.api.nvim_set_hl(0, "ERDiffFiller", { bg = "#2a2a35", fg = "#5a5a6a" })
  -- gutter checkmark for a reviewed hunk
  vim.api.nvim_set_hl(0, "EditReviewHunkSign", { fg = "#a6e3a1", bold = true })
end

local WINHL_OLD =
  "DiffAdd:ERDiffOldAdd,DiffChange:ERDiffOldChange,DiffText:ERDiffOldText,DiffDelete:ERDiffFiller"
local WINHL_NEW =
  "DiffAdd:ERDiffNewAdd,DiffChange:ERDiffNewChange,DiffText:ERDiffNewText,DiffDelete:ERDiffFiller"

--- Tear down the active review diff: diffoff, close the base split, restore maps.
local function close_diff()
  local r = M._review
  if not r then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if b == r.left_buf or b == r.right_buf then
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "diffoff")
      end)
      pcall(function()
        vim.wo[win].winhighlight = "" -- drop the red/green remap
      end)
    end
  end
  pcall(vim.api.nvim_buf_clear_namespace, r.left_buf, SIGN_NS, 0, -1)
  pcall(vim.api.nvim_buf_clear_namespace, r.right_buf, SIGN_NS, 0, -1)
  if r.left_win and vim.api.nvim_win_is_valid(r.left_win) then
    pcall(vim.api.nvim_win_close, r.left_win, true) -- force-close wipes the scratch
  end
  clear_review_maps(r)
  M._review = nil
end

-- Make sure we're in a normal editor window (not neo-tree, a snacks picker, or a
-- floating window) before building the diff, so the review isn't jammed into a
-- sidebar and doesn't leave a stray window behind.
local function goto_editor_win()
  local function bad(w)
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      return true -- floating
    end
    local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype
    return ft == "neo-tree" or ft == "neo-tree-popup" or ft:match("^snacks") ~= nil
  end
  if not bad(vim.api.nvim_get_current_win()) then
    return
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not bad(w) then
      vim.api.nvim_set_current_win(w)
      return
    end
  end
  vim.cmd("topleft new") -- only special windows around; make a clean one
end

function M.open_review()
  local s = M.get_session()
  if not s then
    return
  end
  if #M.changed_files(s) == 0 then
    notify("No changes in this review (" .. (s.meta.label or "?") .. ")")
    return
  end
  M.pick_files()
end

--- Open `rel` as a native side-by-side diff in the current tab.
function M.open_file(rel)
  local s = M.get_session()
  if not s then
    return
  end
  -- On the first file of a review session, land in a real editor window and
  -- remember what was there, so quit can restore it instead of stranding a
  -- scratch blob. (Subsequent files reuse the existing review window.)
  if not M._review then
    goto_editor_win()
    M._restore_buf = vim.api.nvim_get_current_buf()
  end
  close_diff() -- tear down any prior review diff first

  local root = s.root
  local abs = root .. "/" .. rel

  -- RIGHT (new) side lives in the current window.
  local right_win = vim.api.nvim_get_current_win()
  local right_buf
  if s.kind == "worktree" then
    vim.cmd("edit " .. vim.fn.fnameescape(abs)) -- the real, editable file
    right_buf = vim.api.nvim_get_current_buf()
  else
    local b_rev = s.meta.baseB_sha or s.meta.baseB
    right_buf = make_blob_buf("edit-review://" .. b_rev .. "/" .. rel, git_show_lines(root, b_rev, rel), rel)
    vim.api.nvim_win_set_buf(right_win, right_buf)
  end

  -- LEFT (base) side: a read-only blob opened to the left.
  local a_rev = s.kind == "worktree" and "HEAD" or (s.meta.baseA_sha or s.meta.baseA_ref)
  local left_buf = make_blob_buf("edit-review://" .. a_rev .. "/" .. rel, git_show_lines(root, a_rev, rel), rel)
  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  vim.api.nvim_win_call(left_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_win_call(right_win, function()
    vim.cmd("diffthis")
  end)
  -- side-coded colors: left (old) = red, right (new) = green
  define_side_hls()
  vim.wo[left_win].winhighlight = WINHL_OLD
  vim.wo[right_win].winhighlight = WINHL_NEW
  set_diff_maps(left_buf)
  set_diff_maps(right_buf)
  -- <leader>uw inside the diff toggles wrap on BOTH panes (keeps alignment)
  for _, b in ipairs({ left_buf, right_buf }) do
    vim.keymap.set("n", "<leader>uw", function()
      toggle_review_wrap(left_win, right_win)
    end, { buffer = b, desc = "Toggle diff word-wrap (both panes)" })
  end
  vim.api.nvim_set_current_win(right_win) -- land on the new side, ready to edit/comment

  M._review = {
    rel = rel,
    abs = abs,
    kind = s.kind,
    left_win = left_win,
    right_win = right_win,
    left_buf = left_buf,
    right_buf = right_buf,
  }
  M._refresh_hunk_signs(s) -- ✓ gutter marks for already-reviewed hunks

  -- Land on the first change ("top edit"), centered. Uses the native diff
  -- motion (works synchronously right after :diffthis, for both kinds — no
  -- waiting on gitsigns). If line 1 isn't itself a change, jump to the first.
  vim.api.nvim_win_call(right_win, function()
    vim.cmd("normal! gg")
    if vim.fn.diff_hlID(vim.fn.line("."), 1) <= 0 then
      pcall(vim.cmd, "normal! ]c")
    end
    vim.cmd("normal! zz")
  end)
end

local function real_file_from_win(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

--- Open two real files as a native side-by-side diff in the current tab.
--- LEFT = selected/reference file; RIGHT = current editor file.
function M.diff_files(left_abs, right_abs)
  left_abs = left_abs and vim.fn.fnamemodify(left_abs, ":p") or nil
  right_abs = right_abs and vim.fn.fnamemodify(right_abs, ":p") or nil

  if not right_abs or right_abs == "" or vim.fn.filereadable(right_abs) == 0 then
    notify("Current buffer has no file", vim.log.levels.WARN)
    return
  end
  if not left_abs or left_abs == "" or vim.fn.filereadable(left_abs) == 0 then
    notify("Selected item is not a file", vim.log.levels.WARN)
    return
  end
  if left_abs == right_abs then
    notify("Cannot diff file with itself", vim.log.levels.WARN)
    return
  end

  if not M._review then
    goto_editor_win()
    M._restore_buf = vim.api.nvim_get_current_buf()
  end
  close_diff()

  local right_win = vim.api.nvim_get_current_win()
  vim.cmd("edit " .. vim.fn.fnameescape(right_abs))
  local right_buf = vim.api.nvim_get_current_buf()

  vim.cmd("leftabove vsplit " .. vim.fn.fnameescape(left_abs))
  local left_win = vim.api.nvim_get_current_win()
  local left_buf = vim.api.nvim_get_current_buf()

  vim.api.nvim_win_call(left_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_win_call(right_win, function()
    vim.cmd("diffthis")
  end)

  define_side_hls()
  vim.wo[left_win].winhighlight = WINHL_OLD
  vim.wo[right_win].winhighlight = WINHL_NEW
  set_diff_maps(left_buf)
  set_diff_maps(right_buf)
  for _, b in ipairs({ left_buf, right_buf }) do
    vim.keymap.set("n", "<leader>uw", function()
      toggle_review_wrap(left_win, right_win)
    end, { buffer = b, desc = "Toggle diff word-wrap (both panes)" })
  end

  vim.api.nvim_set_current_win(right_win)
  M._review = {
    kind = "files",
    left_abs = left_abs,
    right_abs = right_abs,
    abs = right_abs,
    rel = vim.fn.fnamemodify(right_abs, ":."),
    left_win = left_win,
    right_win = right_win,
    left_buf = left_buf,
    right_buf = right_buf,
  }

  vim.api.nvim_win_call(right_win, function()
    vim.cmd("normal! gg")
    if vim.fn.diff_hlID(vim.fn.line("."), 1) <= 0 then
      pcall(vim.cmd, "normal! ]c")
    end
    vim.cmd("normal! zz")
  end)
end

function M.diff_snacks_explorer_selection(picker)
  local selected = picker:selected()

  if #selected == 0 then
    notify("Select one file in explorer", vim.log.levels.WARN)
    return
  end
  if #selected > 1 then
    notify("Select only one file", vim.log.levels.WARN)
    return
  end
  if not selected[1].file or vim.fn.filereadable(selected[1].file) == 0 then
    notify("Selected item is not a file", vim.log.levels.WARN)
    return
  end

  local main = picker.main
  local current = real_file_from_win(main)
  if not current then
    notify("Current buffer has no file", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_current_win(main)
  M.diff_files(selected[1].file, current)
end

function M.quit()
  local r = M._review
  local rightwin = r and r.right_win
  local restore = M._restore_buf
  close_diff()
  -- Don't strand a read-only scratch blob (range reviews leave the B-blob in the
  -- window): return it to the pre-review buffer, or a fresh empty one. Worktree
  -- reviews end on the real file (buftype ""), so those are left as-is.
  if rightwin and vim.api.nvim_win_is_valid(rightwin) then
    local rb = vim.api.nvim_win_get_buf(rightwin)
    if vim.bo[rb].buftype ~= "" then
      if
        restore
        and vim.api.nvim_buf_is_valid(restore)
        and vim.bo[restore].buftype == ""
        and vim.fn.buflisted(restore) == 1
      then
        vim.api.nvim_win_set_buf(rightwin, restore)
      else
        vim.api.nvim_win_call(rightwin, function()
          vim.cmd("enew")
        end)
      end
    end
  end
  M._restore_buf = nil
end

--- Open the next/prev *unreviewed* changed file. Returns true if it opened one,
--- false if none remain unreviewed.
local function nav(dir)
  local s = M.get_session()
  if not s then
    return false
  end
  local files = M.changed_files(s)
  if #files == 0 then
    return false
  end
  local cur = (M._review and M._review.abs) or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local idx = 0
  for i, f in ipairs(files) do
    if f.abs == cur then
      idx = i
      break
    end
  end
  local n = #files
  for step = 1, n do
    local j = ((idx - 1 + dir * step) % n) + 1
    if not M.is_reviewed(files[j].abs) then
      M.open_file(files[j].rel)
      return true
    end
  end
  return false
end

--- Everything reviewed: tear down the diff and open the report (the review page).
local function finish_review()
  M.quit()
  M.report()
  notify("Review complete 🎉")
end

function M.next_unreviewed()
  if not nav(1) then
    finish_review()
  end
end

function M.prev_unreviewed()
  if not nav(-1) then
    notify("No unreviewed files")
  end
end

-- ---------------------------------------------------------------------------
-- snacks picker of changed (unreviewed) files
-- ---------------------------------------------------------------------------

function M.pick_files()
  local s = M.get_session()
  if not s then
    return
  end
  local Snacks = require("snacks")
  Snacks.picker.pick({
    source = "edit_review_files",
    title = "Edit Review — changed files",
    format = "file",
    -- Preview the file's DIFF, not the file itself: a committed-range review's
    -- files may not exist in the working tree (added/deleted/other checkout),
    -- which made the default file previewer error "file not found".
    preview = function(ctx)
      local rev = s.kind == "range" and s.revspec or "HEAD"
      local out = vim.fn.systemlist({ "git", "-C", s.root, "diff", "--no-color", rev, "--", ctx.item.rel })
      if vim.v.shell_error ~= 0 or #out == 0 then
        out = { "(no textual diff for " .. ctx.item.rel .. ")" }
      end
      ctx.preview:set_lines(out)
      ctx.preview:highlight({ ft = "diff" })
      ctx.preview:set_title(ctx.item.rel)
      return true
    end,
    finder = function()
      local out = {}
      for _, f in ipairs(M.changed_files(s)) do
        if not M.is_reviewed(f.abs) then
          out[#out + 1] = { text = f.rel, file = f.abs, rel = f.rel, cwd = s.root }
        end
      end
      return out
    end,
    actions = {
      confirm = function(picker, item)
        picker:close()
        if item then
          vim.schedule(function()
            M.open_file(item.rel)
          end)
        end
      end,
      er_mark_reviewed = function(picker, item)
        if item then
          M.toggle_reviewed(item.file)
          picker:find()
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<a-v>"] = { "er_mark_reviewed", mode = { "i", "n" }, desc = "mark reviewed" },
        },
      },
    },
  })
end

-- ---------------------------------------------------------------------------
-- comments + report
-- ---------------------------------------------------------------------------

local function find_hunk(hunks, line)
  for _, h in ipairs(hunks or {}) do
    local a = h.added or {}
    local s = a.start or 0
    local c = a.count or 0
    local e = c > 0 and (s + c - 1) or s
    if line >= s and line <= e then
      return h
    end
  end
end

--- Parse `git diff <revspec> -- <rel>` into gitsigns-shaped hunks. Used for
--- committed-range reviews, where gitsigns can't attach to the diff buffers.
--- `-U0` keeps each hunk's added.start/count tight to the changed lines, so the
--- "hunk under cursor" test matches gitsigns' behaviour.
function M.git_hunks(root, revspec, rel)
  local lines = vim.fn.systemlist({
    "git", "-C", root, "diff", "--no-color", "-U0", revspec, "--", rel,
  })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local hunks, cur = {}, nil
  for _, l in ipairs(lines) do
    local oa, oc, na, nc = l:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if oa then
      cur = {
        removed = { start = tonumber(oa), count = oc == "" and 1 or tonumber(oc), lines = {} },
        added = { start = tonumber(na), count = nc == "" and 1 or tonumber(nc), lines = {} },
      }
      hunks[#hunks + 1] = cur
    elseif cur then
      local c = l:sub(1, 1)
      if c == "+" then
        cur.added.lines[#cur.added.lines + 1] = l:sub(2)
      elseif c == "-" then
        cur.removed.lines[#cur.removed.lines + 1] = l:sub(2)
      end
    end
  end
  return hunks
end

--- Resolve what the cursor is pointing at. Returns { win, buf, line, ft, abs,
--- rel } or nil. Inside a review diff we anchor to the RIGHT (new) side, so the
--- cursor line is a B-side line that matches the hunk's added range.
local function current_target(s)
  if M._review and M._review.rel then
    local r = M._review
    local cur = vim.api.nvim_get_current_win()
    if r.left_win and cur == r.left_win then
      notify("Comment from the new (right) side of the diff", vim.log.levels.WARN)
      return nil
    end
    local win = (r.right_win and vim.api.nvim_win_is_valid(r.right_win)) and r.right_win or cur
    return {
      win = win,
      buf = r.right_buf,
      line = vim.api.nvim_win_get_cursor(win)[1],
      ft = vim.bo[r.right_buf].filetype,
      abs = r.abs,
      rel = r.rel,
    }
  end

  -- fallback: a normal file buffer (review wasn't opened through us)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(name, ":p")
  return {
    win = win,
    buf = buf,
    line = vim.api.nvim_win_get_cursor(win)[1],
    ft = vim.bo[buf].filetype,
    abs = abs,
    rel = relpath(s.root, abs),
  }
end

local function build_section(anchor, rel, hunk, ft)
  local before = (hunk.removed and hunk.removed.lines) or {}
  local changed = (hunk.added and hunk.added.lines) or {}
  local s = (hunk.added and hunk.added.start) or 0
  local c = (hunk.added and hunk.added.count) or 0
  local e = c > 0 and (s + c - 1) or s
  local bf, cf = fence(before), fence(changed)

  local out = {
    "<!-- id: " .. anchor .. " -->",
    string.format("### `%s` · L%d-%d", rel, s, e),
    "",
    "**BEFORE**",
    bf .. ft,
  }
  vim.list_extend(out, before)
  vim.list_extend(out, { bf, "", "**CHANGED**", cf .. ft })
  vim.list_extend(out, changed)
  vim.list_extend(out, { cf, "", "**COMMENT**", "", "", "---", "" })
  return out
end

--- Comment on the diff hunk under the cursor. Opens the review's report.md;
--- creates a templated section for this hunk if none exists yet, else jumps to
--- the existing comment. Identity = absolute path + hunk start line.
function M.comment()
  local s = M.get_session()
  if not s then
    return
  end

  local tgt = current_target(s)
  if not tgt then
    notify("Couldn't resolve the file under the cursor", vim.log.levels.WARN)
    return
  end

  local hunk = find_hunk(hunks_for(s, tgt.rel, tgt.buf), tgt.line)
  if not hunk then
    notify("No diff hunk under the cursor", vim.log.levels.WARN)
    return
  end

  local anchor = tgt.abs .. ":" .. ((hunk.added and hunk.added.start) or tgt.line)
  M._return = { win = tgt.win, line = tgt.line }

  -- open the report file in a right-hand split
  vim.cmd("botright vsplit " .. vim.fn.fnameescape(s.dir .. "/report.md"))
  M._report_win = vim.api.nvim_get_current_win()
  local rbuf = vim.api.nvim_get_current_buf()

  local marker = "<!-- id: " .. anchor .. " -->"
  local rlines = vim.api.nvim_buf_get_lines(rbuf, 0, -1, false)
  local found
  for i, l in ipairs(rlines) do
    if l == marker then
      found = i
      break
    end
  end
  if not found then
    vim.api.nvim_buf_set_lines(rbuf, -1, -1, false, build_section(anchor, tgt.rel, hunk, tgt.ft))
    rlines = vim.api.nvim_buf_get_lines(rbuf, 0, -1, false)
    for i, l in ipairs(rlines) do
      if l == marker then
        found = i
        break
      end
    end
  end

  -- drop the cursor on the line under **COMMENT**
  local target = found or 1
  for i = found or 1, #rlines do
    if rlines[i] == "**COMMENT**" then
      target = i + 1
      break
    end
  end
  target = math.min(target, vim.api.nvim_buf_line_count(rbuf))
  vim.api.nvim_win_set_cursor(M._report_win, { target, 0 })
  vim.cmd("startinsert")
end

--- Finish commenting: save the report, close its split, and return to the code
--- line — using a `G` jump so the move lands in the jumplist (`<C-o>` works).
function M.finish_comment()
  if M._report_win and vim.api.nvim_win_is_valid(M._report_win) then
    vim.api.nvim_win_call(M._report_win, function()
      if vim.bo.modified then
        vim.cmd("silent write")
      end
    end)
    if not (M._return and M._report_win == M._return.win) then
      pcall(vim.api.nvim_win_close, M._report_win, false)
    end
  end
  M._report_win = nil

  local ret = M._return
  if ret and vim.api.nvim_win_is_valid(ret.win) then
    vim.api.nvim_set_current_win(ret.win)
    vim.cmd("stopinsert")
    pcall(vim.cmd, "normal! " .. ret.line .. "G")
  end
  M._return = nil
  notify("Comment saved")
end

function M.report()
  local s = M.get_session()
  if not s then
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(s.dir .. "/report.md"))
end

-- ---------------------------------------------------------------------------
-- per-hunk review (resolve individual hunks; ✓ gutter sign; auto-complete file)
-- ---------------------------------------------------------------------------

--- (Re)place the ✓ gutter signs for the current file's reviewed hunks, on the
--- changed lines of both panes.
function M._refresh_hunk_signs(s)
  local r = M._review
  if not r then
    return
  end
  for _, b in ipairs({ r.left_buf, r.right_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_clear_namespace(b, SIGN_NS, 0, -1)
    end
  end
  local fh = (s.meta.reviewed_hunks or {})[r.abs]
  if not fh or next(fh) == nil then
    return
  end
  local function sign(buf, l0, l1)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    local last = vim.api.nvim_buf_line_count(buf)
    for ln = math.max(l0, 1), math.min(l1, last) do
      pcall(vim.api.nvim_buf_set_extmark, buf, SIGN_NS, ln - 1, 0, {
        sign_text = "✓",
        sign_hl_group = "EditReviewHunkSign",
        priority = 100, -- above gitsigns' own +/- signs on the worktree file
      })
    end
  end
  for _, h in ipairs(hunks_for(s, r.rel, r.right_buf)) do
    if fh[hunk_id(h)] then
      local a, rm = h.added or {}, h.removed or {}
      if (a.count or 0) > 0 then
        sign(r.right_buf, a.start, a.start + a.count - 1)
      end
      if (rm.count or 0) > 0 then
        sign(r.left_buf, rm.start, rm.start + rm.count - 1)
      end
    end
  end
end

function M.is_hunk_reviewed(abs, h)
  local s = M._session or M.get_session()
  if not s then
    return false
  end
  local fh = (s.meta.reviewed_hunks or {})[abs]
  return fh ~= nil and fh[hunk_id(h)] ~= nil
end

--- Move the cursor to the next still-unreviewed hunk in the current file (the
--- nearest one after `after_line`, wrapping to the first if needed), centered.
--- Returns false when no unreviewed hunks remain in the file.
local function goto_next_unreviewed_hunk(s, after_line)
  local r = M._review
  if not r then
    return false
  end
  local fh = (s.meta.reviewed_hunks or {})[r.abs] or {}
  local unrev = {}
  for _, h in ipairs(hunks_for(s, r.rel, r.right_buf)) do
    if not fh[hunk_id(h)] then
      unrev[#unrev + 1] = h
    end
  end
  if #unrev == 0 then
    return false
  end
  table.sort(unrev, function(a, b)
    return ((a.added and a.added.start) or 0) < ((b.added and b.added.start) or 0)
  end)
  local target
  for _, h in ipairs(unrev) do
    if ((h.added and h.added.start) or 0) > after_line then
      target = h
      break
    end
  end
  target = target or unrev[1] -- wrap to the first remaining one
  local line = math.max((target.added and target.added.start) or 1, 1)
  if r.right_win and vim.api.nvim_win_is_valid(r.right_win) then
    vim.api.nvim_set_current_win(r.right_win)
    pcall(vim.api.nvim_win_set_cursor, r.right_win, { line, 0 })
    vim.cmd.normal({ "zz", bang = true })
  end
  return true
end

--- `<leader>rh`: toggle the hunk under the cursor reviewed/unreviewed. After
--- marking one reviewed, jump to the next unreviewed hunk; when the file's last
--- hunk is resolved the file auto-completes and we advance to the next file (or
--- finish + open the report). Unmarking just updates in place.
function M.toggle_hunk_reviewed()
  local s = M.get_session()
  if not s then
    return
  end
  local tgt = current_target(s)
  if not tgt then
    notify("Couldn't resolve the file under the cursor", vim.log.levels.WARN)
    return
  end
  local hunks = hunks_for(s, tgt.rel, tgt.buf)
  local hunk = find_hunk(hunks, tgt.line)
  if not hunk then
    notify("No diff hunk under the cursor", vim.log.levels.WARN)
    return
  end

  s.meta.reviewed_hunks = s.meta.reviewed_hunks or {}
  local fh = s.meta.reviewed_hunks[tgt.abs] or {}
  local id = hunk_id(hunk)
  local now_reviewed = fh[id] == nil
  fh[id] = now_reviewed and { at = os.date("%Y-%m-%dT%H:%M:%S") } or nil
  s.meta.reviewed_hunks[tgt.abs] = (next(fh) ~= nil) and fh or nil

  -- auto-complete: the file is reviewed iff every one of its hunks is
  local all = #hunks > 0
  for _, h in ipairs(hunks) do
    if not fh[hunk_id(h)] then
      all = false
      break
    end
  end
  s.meta.reviewed[tgt.abs] = all and { hash = file_hash(tgt.abs), at = os.date("%Y-%m-%dT%H:%M:%S") } or nil

  save_meta(s)
  M._refresh_hunk_signs(s)
  notify(
    (now_reviewed and "Hunk reviewed" or "Hunk unmarked") .. (all and "  ·  file complete ✓" or "")
  )

  -- Advance only when we just resolved a hunk (not when unmarking one).
  if now_reviewed and not goto_next_unreviewed_hunk(s, tgt.line) then
    M.next_unreviewed() -- file done -> next unreviewed file, or finish + report
  end
end

-- ---------------------------------------------------------------------------
-- difftastic (optional, read-only structural view in a terminal split)
-- ---------------------------------------------------------------------------

function M.difftastic()
  if vim.fn.executable("difft") == 0 then
    notify("difftastic (`difft`) is not installed", vim.log.levels.WARN)
    return
  end
  local s = M.get_session()
  if not s then
    return
  end
  local tgt = current_target(s)
  if not tgt then
    notify("Couldn't resolve the file under the cursor", vim.log.levels.WARN)
    return
  end
  local cmd = string.format(
    "GIT_EXTERNAL_DIFF=difft git -C %s diff %s -- %s",
    vim.fn.shellescape(s.root),
    s.revspec,
    vim.fn.shellescape(tgt.rel)
  )
  vim.cmd("botright new")
  vim.fn.termopen(cmd)
  vim.cmd("startinsert")
end

-- ---------------------------------------------------------------------------

-- Kept for back-compat; nothing to do (seeding happens at module load).
function M.setup(_) end

return M
