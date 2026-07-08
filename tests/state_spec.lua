---@module 'luassert'

local Select = require("sidekick.cli.ui.select")
local State = require("sidekick.cli.state")

-- A fake session/state. `open` controls whether its terminal is visible in the
-- sidekick panel (i.e. `terminal:is_open()` returns true).
local function fake(name, open)
  return {
    tool = { name = name },
    session = { id = name },
    attached = true,
    terminal = open and {
      is_open = function()
        return true
      end,
    } or nil,
  }
end

describe("State.with: prefer the session open in the panel", function()
  local orig_get, orig_attach, orig_select
  local received, picker_called

  before_each(function()
    orig_get = State.get
    orig_attach = State.attach
    orig_select = Select.select
    -- avoid opening real terminals / windows in headless tests
    State.attach = function(state)
      return state, false
    end
    Select.select = function()
      picker_called = true
    end
    received = nil
    picker_called = false
  end)

  after_each(function()
    State.get = orig_get
    State.attach = orig_attach
    Select.select = orig_select
  end)

  -- states, expected tool the callback runs on (nil => picker shown instead)
  local cases = {
    {
      name = "targets the open session among several attached",
      states = { fake("pi", true), fake("aider", false) },
      expect_tool = "pi",
    },
    {
      name = "targets the open session when it is the only attached one",
      states = { fake("pi", true) },
      expect_tool = "pi",
    },
    {
      name = "falls back to the picker when no session is open",
      states = { fake("pi", false), fake("aider", false) },
      expect_tool = nil,
    },
  }

  for _, c in ipairs(cases) do
    it(c.name, function()
      State.get = function()
        return c.states
      end
      State.with(function(state)
        received = state
      end, { attach = true, show = true })

      if c.expect_tool then
        vim.wait(100, function()
          return received ~= nil
        end)
        assert.is_not_nil(received)
        assert.are.same(c.expect_tool, received.tool.name)
        assert.is_false(picker_called)
      else
        assert.is_nil(received)
        assert.is_true(picker_called)
      end
    end)
  end

  it("does not shortcut when all=true (operates on every attached session)", function()
    local states = { fake("pi", true), fake("aider", false) }
    State.get = function()
      return states
    end
    local seen = {}
    State.with(function(state)
      table.insert(seen, state.tool.name)
    end, { attach = true, all = true })

    vim.wait(100, function()
      return #seen == #states
    end)
    assert.are.same({ "pi", "aider" }, seen)
    assert.is_false(picker_called)
  end)
end)
