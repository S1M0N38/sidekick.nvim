local M = {}

---Represents an item in a Neovim quickfix/loclist.
---@class telescope.Item
---@field lnum? number The start line number for the item.
---@field col? number The column number where the item starts.
---@field bufnr? number The buffer number where the item originates.
---@field filename? string The filename of the item.
---@field text? string The text of the item.
---@field cwd? string The current working directory of the item.
---@field path? string The path of the item.

M.sources = {
  files = "find_files",
  grep = "live_grep",
}

---@param source string
---@param cb fun(items:sidekick.context.Loc[])
---@param opts? table
function M.open(source, cb, opts)
  -- example for running a command on a file
  opts = opts or {}
  opts.attach_mappings = function()
    local actions = require("telescope.actions")
    actions.select_default:replace(M.action(cb))
    return true
  end
  source = M.sources[source] or source
  require("telescope.builtin")[source](opts)
end

---@param cb fun(items:sidekick.context.Loc[])
function M.action(cb)
  return function(prompt_bufnr)
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local picker = action_state.get_current_picker(prompt_bufnr)
    actions.close(prompt_bufnr)
    local items = {} ---@type telescope.Item[]
    if #picker:get_multi_selection() > 0 then
      vim.list_extend(items, picker:get_multi_selection())
    else
      items[1] = action_state.get_selected_entry()
    end
    ---@param item telescope.Item
    cb(vim.tbl_map(function(item)
      ---@type sidekick.context.Loc
      return {
        buf = item.bufnr,
        name = item.path or item.filename,
        row = item.lnum,
        col = item.col,
        cwd = item.cwd,
      }
    end, items))
  end
end

function M.send(prompt_bufnr)
  M.action(require("sidekick.cli.picker")._send_cb())(prompt_bufnr)
end

return M
