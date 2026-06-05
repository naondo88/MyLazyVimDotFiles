-- edit_review: an in-neovim AI-edit / code-review workflow.
-- See EDIT_VIEWER_SPEC.md for the design and decisions behind this module.
--
-- v1 scope: a single in-progress "staged" review per project, comparing the
-- working tree (baseB = WORKTREE) against HEAD (baseA). Reviews are keyed by a
-- per-session UUID under stdpath("state"), so generalizing to committed SHA
-- ranges / PR review later needs no migration.

local M = {}

local STATE_ROOT = vim.fn.stdpath("state") .. "/edit-review"

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

local function head_sha(root)
  local out = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--short", "HEAD" })
  if vim.v.shell_error ~= 0 then
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

-- ---------------------------------------------------------------------------
-- session
-- ---------------------------------------------------------------------------

local function save_meta(session)
  write_json(session.dir .. "/meta.json", session.meta)
end

--- Get (or lazily create) the current review session for the project.
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
  vim.fn.mkdir(base, "p")
  local pointer = base .. "/current"

  local dir
  if vim.fn.filereadable(pointer) == 1 then
    local p = vim.fn.readfile(pointer)[1]
    if p and vim.fn.isdirectory(p) == 1 then
      dir = p
    end
  end

  if not dir then
    dir = base .. "/staged-" .. uuid()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ dir }, pointer)
    local sha = head_sha(root) or "?"
    write_json(dir .. "/meta.json", {
      proj = proj,
      uuid = vim.fn.fnamemodify(dir, ":t"),
      created = os.date("%Y-%m-%dT%H:%M:%S"),
      baseA_ref = "HEAD",
      baseA_sha = sha,
      baseB = "WORKTREE",
      reviewed = vim.empty_dict(),
    })
    vim.fn.writefile({
      "# Review report — " .. proj,
      "",
      "_Base A: HEAD (" .. sha .. ")  ·  Base B: WORKTREE_",
      "",
    }, dir .. "/report.md")
  end

  local meta = read_json(dir .. "/meta.json") or {}
  meta.reviewed = meta.reviewed or {}
  M._session = { root = root, proj = proj, dir = dir, baseA = "HEAD", meta = meta }
  return M._session
end

--- Start a fresh review session (rotates the `current` pointer).
function M.new_session()
  local root = git_root()
  if not root then
    notify("Not in a git repository", vim.log.levels.WARN)
    return
  end
  M._session = nil
  local proj = vim.fn.fnamemodify(root, ":t")
  vim.fn.delete(STATE_ROOT .. "/" .. proj .. "/current")
  M.get_session()
  notify("Started a new review session")
end

-- ---------------------------------------------------------------------------
-- changed files + reviewed state
-- ---------------------------------------------------------------------------

--- List files changed in the working tree vs HEAD (tracked + untracked).
--- Returns a sorted list of { rel = <relpath>, abs = <abspath> }.
function M.changed_files(root)
  local seen, files = {}, {}
  local function add(rel)
    if rel and rel ~= "" and not seen[rel] then
      seen[rel] = true
      files[#files + 1] = { rel = rel, abs = root .. "/" .. rel }
    end
  end
  for _, rel in ipairs(vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only", "--diff-filter=ACMRD", "HEAD" })) do
    add(rel)
  end
  for _, rel in ipairs(vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })) do
    add(rel)
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
  local abs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  if abs == "" then
    return
  end
  M.toggle_reviewed(abs)
  notify((M.is_reviewed(abs) and "Marked reviewed: " or "Unmarked: ") .. vim.fn.fnamemodify(abs, ":t"))
end

-- ---------------------------------------------------------------------------
-- diff viewing (diffview.nvim) + navigation
-- ---------------------------------------------------------------------------

function M.open_review()
  local s = M.get_session()
  if not s then
    return
  end
  vim.cmd("DiffviewOpen " .. s.baseA)
end

function M.open_file(rel)
  local s = M.get_session()
  if not s then
    return
  end
  vim.cmd("DiffviewOpen " .. s.baseA .. " -- " .. vim.fn.fnameescape(rel))
end

function M.quit()
  pcall(vim.cmd, "DiffviewClose")
end

local function nav(dir)
  local s = M.get_session()
  if not s then
    return
  end
  local files = M.changed_files(s.root)
  if #files == 0 then
    notify("No changes in this review")
    return
  end
  local cur = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
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
      return
    end
  end
  notify("All files reviewed 🎉")
end

function M.next_unreviewed()
  nav(1)
end

function M.prev_unreviewed()
  nav(-1)
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
    finder = function()
      local out = {}
      for _, f in ipairs(M.changed_files(s.root)) do
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
          M.open_file(item.rel)
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
  local code_win = vim.api.nvim_get_current_win()
  local code_buf = vim.api.nvim_get_current_buf()
  local code_file = vim.api.nvim_buf_get_name(code_buf)
  if code_file == "" then
    notify("No file in the current buffer", vim.log.levels.WARN)
    return
  end

  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    notify("gitsigns is not available", vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(code_win)[1]
  local hunk = find_hunk(gs.get_hunks(code_buf), line)
  if not hunk then
    notify("No diff hunk under the cursor", vim.log.levels.WARN)
    return
  end

  local s = M.get_session()
  if not s then
    return
  end
  local abs = vim.fn.fnamemodify(code_file, ":p")
  local rel = relpath(s.root, abs)
  local ft = vim.bo[code_buf].filetype
  local anchor = abs .. ":" .. ((hunk.added and hunk.added.start) or line)
  M._return = { win = code_win, line = line }

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
    vim.api.nvim_buf_set_lines(rbuf, -1, -1, false, build_section(anchor, rel, hunk, ft))
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
  local abs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local rel = relpath(s.root, abs)
  local cmd = string.format(
    "GIT_EXTERNAL_DIFF=difft git -C %s diff %s -- %s",
    vim.fn.shellescape(s.root),
    s.baseA,
    vim.fn.shellescape(rel)
  )
  vim.cmd("botright new")
  vim.fn.termopen(cmd)
  vim.cmd("startinsert")
end

-- ---------------------------------------------------------------------------

function M.setup(_)
  math.randomseed(os.time())
end

return M
