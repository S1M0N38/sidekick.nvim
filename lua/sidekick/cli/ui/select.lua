local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.Select: sidekick.cli.With
---@field cb fun(state?:sidekick.cli.State)
---@field auto? boolean Automatically select if only one tool matches the filter

local M = {}

-- Column widths for the session picker list. The title column scales with the
-- picker's list window (see `title_width`) so the backend tag and cwd stay
-- aligned across rows regardless of title length. See `M.format`.
local NAME_W = 8 -- tool name + instance ordinal (e.g. "pi #2")
local TITLE_MIN = 24 -- never narrower than this, even in a tiny picker
local TITLE_FALLBACK = 40 -- used before the list window exists (filter text)

--- Width of the session-title column, scaled to the picker's list window so
--- titles stay readable regardless of picker size. Falls back to a sensible
--- default before the picker has opened (e.g. while building filter text).
---@param picker? snacks.Picker
---@return integer
local function title_width(picker)
  local win = picker and picker.list and picker.list.win and picker.list.win.win
  if win and vim.api.nvim_win_is_valid(win) then
    -- leave room for idx, status icon, NAME_W, backend tag and cwd path
    return math.max(TITLE_MIN, math.floor(vim.api.nvim_win_get_width(win) * 0.4))
  end
  return TITLE_FALLBACK
end

---@param opts sidekick.cli.Select
function M.select(opts)
  assert(type(opts) == "table", "opts must be a table")
  local tools = require("sidekick.cli.state").get(opts.filter)

  ---@param state? sidekick.cli.State
  local on_select = function(state)
    if state and not state.installed then
      M.on_missing(state.tool)
      state = nil
    end
    opts.cb(state)
  end

  if #tools == 0 then
    Util.warn("No tools match the given filter")
    return
  elseif #tools == 1 and opts.auto then
    on_select(tools[1])
    return
  end

  -- `kind="tool"` lists only tools (the "spawn new" rows); there is no
  -- scrollback to preview, so drop the preview window and relabel the picker.
  local tools_only = opts.filter and opts.filter.kind == "tool"
  local title = tools_only and "Select Tool:" or "Select Session:"

  -- vertical layout: input + list, with a live scrollback preview for sessions
  local layout = {
    layout = {
      width = 0.8,
      height = 0.9,
      box = "vertical",
      border = true,
      title = "{title} {live} {flags}",
      title_pos = "center",
      { win = "input", height = 1, border = "bottom" },
      { win = "list", border = "none" },
    },
  }
  if not tools_only then
    table.insert(layout.layout, { win = "preview", title = "{preview}", height = 0.6, border = "top" })
  end

  local snacks_opts = {
    format = M.format,
    win = {
      -- `<M-r>` renames the focused session (see `M.rename`). Bound in both
      -- modes so it fires from the picker's default insert mode too (a plain
      -- `r` would just type into the filter).
      -- Note: this overrides snacks' default `<M-r>` = toggle_regex.
      input = { keys = { ["<M-r>"] = { "rename", mode = { "n", "i" } } } },
      list = { keys = { ["<M-r>"] = { "rename", mode = { "n", "i" } } } },
    },
    actions = { rename = M.rename },
    layout = layout,
  }
  if not tools_only then
    snacks_opts.preview = M.preview
  end

  ---@type snacks.picker.ui_select.Opts
  local select_opts = {
    prompt = title,
    kind = "sidekick_cli",
    ---@param tool sidekick.cli.State
    format_item = function(tool)
      local parts = M.format(tool)
      return table.concat(vim.tbl_map(function(p)
        return p[1]
      end, parts))
    end,
    snacks = snacks_opts,
  }

  vim.ui.select(tools, select_opts, on_select)
end

---@param tool sidekick.cli.Tool
function M.on_missing(tool)
  Util.error(("Tool `%s` is not installed"):format(tool.name))
  if tool.url then
    local ok, err = vim.ui.open(tool.url)
    if ok then
      Util.info(("Opening %s in your browser..."):format(tool.url))
    else
      Util.error(("Failed to open %s: %s"):format(tool.url, err))
    end
  end
end

---@param state sidekick.cli.State|snacks.picker.Item
---@param picker? snacks.Picker
function M.format(state, picker)
  local ret = {} ---@type snacks.picker.Highlight[]

  local status = state.attached and "attached"
    or state.started and "started"
    or state.installed and "installed"
    or "missing"
  local status_hl = "SidekickCli" .. status:gsub("^%l", string.upper)

  if picker then
    local count = picker:count()
    local idx = tostring(state.idx)
    idx = (" "):rep(#tostring(count) - #idx) .. idx
    ret[#ret + 1] = { idx .. ".", "SnacksPickerIdx" }
    ret[#ret + 1] = { " " }
  end
  ret[#ret + 1] = { Config.ui.icons[status], status_hl }
  ret[#ret + 1] = { " " }

  -- tool name + instance ordinal (e.g. "pi #2")
  local name = state.tool.name
  if state.session and state.session.iid then
    name = name .. " #" .. state.session.iid
  end

  if not state.session then
    -- "spawn new" row (no running session): just the tool name
    ret[#ret + 1] = { name }
    return ret
  end

  -- title-prominent layout: a descriptive title (if set) leads in a column sized
  -- to the picker window so the backend tag and cwd stay aligned across rows; the
  -- tool name + ordinal is secondary. See `M.rename` for how titles are set.
  local title_w = title_width(picker)
  local title = state.session.get_title and state.session:get_title()
  if title and title ~= "" then
    ret[#ret + 1] = { Util.cell(title, title_w), "Title" }
    ret[#ret + 1] = { " " }
    ret[#ret + 1] = { Util.cell(name, NAME_W), "Comment" }
  else
    ret[#ret + 1] = { Util.cell(name, title_w) }
    ret[#ret + 1] = { " " }
    ret[#ret + 1] = { string.rep(" ", NAME_W) }
  end

  local backends = {} ---@type string[]
  backends[#backends + 1] = state.session.mux_backend or state.session.backend
  if state.external then
    backends[#backends + 1] = state.session.mux_session
  end
  ret[#ret + 1] = { ("[%s]"):format(table.concat(backends, ":")), "Special" }
  ret[#ret + 1] = { "  " }
  ret[#ret + 1] = { vim.fn.fnamemodify(state.session.cwd, ":~"), "Directory" }
  return ret
end

--- Live scrollback preview for the session picker.
--- Captures the selected session's terminal output (incl. ANSI colors) and
--- renders it in the preview window, mirroring `sidekick.cli.scrollback`.
---@param ctx snacks.picker.preview.ctx
function M.preview(ctx)
  local state = ctx.item.item or ctx.item
  local session = state.session
  local text ---@type string?
  if session and session.dump then
    text = session:dump()
  elseif state.terminal and state.terminal.buf and vim.api.nvim_buf_is_valid(state.terminal.buf) then
    -- embedded Neovim terminal: snapshot the visible lines
    text = table.concat(vim.api.nvim_buf_get_lines(state.terminal.buf, 0, -1, false), "\n")
  end
  if not text or vim.trim(text) == "" then
    ctx.preview:notify("No scrollback available", "warn", { item = false })
    return
  end
  ctx.preview:set_title((" %s "):format(state.tool.name))
  -- render the captured output (with escape sequences) in a terminal buffer
  local buf = ctx.preview:scratch()
  vim.api.nvim_chan_send(vim.api.nvim_open_term(buf, {}), text)
end

--- Rename the focused session via a command-line prompt (bound to `<M-r>` in
--- the picker). Uses `vim.fn.input` so the prompt reliably renders over the open
--- picker (a second floating window can be fought by the picker's focus hooks).
--- Titles are persisted by the session backend (tmux: `@sidekick-title`).
---@param picker snacks.Picker
---@param item? snacks.picker.Item
function M.rename(picker, item)
  local cur = item or picker:current()
  local state = cur and cur.item
  local s = state and state.session
  -- titles live on the underlying mux session. The picker may show a terminal
  -- wrapper (backend="terminal", priority 100) around the real tmux session,
  -- reachable via `.mux_session` / `.parent` — accept both shapes.
  local tmux = s and s.mux_session and (s.backend == "tmux" or s.mux_backend == "tmux")
  if not tmux then
    vim.notify(
      ("[sidekick] rename skipped: no tmux session (backend=%q mux_session=%s)"):format(
        tostring(s and s.backend),
        tostring(s and s.mux_session ~= nil)
      ),
      vim.log.levels.WARN
    )
    return
  end
  local ABORT = "\0" -- untypeable sentinel to detect <Esc>/<C-c>
  local title = vim.fn.input({
    prompt = "Session title: ",
    default = state.session:get_title() or "",
    cancelreturn = ABORT,
  })
  if title == ABORT then
    return -- aborted, keep the existing title
  end
  title = vim.trim(title)
  state.session:set_title(title == "" and nil or title)
  picker:refresh()
end

return M
