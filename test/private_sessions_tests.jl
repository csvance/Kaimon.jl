using ReTest
using Kaimon

# Private agent sessions (#97): an agent can own a session for a project that no other
# agent is handed by start_session or picked for by automatic binding, and tools default
# to the caller's bound session when `ses` is omitted.

const K = Kaimon

_fake_conn(port, proj; pid = port) = (c = K.REPLConnection(
    session_id = "tcp-127.0.0.1-$port", endpoint = "tcp://127.0.0.1:$port",
    name = "s$port", project_path = proj, spawned_by = "agent", pid = pid);
    c.status = :connected; c)

function _with_mcp_caller(f, caller)
    task_local_storage(:mcp_caller, caller) do
        f()
    end
end

function _register_caller!(caller)
    sess = K.Session.MCPSession()
    sess.id = caller
    lock(K.STANDALONE_SESSIONS_LOCK) do
        K.STANDALONE_SESSIONS[caller] = sess
    end
    return sess
end

_unregister_callers!(callers...) = lock(K.STANDALONE_SESSIONS_LOCK) do
    foreach(c -> delete!(K.STANDALONE_SESSIONS, c), callers)
end

@testset "Private agent sessions (#97)" begin
    proj = mktempdir()
    write(joinpath(proj, "Project.toml"), "name = \"P97\"\n")
    proj = K.normalize_path(proj)

    shared = _fake_conn(9701, proj)                  # e.g. the user's own REPL
    mine = _fake_conn(9702, proj)                    # caller A's private session
    mgr = K.ConnectionManager(sock_dir = mktempdir())
    lock(mgr.lock) do
        append!(mgr.connections, [shared, mine])
    end

    ms_mine = K.ManagedSession(proj; owner = "caller-A-0000")
    ms_mine.session_key = K.short_key(mine)
    ms_mine.status = :running

    old_mgr = K.GATE_CONN_MGR[]
    K.GATE_CONN_MGR[] = mgr
    lock(K.MANAGED_SESSIONS_LOCK) do
        push!(K.MANAGED_SESSIONS, ms_mine)
    end
    sess_a = _register_caller!("caller-A-0000")
    sess_b = _register_caller!("caller-B-0000")
    try
        @testset "ownership records" begin
            @test ms_mine.name == "$(basename(proj)) (private)"
            @test endswith(ms_mine.log_file, "$(basename(proj))-caller-A.log")
            @test K.ManagedSession(proj).owner == ""
            @test K.session_owner(K.short_key(mine)) == "caller-A-0000"
            @test K.session_owner(K.short_key(shared)) == ""
            @test K.private_to_other(K.short_key(mine), "caller-B-0000")
            @test !K.private_to_other(K.short_key(mine), "caller-A-0000")
            @test K.find_managed_by_key(K.short_key(mine)) === ms_mine
            @test K.find_managed_session(proj; owner = "caller-A-0000") === ms_mine
            @test K.find_managed_session(proj; owner = "") === nothing
        end

        @testset "automatic binding skips another agent's private session" begin
            K._bind_caller_to_project!("caller-B-0000", proj)
            @test sess_b.target_julia_session_id == K.short_key(shared)
            K._bind_caller_to_project!("caller-A-0000", proj)
            @test sess_a.target_julia_session_id == K.short_key(mine)   # its own wins the tie
        end

        @testset "omitted ses resolves to the caller's session" begin
            _with_mcp_caller("caller-A-0000") do
                c, err = K._resolve_gate_conn("")
                @test err === nothing && c === mine
            end
            _with_mcp_caller("caller-B-0000") do
                c, err = K._resolve_gate_conn("")
                @test err === nothing && c === shared
                # An explicit key still reaches it: private is about defaults, not access.
                c, err = K._resolve_gate_conn(K.short_key(mine))
                @test err === nothing && c === mine
            end
            # An unbound caller never lands on someone else's private session.
            _register_caller!("caller-C-0000")
            _with_mcp_caller("caller-C-0000") do
                c, err = K._resolve_gate_conn("")
                @test err === nothing && c === shared
            end
        end

        @testset "start_session converges on the right session" begin
            call(caller, args) = _with_mcp_caller(() -> K.start_session_tool.handler(args), caller)
            r = call("caller-B-0000", Dict("project_path" => proj))
            @test occursin("session key: $(K.short_key(shared))", r)
            r = call("caller-A-0000", Dict("project_path" => proj, "private" => true))
            @test occursin("Your private session", r) && occursin(K.short_key(mine), r)
            @test sess_a.target_julia_session_id == K.short_key(mine)
            listing = call("caller-A-0000", Dict{String,Any}())
            @test listing isa String
        end

        @testset "agent session mode resolution" begin
            withenv("KAIMON_AGENT_SESSIONS" => "private") do
                @test K.agent_sessions_mode() === :private
            end
            withenv("KAIMON_AGENT_SESSIONS" => "bogus") do
                @test K.agent_sessions_mode() === K.get_agent_sessions_preference()
            end
            @test_throws ArgumentError K.set_agent_sessions_preference!(:everyone)
        end
    finally
        K.GATE_CONN_MGR[] = old_mgr
        lock(K.MANAGED_SESSIONS_LOCK) do
            filter!(ms -> ms !== ms_mine, K.MANAGED_SESSIONS)
        end
        _unregister_callers!("caller-A-0000", "caller-B-0000", "caller-C-0000")
    end
end

@testset "monitor matches each starting session to its own process (#97)" begin
    proj = K.normalize_path(mktempdir())
    p1 = run(`sleep 30`; wait = false)
    p2 = run(`sleep 30`; wait = false)
    ms1 = K.ManagedSession(proj; owner = "o1")
    ms2 = K.ManagedSession(proj; owner = "o2")
    for (ms, p) in ((ms1, p1), (ms2, p2))
        ms.process = p
        ms.status = :starting
        ms.started_at = time()
    end
    # The second session's gate connects first; it must not be claimed by the first.
    c2 = _fake_conn(9712, proj; pid = Int(getpid(p2)))
    c1 = _fake_conn(9711, proj; pid = Int(getpid(p1)))
    mgr = K.ConnectionManager(sock_dir = mktempdir())
    lock(mgr.lock) do
        append!(mgr.connections, [c2, c1])
    end
    lock(K.MANAGED_SESSIONS_LOCK) do
        append!(K.MANAGED_SESSIONS, [ms1, ms2])
    end
    try
        K._monitor_managed_sessions!(mgr)
        @test ms1.session_key == K.short_key(c1)
        @test ms2.session_key == K.short_key(c2)
    finally
        lock(K.MANAGED_SESSIONS_LOCK) do
            filter!(ms -> ms !== ms1 && ms !== ms2, K.MANAGED_SESSIONS)
        end
        kill(p1); kill(p2)
    end
end
