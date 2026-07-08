local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.Select: sidekick.cli.With
---@field cb fun(state?:sidekick.cli.State)
---@field auto? boolean Automatically select if only one tool matches the filter

local M = {}

---@param opts sidekick.cli.Select
function M.select(opts)
  assert(type(opts) == "table", "opts must be a table")
  local tools = require("sidekick.cli.state").get(opts.filter, { spawn = opts.spawn })

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

  ---@type snacks.picker.ui_select.Opts
  local select_opts = {
    prompt = "Select CLI tool:",
    kind = "sidekick_cli",
    ---@param tool sidekick.cli.State
    format_item = function(tool)
      local parts = M.format(tool)
      return table.concat(vim.tbl_map(function(p)
        return p[1]
      end, parts))
    end,
    snacks = {
      format = M.format,
      preview = M.preview,
      -- big horizontal layout: sessions on the left, live scrollback preview
      -- on the right (see `M.preview`)
      layout = {
        hidden = {},
        layout = {
          width = 0.9,
          height = 0.9,
          box = "horizontal",
          {
            box = "vertical",
            border = true,
            title = "{title} {live} {flags}",
            title_pos = "center",
            { win = "input", height = 1, border = "bottom" },
            { win = "list", border = "none" },
          },
          { win = "preview", title = "{preview}", border = true, width = 0.6 },
        },
      },
    },
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
  local sw = vim.api.nvim_strwidth
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
  -- append the instance ordinal (e.g. "pi #2") so multiple instances of the
  -- same tool in the same dir can be told apart in the list
  local name = state.tool.name
  if state.session and state.session.iid then
    name = name .. " #" .. state.session.iid
  end
  ret[#ret + 1] = { name }
  local len = sw(name) + 2
  if state.session then
    ret[#ret + 1] = { string.rep(" ", math.max(0, 12 - len)) }

    if state.external then
      ret[#ret + 1] = { Config.ui.icons["external_" .. status], status_hl }
    else
      ret[#ret + 1] = { Config.ui.icons["terminal_" .. status], status_hl }
    end
    len = len + 2

    -- Keep this for debugging purposes
    -- ret[#ret + 1] = { table.concat(state.session.pids or {}, ",") }

    local backends = {} ---@type string[]
    backends[#backends + 1] = state.session.mux_backend or state.session.backend
    if state.external then
      backends[#backends + 1] = state.session.mux_session
    end
    local backend = ("[%s]"):format(table.concat(backends, ":"))

    ret[#ret + 1] = { backend, "Special" }
    len = 12 + sw(backend)
    ret[#ret + 1] = { string.rep(" ", 40 - len) }
    if picker then
      local item = setmetatable({}, state) --[[@as snacks.picker.Item]]
      item.file = state.session.cwd
      item.dir = true
      vim.list_extend(ret, require("snacks").picker.format.filename(item, picker))
    else
      ret[#ret + 1] = { vim.fn.fnamemodify(state.session.cwd, ":p:~"), "Directory" }
    end
  end
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

return M
