const PREF_GATE_MIRROR_REPL = "gate_mirror_repl"

"""
    get_gate_mirror_repl_preference() -> Bool

Return whether gate evaluations should mirror command/result text in the host REPL.
"""
function get_gate_mirror_repl_preference()
    val = @load_preference(PREF_GATE_MIRROR_REPL, true)
    return val === true
end

"""
    set_gate_mirror_repl_preference!(enabled::Bool) -> Bool

Persist host-REPL mirroring preference in LocalPreferences.toml.
"""
function set_gate_mirror_repl_preference!(enabled::Bool)
    @set_preferences!(PREF_GATE_MIRROR_REPL => enabled)
    return enabled
end

const PREF_GATE_PROMOTE_AFTER = "gate_promote_after"   # seconds; 0 = never promote

"""
    get_gate_promote_after_preference() -> Float64

Seconds a foreground eval may run before it's promoted to a background job. `0` means
never promote (the eval stays foreground until it finishes). Default 30s. Overridden by
the `KAIMON_GATE_PROMOTE_AFTER` env var in `_promote_after`.
"""
function get_gate_promote_after_preference()::Float64
    val = @load_preference(PREF_GATE_PROMOTE_AFTER, 30.0)
    return val isa Real ? max(0.0, Float64(val)) : 30.0
end

"""
    set_gate_promote_after_preference!(secs::Real) -> Float64

Persist the auto-background threshold (seconds; 0 = never) in LocalPreferences.toml.
"""
function set_gate_promote_after_preference!(secs::Real)::Float64
    s = max(0.0, Float64(secs))
    @set_preferences!(PREF_GATE_PROMOTE_AFTER => s)
    return s
end

const PREF_PRINT_STRIP = "print_strip"   # "off" | "moderate" | "high"

"""
    get_print_strip_preference() -> Symbol

How much output-producing code is removed from agent evals: `:off`, `:moderate` (the
default) or `:high`. See print_strip.jl. Overridden by the `KAIMON_PRINT_STRIP` env var
in `print_strip_level`.
"""
function get_print_strip_preference()::Symbol
    val = @load_preference(PREF_PRINT_STRIP, "moderate")
    return val isa AbstractString ? _parse_strip_level(val) : :moderate
end

"""
    set_print_strip_preference!(level) -> Symbol

Persist the print-strip level in LocalPreferences.toml.
"""
function set_print_strip_preference!(level)::Symbol
    lv = Symbol(level)
    lv in PRINT_STRIP_LEVELS || throw(ArgumentError("print strip level must be one of $(PRINT_STRIP_LEVELS), got $(repr(level))"))
    @set_preferences!(PREF_PRINT_STRIP => String(lv))
    return lv
end

const PREF_AGENT_SESSIONS = "agent_sessions"   # "shared" | "private"
const AGENT_SESSION_MODES = (:shared, :private)

"""
    get_agent_sessions_preference() -> Symbol

Whether `start_session` gives each MCP client its own session (`:private`) or the one
already running for the project (`:shared`, the default). Overridden by the
`KAIMON_AGENT_SESSIONS` env var in `agent_sessions_mode`.
"""
function get_agent_sessions_preference()::Symbol
    val = @load_preference(PREF_AGENT_SESSIONS, "shared")
    return val isa AbstractString && Symbol(val) in AGENT_SESSION_MODES ? Symbol(val) : :shared
end

"""
    set_agent_sessions_preference!(mode) -> Symbol

Persist the agent-session mode in LocalPreferences.toml.
"""
function set_agent_sessions_preference!(mode)::Symbol
    m = Symbol(mode)
    m in AGENT_SESSION_MODES || throw(ArgumentError("agent session mode must be one of $(AGENT_SESSION_MODES), got $(repr(mode))"))
    @set_preferences!(PREF_AGENT_SESSIONS => String(m))
    return m
end

"""The active agent-session mode: `KAIMON_AGENT_SESSIONS`, else the preference."""
function agent_sessions_mode()::Symbol
    env = Symbol(lowercase(strip(get(ENV, "KAIMON_AGENT_SESSIONS", ""))))
    return env in AGENT_SESSION_MODES ? env : get_agent_sessions_preference()
end

const PREF_TEST_PROMOTE_AFTER = "test_promote_after"   # seconds; 0 = never background

"""
    get_test_promote_after_preference() -> Float64

Seconds a test run may hold the foreground before it's backgrounded. `0` means never
background (the tool blocks until the suite finishes). Default 30s. Overridden by the
`KAIMON_TEST_PROMOTE_AFTER` env var in `test_promote_after`.

Deliberately separate from the eval threshold: a project with a slow suite and fast evals
is ordinary, so the two are tuned independently even though they default the same.
"""
function get_test_promote_after_preference()::Float64
    val = @load_preference(PREF_TEST_PROMOTE_AFTER, 30.0)
    return val isa Real ? max(0.0, Float64(val)) : 30.0
end

"""
    set_test_promote_after_preference!(secs::Real) -> Float64

Persist the test auto-background threshold (seconds; 0 = never) in LocalPreferences.toml.
"""
function set_test_promote_after_preference!(secs::Real)::Float64
    s = max(0.0, Float64(secs))
    @set_preferences!(PREF_TEST_PROMOTE_AFTER => s)
    return s
end

const PREF_TEST_CONCURRENCY = "test_concurrency"   # concurrent runs per project

"""
    get_test_concurrency_preference() -> Int

How many test runs may be in flight for one project at a time. Default `1`.

Serialised by default because overlapping runs of the same project are rarely independent:
a subset and the full suite share fixtures, temp directories, ports and any global state
the suite mutates, so running them concurrently can fail or — worse — pass misleadingly.
Raise it for a suite you know is isolated.
"""
function get_test_concurrency_preference()::Int
    val = @load_preference(PREF_TEST_CONCURRENCY, 1)
    return val isa Real ? max(1, Int(val)) : 1
end

"""
    set_test_concurrency_preference!(n::Integer) -> Int

Persist the per-project test concurrency limit (minimum 1) in LocalPreferences.toml.
"""
function set_test_concurrency_preference!(n::Integer)::Int
    v = max(1, Int(n))
    @set_preferences!(PREF_TEST_CONCURRENCY => v)
    return v
end
