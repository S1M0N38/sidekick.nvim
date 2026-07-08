---@module 'luassert'

local tmux = require("sidekick.cli.session.tmux")

-- A representative session group id (`sid` = tool + cwd hash).
local SID = "pi a1b2c3d4e5f6a1"

describe("tmux.instance_number", function()
  -- mux_session, sid, expected instance number (nil = not an owned instance)
  local cases = {
    { SID .. " #1", SID, 1 },
    { SID .. " #2", SID, 2 },
    { SID .. " #13", SID, 13 },
    { SID, SID, nil }, -- bare sid: no ordinal, not an owned instance (no backward compat)
    { "some-other-session", SID, nil }, -- foreign tmux session
    { SID .. " #2", "pi differenthash", nil }, -- belongs to a different group
    { nil, SID, nil }, -- no mux_session
  }

  for _, c in ipairs(cases) do
    local label = ("%q -> %s"):format(c[1], tostring(c[3]))
    it(label, function()
      assert.are.same(c[3], tmux.instance_number(c[1], c[2]))
    end)
  end
end)

describe("tmux.next_session", function()
  local Util = require("sidekick.util")
  local orig_exec
  local sessions

  before_each(function()
    orig_exec = Util.exec
    sessions = {}
    Util.exec = function()
      return sessions
    end
  end)

  after_each(function()
    Util.exec = orig_exec
  end)

  local function name(n)
    return SID .. " #" .. n
  end

  -- running session names, expected next name
  local cases = {
    { {}, name(1) }, -- nothing running -> #1
    { { name(1) }, name(2) }, -- one running -> #2
    { { name(1), name(3) }, name(4) }, -- gap -> highest + 1
    { { "other-session", name(2) }, name(3) }, -- foreign session ignored
    { { name(5), name(2), name(9) }, name(10) }, -- unsorted -> highest + 1
  }

  for _, c in ipairs(cases) do
    local running = #c[1] == 0 and "(none)" or table.concat(c[1], ", ")
    it(("-> %s when running: %s"):format(c[2], running), function()
      sessions = c[1]
      assert.are.same(c[2], tmux.next_session(SID))
    end)
  end
end)

describe("tmux:start (spawning an owned instance)", function()
  local Util = require("sidekick.util")
  local orig_exec

  before_each(function()
    orig_exec = Util.exec
    Util.exec = function()
      return {} -- no instances running
    end
  end)

  after_each(function()
    Util.exec = orig_exec
  end)

  local function session(opts)
    return setmetatable(
      vim.tbl_extend("keep", opts or {}, {
        sid = SID,
        id = SID,
        cwd = "/tmp/proj",
        external = false,
        started = false,
        tool = { cmd = { "pi" }, env = {} },
      }),
      { __index = tmux }
    )
  end

  local function flag(cmd, f)
    for i, v in ipairs(cmd) do
      if v == f then
        return cmd[i + 1]
      end
    end
  end

  it("names the new session with a unique instance name (#1 when none running)", function()
    local s = session()
    local ret = s:start()
    assert.are.same(SID .. " #1", s.mux_session)
    assert.are.same(SID .. " #1", flag(ret.cmd, "-s"))
  end)

  it("assigns the next free number when an instance is already running", function()
    Util.exec = function()
      return { SID .. " #1" } -- one instance already running
    end
    local s = session()
    local ret = s:start()
    assert.are.same(SID .. " #2", s.mux_session)
    assert.are.same(SID .. " #2", flag(ret.cmd, "-s"))
  end)
end)

describe("tmux:attach", function()
  local function session(opts)
    return setmetatable(
      vim.tbl_extend("keep", opts or {}, {
        sid = SID,
      }),
      { __index = tmux }
    )
  end

  it("reattaches to an owned instance by its mux_session", function()
    local s = session({ mux_session = SID .. " #2" })
    local ret = s:attach()
    assert.are.same({ "tmux", "attach-session", "-t", SID .. " #2" }, ret.cmd)
  end)

  it("returns nil for an external (non-owned) session", function()
    local ret = session({ mux_session = "my-session" }):attach()
    assert.is_nil(ret)
  end)

  it("returns nil for a bare sid (no ordinal -> not owned)", function()
    local ret = session({ mux_session = SID }):attach()
    assert.is_nil(ret)
  end)
end)

describe("tmux:init (classifying a discovered session)", function()
  local function init_session(opts)
    local s = setmetatable(
      vim.tbl_extend("keep", opts or {}, {
        sid = SID,
        started = true,
      }),
      { __index = tmux }
    )
    s:init()
    return s
  end

  it("marks an owned instance as not external and stores its number", function()
    local s = init_session({ mux_session = SID .. " #2" })
    assert.are.same(2, s.iid)
    assert.is_false(s.external)
  end)

  it("marks a foreign tmux session as external", function()
    local s = init_session({ mux_session = "my-session" })
    assert.is_nil(s.iid)
    assert.is_true(s.external)
  end)

  it("treats a bare sid (no ordinal) as external", function()
    local s = init_session({ mux_session = SID })
    assert.is_nil(s.iid)
    assert.is_true(s.external)
  end)
end)

describe("State.get spawn flag", function()
  local Session = require("sidekick.cli.session")
  local State = require("sidekick.cli.state")
  local Config = require("sidekick.config")
  local orig_sessions, orig_tools

  -- a fake running pi instance discovered by the tmux backend
  local function running_pi()
    return {
      sid = Session.sid({ tool = "pi" }),
      id = "tmux 12345",
      backend = "tmux",
      external = false,
      started = true,
      priority = 50,
      pids = {},
      tool = Config.get_tool("pi"),
      cwd = Session.cwd(),
      is_attached = function()
        return false
      end,
    }
  end

  before_each(function()
    orig_sessions = Session.sessions
    orig_tools = Config.tools
    Session.sessions = function()
      return { running_pi() }
    end
    Config.tools = function()
      return { pi = Config.get_tool("pi") }
    end
  end)

  after_each(function()
    Session.sessions = orig_sessions
    Config.tools = orig_tools
  end)

  local function has_new(states)
    for _, st in ipairs(states) do
      if st.session == nil then
        return true
      end
    end
    return false
  end

  it("without spawn: hides the '+new' entry when an instance is running", function()
    local states = State.get({ name = "pi" })
    assert.is_false(has_new(states))
  end)

  it("with spawn=true: includes the '+new' entry even when an instance is running", function()
    local states = State.get({ name = "pi" }, { spawn = true })
    assert.is_true(has_new(states))
  end)

  it("with spawn + cwd filter: still includes '+new' (spawns in the current dir)", function()
    local states = State.get({ name = "pi", cwd = true }, { spawn = true })
    assert.is_true(has_new(states))
  end)
end)

describe("Session.attach: distinct ids per owned instance", function()
  local Session = require("sidekick.cli.session")
  local Terminal = require("sidekick.cli.terminal")
  local orig_init, orig_start

  -- a discovered owned tmux instance that reattaches via `tmux attach-session`
  local function owned(mux_session, pid)
    return {
      sid = SID,
      id = "tmux " .. pid,
      backend = "tmux",
      mux_session = mux_session,
      started = true,
      cwd = "/tmp/proj",
      tool = {
        name = "pi",
        cmd = { "pi" },
        env = {},
        clone = function()
          return { name = "pi", cmd = { "pi" }, env = {} }
        end,
      },
      attach = function(self)
        return { cmd = { "tmux", "attach-session", "-t", self.mux_session } }
      end,
    }
  end

  before_each(function()
    Session.setup()
    orig_init = Terminal.init
    orig_start = Terminal.start
    Terminal.init = function() end -- don't open a real terminal / create buffers
    Terminal.start = function() end
  end)

  after_each(function()
    Terminal.init = orig_init
    Terminal.start = orig_start
    for k in pairs(Session._attached) do
      Session._attached[k] = nil
    end
  end)

  it("tracks each instance under a distinct terminal id", function()
    local a = Session.attach(owned(SID .. " #1", "111"))
    local b = Session.attach(owned(SID .. " #2", "222"))
    assert.are.same("terminal: " .. SID .. " #1", a.id)
    assert.are.same("terminal: " .. SID .. " #2", b.id)
  end)
end)
