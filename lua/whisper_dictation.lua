-- whisper_dictation: local, phrase-on-pause speech-to-text for Neovim.
--
-- Pipeline:  parecord (WSLg mic) --raw--> sox `silence` segmenter, which writes
-- one finalized WAV per spoken phrase (phrase_001.wav, phrase_002.wav, …) each
-- time it detects a pause. A poll timer notices completed files, a single-in-
-- flight FIFO worker runs `whisper-cli` (with a vocab `--prompt`) on each, and
-- the result is inserted at a tracked extmark so dictation survives cursor moves.
--
-- Everything is local: the only network access is a one-time model download.
-- The engine (`whisper-cli`/`parecord`/`sox`) is provided by the parent .config
-- repo's home.nix (Nix-managed toolchain). See lua/config/keymaps.lua for the
-- <leader>v* keymaps and lua/plugins/whisper-dictation.lua for the which-key
-- group + lualine indicator.

local M = {}

-- Editable defaults. `vocab` is the global term list; per-project terms live in
-- <project root>/dev/PROJECT_VOCAB.txt (read fresh at each open()).
M.opts = {
  model = vim.fn.stdpath("data") .. "/whisper/models/ggml-base.en.bin",
  server_bin = "whisper-server", -- resident model; loaded once, reused per phrase
  server_host = "127.0.0.1",
  server_port = 18176,
  language = "en",
  threads = 8,
  pause_ms = 1500, -- trailing silence (ms) that ends a phrase (longer = fewer mid-sentence splits)
  gain_db = 12, -- input gain boost (dB) before VAD; raise for a quiet mic, 0 to disable
  silence_pct = "3%", -- sox silence threshold (room noise floor)
  min_bytes = 6000, -- ignore phrase files smaller than this (~0.2s; noise/empty)
  poll_ms = 250, -- how often to scan for finished phrase files
  max_seconds = 300, -- safety auto-stop for a forgotten recording
  notify = true,
  vocab = { "Naondo", "Neovim", "nvim", "LazyVim", "Nix", "WSLg", "PulseAudio" },
  project_vocab_file = "dev/PROJECT_VOCAB.txt",
}

-- ---------------------------------------------------------------------------
-- state (single active session at a time)
-- ---------------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("whisper_dictation")
local S = nil -- nil when idle; a table while a session is active

-- A single reused notification id so lifecycle messages (Starting → Recording →
-- Transcribing → Done) replace in place rather than stacking. snacks.notifier /
-- nvim-notify honor `id`; plain :notify ignores it harmlessly.
local NID = "whisper_dictation"

-- sticky=true keeps the toast up until replaced/dismissed (snacks/nvim-notify
-- honor `timeout=false`); used for the persistent "Recording" status.
local function notify(msg, level, sticky)
  if M.opts.notify or level == vim.log.levels.ERROR then
    local opts = { title = "Dictation", id = NID }
    if sticky then
      opts.timeout = false -- keep up until replaced (can't use `and/or`: false is falsy)
    end
    vim.notify(msg, level or vim.log.levels.INFO, opts)
  end
end

-- Animated status: cycles a trailing-dot spinner under the lifecycle id until
-- stopped. Used while the model server warms up.
local spin = { timer = nil }
local function spin_stop()
  if spin.timer then
    pcall(vim.fn.timer_stop, spin.timer)
    spin.timer = nil
  end
end
local function spin_start(base)
  spin_stop()
  local n = 0
  notify(base, nil, true)
  spin.timer = vim.fn.timer_start(160, function()
    n = (n + 1) % 4
    notify(base .. string.rep(".", n), nil, true)
  end, { ["repeat"] = -1 })
end

-- ---------------------------------------------------------------------------
-- model auto-install (portable: derives name + dir from the model path)
-- ---------------------------------------------------------------------------
local function ensure_model()
  if vim.uv.fs_stat(M.opts.model) then
    return true
  end
  local dir = vim.fn.fnamemodify(M.opts.model, ":h")
  local name = vim.fn.fnamemodify(M.opts.model, ":t"):gsub("^ggml%-", ""):gsub("%.bin$", "")
  vim.fn.mkdir(dir, "p")
  notify("Downloading whisper model '" .. name .. "' (one-time)…")
  vim.fn.system({ "whisper-cpp-download-ggml-model", name, dir })
  if vim.v.shell_error ~= 0 or not vim.uv.fs_stat(M.opts.model) then
    notify("Model download failed for '" .. name .. "'", vim.log.levels.ERROR)
    return false
  end
  notify("Model '" .. name .. "' ready")
  return true
end

-- ---------------------------------------------------------------------------
-- whisper-server: load the model ONCE and keep it resident for the whole nvim
-- session, so each phrase is just an HTTP inference call (no per-phrase reload).
-- ---------------------------------------------------------------------------
local SRV = { job = nil, ready = false } -- module-level (survives across sessions)

local function server_url()
  return string.format("http://%s:%d/inference", M.opts.server_host, M.opts.server_port)
end

-- Launch the server process. We drain its stdout/stderr (so its pipe buffer
-- can't fill and stall the server over a long session) but do NOT rely on a log
-- marker for readiness — whisper-server block-buffers stdout when piped, so the
-- "listening" line may never flush. Readiness is detected by probing the port.
local function start_server_process()
  SRV.ready = false
  local function drain() end -- consume output; discard
  SRV.job = vim.fn.jobstart({
    M.opts.server_bin,
    "-m", M.opts.model,
    "--host", M.opts.server_host,
    "--port", tostring(M.opts.server_port),
    "-t", tostring(M.opts.threads),
    "-nt",
    "-l", M.opts.language,
  }, {
    on_stdout = drain,
    on_stderr = drain,
    on_exit = function()
      SRV.job = nil
      SRV.ready = false
    end,
  })
  return SRV.job and SRV.job > 0
end

-- Non-blocking readiness probe: the listening socket only accepts connections
-- once the model has finished loading, so a successful TCP connect == ready.
local function probe_ready(cb)
  local tcp = vim.uv.new_tcp()
  local settled = false
  local function done(ok)
    if settled then
      return
    end
    settled = true
    pcall(function()
      tcp:close()
    end)
    -- connect callback runs in a libuv fast context; hop to the main loop before
    -- touching any editor API (E5560 otherwise).
    vim.schedule(function()
      cb(ok)
    end)
  end
  tcp:connect(M.opts.server_host, M.opts.server_port, function(err)
    done(err == nil)
  end)
end

-- Ensure the server is up and ready, then call cb(ok). Non-blocking: only the
-- first dictation of a session waits for the model load.
local function ensure_server(cb)
  if SRV.job and SRV.ready then
    cb(true)
    return
  end
  if not SRV.job and not start_server_process() then
    SRV.job = nil
    cb(false)
    return
  end
  local waited, fired, t = 0, false, nil
  local function finish(ok)
    if fired then
      return
    end
    fired = true
    pcall(vim.fn.timer_stop, t)
    cb(ok)
  end
  t = vim.fn.timer_start(250, function()
    if not SRV.job then
      return finish(false)
    end
    waited = waited + 250
    if waited > 30000 then
      return finish(false)
    end
    probe_ready(function(ok)
      if ok and SRV.job then
        SRV.ready = true
        finish(true)
      end
    end)
  end, { ["repeat"] = -1 })
end

function M.stop_server()
  if SRV.job then
    pcall(vim.fn.jobstop, SRV.job)
    SRV.job = nil
  end
end

-- Tear the resident server down when nvim exits.
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.stop_server()
  end,
})

-- ---------------------------------------------------------------------------
-- vocab -> --prompt string (global list + per-project file)
-- ---------------------------------------------------------------------------
local function project_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
    return out[1]
  end
  return vim.fn.getcwd()
end

local function resolve_prompt()
  local terms, seen = {}, {}
  local function add(t)
    t = vim.trim(t)
    if t ~= "" and not seen[t:lower()] then
      seen[t:lower()] = true
      terms[#terms + 1] = t
    end
  end
  for _, t in ipairs(M.opts.vocab) do
    add(t)
  end
  local pf = project_root() .. "/" .. M.opts.project_vocab_file
  if vim.fn.filereadable(pf) == 1 then
    for _, line in ipairs(vim.fn.readfile(pf)) do
      if not line:match("^%s*#") then
        add(line)
      end
    end
  end
  if #terms == 0 then
    return ""
  end
  if #terms > 150 then -- keep under the model's prompt token budget
    terms = vim.list_slice(terms, 1, 150)
  end
  return table.concat(terms, ", ")
end

-- ---------------------------------------------------------------------------
-- phrase file discovery (numeric sort; size-stability completion)
-- ---------------------------------------------------------------------------
local function phrase_files()
  local files = vim.fn.glob(S.dir .. "/phrase_*.wav", false, true)
  table.sort(files, function(a, b)
    return (tonumber(a:match("(%d+)%.wav$")) or 0) < (tonumber(b:match("(%d+)%.wav$")) or 0)
  end)
  return files
end

-- True while a real (>= min_bytes) phrase file is still being written / not yet
-- enqueued. Used to know when draining is truly finished.
local function pending_real()
  for _, f in ipairs(phrase_files()) do
    if not S.seen[f] then
      local st = vim.uv.fs_stat(f)
      if st and st.size >= M.opts.min_bytes then
        return true
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- text insertion at the extmark
-- ---------------------------------------------------------------------------
local function insert_text(text)
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then
    notify("Target buffer gone — transcribed: " .. text, vim.log.levels.WARN)
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(S.buf, ns, S.mark, {})
  if not pos[1] then
    return
  end
  local row, col = pos[1], pos[2]
  local chunk = (S.chars > 0 and " " or "") .. text
  local lines = vim.split(chunk, "\n", { plain = true })
  vim.api.nvim_buf_set_text(S.buf, row, col, row, col, lines)
  S.chars = S.chars + #chunk
  S.phrases = S.phrases + 1
  -- Keep the sticky status alive with a live count (but not once we're draining,
  -- where "Transcribing…" should stay until "Done").
  if not S.draining then
    notify(
      string.format("Recording — %d phrase%s · <leader>vc to stop", S.phrases, S.phrases == 1 and "" or "s"),
      nil,
      true
    )
  end
  -- Follow the inserted text with the cursor only if the user is in that buffer.
  if vim.api.nvim_get_current_buf() == S.buf then
    local np = vim.api.nvim_buf_get_extmark_by_id(S.buf, ns, S.mark, {})
    pcall(vim.api.nvim_win_set_cursor, 0, { np[1] + 1, np[2] })
  end
end

-- ---------------------------------------------------------------------------
-- sequential transcription worker
-- ---------------------------------------------------------------------------
local function cleanup_session()
  if not S then
    return
  end
  if S.job then
    pcall(vim.fn.jobstop, S.job) -- stop the parecord|sox pipeline
  end
  if S.cur_job then
    pcall(vim.fn.jobstop, S.cur_job) -- stop any in-flight curl
  end
  if S.poll then
    pcall(vim.fn.timer_stop, S.poll)
  end
  if S.safety then
    pcall(vim.fn.timer_stop, S.safety)
  end
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    pcall(vim.api.nvim_buf_del_extmark, S.buf, ns, S.mark)
  end
  if S.dir then
    vim.fn.delete(S.dir, "rf")
  end
end

local function finish()
  local n, c = S.phrases, S.chars
  cleanup_session()
  S = nil
  notify(string.format("Done — %d phrase%s, %d chars", n, n == 1 and "" or "s", c))
end

local pump -- forward decl

local function transcribe_one(wav)
  S.working = true
  local out = {}
  S.cur_job = vim.fn.jobstart({
    "curl", "-s", "-S",
    server_url(),
    "-F", "file=@" .. wav,
    "-F", "response_format=text",
    "-F", "temperature=0",
    "-F", "prompt=" .. S.prompt,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        out[#out + 1] = table.concat(data, "\n")
      end
    end,
    on_exit = function()
      if not S then -- aborted mid-flight
        return
      end
      if not S.cancelled then
        local raw = table.concat(out, "")
        -- strip whisper's non-speech markers and squeeze whitespace
        raw = raw:gsub("%[[^%]]*%]", ""):gsub("%([^%)]*%)", "")
        local text = vim.trim(raw:gsub("%s+", " "))
        if text ~= "" then
          insert_text(text)
        end
      end
      vim.fn.delete(wav)
      S.working = false
      S.cur_job = nil
      pump()
    end,
  })
end

pump = function()
  if not S or S.working then
    return
  end
  local wav = table.remove(S.queue, 1)
  if wav then
    transcribe_one(wav)
  elseif S.draining and not pending_real() then
    finish()
  end
end

-- A phrase file is COMPLETE only once sox has opened the *next* one (so it's
-- finalized), or — while draining — once the pipeline has stopped. We never read
-- the highest-numbered file mid-recording, which avoids grabbing a partial phrase
-- (sox flushes in chunks, so file size is not a reliable "done" signal).
local function poll()
  if not S then
    return
  end
  local files = phrase_files()
  local upto = S.draining and #files or (#files - 1)
  for i = 1, upto do
    local f = files[i]
    if not S.seen[f] then
      S.seen[f] = true
      local st = vim.uv.fs_stat(f)
      if st and st.size >= M.opts.min_bytes then
        S.queue[#S.queue + 1] = f -- real phrase; tiny/noise files are skipped
      end
    end
  end
  pump()
end

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------
local STARTING = false -- true while the server is warming up for a pending open()

-- Begin the actual capture pipeline (server is confirmed ready by here).
local function start_capture()
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, cur[1] - 1, cur[2], { right_gravity = true })
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  S = {
    buf = buf,
    mark = mark,
    dir = dir,
    prompt = resolve_prompt(),
    queue = {},
    seen = {},
    working = false,
    cur_job = nil,
    draining = false,
    cancelled = false,
    phrases = 0,
    chars = 0,
    start_time = os.time(),
  }

  local pause_s = string.format("%.3f", M.opts.pause_ms / 1000)
  local gain = M.opts.gain_db ~= 0 and string.format("gain -l %d ", M.opts.gain_db) or ""
  local pipe = string.format(
    "parecord --raw --channels=1 --rate=16000 --format=s16le "
      .. "| sox -t raw -r 16000 -e signed -b 16 -c 1 - %s/phrase_.wav "
      .. "%ssilence 1 0.1 %s 1 %s %s : newfile : restart",
    vim.fn.shellescape(dir),
    gain,
    M.opts.silence_pct,
    pause_s,
    M.opts.silence_pct
  )
  S.job = vim.fn.jobstart({ "sh", "-c", pipe }, {
    on_exit = function()
      if S then
        S.draining = true -- pipeline ended; flush remaining files then finish()
      end
    end,
  })
  if not S.job or S.job <= 0 then
    notify("Failed to start recording pipeline", vim.log.levels.ERROR)
    cleanup_session()
    S = nil
    return
  end

  S.poll = vim.fn.timer_start(M.opts.poll_ms, poll, { ["repeat"] = -1 })
  S.safety = vim.fn.timer_start(M.opts.max_seconds * 1000, function()
    if S and not S.draining then
      notify("Max recording length reached — stopping", vim.log.levels.WARN)
      M.close()
    end
  end)
  notify("Recording — pause between phrases; <leader>vc to stop, <leader>va to abort", nil, true)
end

function M.open()
  if S then
    notify("Already recording (use <leader>vc to stop)", vim.log.levels.WARN)
    return
  end
  if STARTING then
    notify("Server is still starting…", vim.log.levels.WARN)
    return
  end
  for _, bin in ipairs({ M.opts.server_bin, "parecord", "sox", "curl" }) do
    if vim.fn.executable(bin) == 0 then
      notify("Missing required binary: " .. bin, vim.log.levels.ERROR)
      return
    end
  end
  if not ensure_model() then
    return
  end
  local function begin()
    local ok, err = pcall(start_capture)
    if not ok then
      notify("Failed to start recording: " .. tostring(err), vim.log.levels.ERROR)
      cleanup_session() -- tear down any half-started pipeline/timers
      S = nil
    end
  end

  if SRV.job and SRV.ready then
    begin() -- warm server: record immediately
    return
  end
  STARTING = true
  spin_start("Starting whisper server")
  ensure_server(function(ok)
    STARTING = false
    spin_stop()
    if not ok then
      notify("whisper-server failed to start", vim.log.levels.ERROR)
      return
    end
    begin()
  end)
end

function M.close()
  if not S then
    notify("Not recording", vim.log.levels.WARN)
    return
  end
  if S.draining then
    return -- already stopping
  end
  if S.job then
    pcall(vim.fn.jobstop, S.job) -- parecord dies -> sox finalizes last file -> on_exit
  end
  if S.safety then
    pcall(vim.fn.timer_stop, S.safety)
    S.safety = nil
  end
  notify("Transcribing…", nil, true)
  -- on_exit sets draining; poll/pump drain the queue and call finish().
end

function M.abort()
  if not S then
    return
  end
  S.cancelled = true
  if S.job then
    pcall(vim.fn.jobstop, S.job)
  end
  if S.cur_job then
    pcall(vim.fn.jobstop, S.cur_job)
  end
  cleanup_session()
  S = nil
  notify("Cancelled")
end

-- lualine component: "● REC m:ss" while recording, "" otherwise.
function M.status()
  if not S then
    return ""
  end
  local e = os.time() - S.start_time
  return string.format("● REC %d:%02d", math.floor(e / 60), e % 60)
end

function M.is_active()
  return S ~= nil
end

-- :WhisperHealth — quick dependency + model report.
function M.health()
  local lines = { "whisper dictation health:" }
  for _, bin in ipairs({ M.opts.server_bin, "parecord", "sox", "curl", "whisper-cpp-download-ggml-model" }) do
    lines[#lines + 1] = string.format("  %s %s", vim.fn.executable(bin) == 1 and "✓" or "✗", bin)
  end
  lines[#lines + 1] = string.format(
    "  %s model: %s",
    vim.uv.fs_stat(M.opts.model) and "✓" or "✗ (will download on first use)",
    M.opts.model
  )
  lines[#lines + 1] = string.format(
    "  %s server: %s",
    (SRV.job and SRV.ready) and "✓ running" or "○ not started (starts on first use)",
    server_url()
  )
  notify(table.concat(lines, "\n"))
end

return M
