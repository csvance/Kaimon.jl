using ReTest
using Kaimon
using Kaimon: MCPTool
using HTTP
using JSON

# `tools/list_changed` must reach a client over HTTP whichever channel it is reading. These
# drive a real server the way Claude Code does: POSTs under an Mcp-Session-Id, plus a GET
# receive stream for the same id that the client may or may not be reading. The failure they
# pin down: a GET stream the client had stopped reading consumed the notification, and because
# it shared a cursor with the POST channel, no later POST carried it, so the tools an
# extension registered stayed invisible until the user ran `/mcp`.

_nd_tool(name, handler = args -> "ok") =
    MCPTool(Symbol(name), name, name, "t", Kaimon.text_parameter("text", "t"), handler)

function _nd_post(url, body; sid = nothing)
    hdrs = ["Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"]
    sid === nothing || push!(hdrs, "Mcp-Session-Id" => sid)
    return HTTP.post(url, hdrs, JSON.json(body); status_exception = false)
end

function _nd_session(url)
    r = _nd_post(url, Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
        "params" => Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(),
            "clientInfo" => Dict("name" => "notification-tests", "version" => "0"))))
    sid = HTTP.header(r, "Mcp-Session-Id")
    _nd_post(url, Dict("jsonrpc" => "2.0", "method" => "notifications/initialized"); sid)
    _nd_call(url, sid)   # drain whatever the board already holds for this session
    return sid
end

_nd_call(url, sid, name = "nd_echo") = String(_nd_post(url, Dict("jsonrpc" => "2.0",
    "id" => rand(1:10^6), "method" => "tools/call",
    "params" => Dict("name" => name, "arguments" => Dict("text" => "x"))); sid).body)

_nd_list_changed(body) = occursin("notifications/tools/list_changed", body)

# A GET receive stream for `sid`. With `read = false` the client opened it and stopped reading,
# which is what a stream left over from an idle session looks like from the server. Returns
# (task, lines, stop): set `stop[]` to end it.
function _nd_get_stream(url, sid; read::Bool)
    lines = String[]
    stop = Ref(false)
    task = @async try
        HTTP.open("GET", url, ["Mcp-Session-Id" => sid, "Accept" => "text/event-stream"]) do io
            startread(io)
            while !stop[] && !eof(io)
                read ? push!(lines, readline(io)) : sleep(0.1)
            end
        end
    catch
    end
    sleep(1.5)   # let the server bind the stream before anything is queued
    return (task, lines, stop)
end

# The GET loop polls the board once a second.
_nd_tick() = sleep(2.5)

@testset "tools/list_changed reaches the client" begin
    saved_gate_mode = Kaimon.GATE_MODE[]
    saved_server = Kaimon.SERVER[]
    server = Kaimon.start_mcp_server([_nd_tool("nd_echo")], 0; verbose = false)
    # As the real server has them: dynamic tools land in the live registry, and gate and
    # session tools take the streaming path (`_handle_gate_tool_sse`).
    Kaimon.SERVER[] = server
    Kaimon.GATE_MODE[] = true
    url = "http://127.0.0.1:$(server.port)/mcp"
    streams = []
    try
        @testset "A: no GET stream, the next POST carries it" begin
            sid = _nd_session(url)
            Kaimon._register_dynamic_tools!([_nd_tool("nd_a")])
            @test _nd_list_changed(_nd_call(url, sid))
        end

        @testset "B: an unread GET stream does not stop the next POST carrying it" begin
            sid = _nd_session(url)
            s = _nd_get_stream(url, sid; read = false)
            push!(streams, s)
            Kaimon._register_dynamic_tools!([_nd_tool("nd_b")])
            _nd_tick()
            @test _nd_list_changed(_nd_call(url, sid))
        end

        @testset "C: idle reap, return, register: the next POST carries it" begin
            sid = _nd_session(url)
            s = _nd_get_stream(url, sid; read = false)
            push!(streams, s)
            Kaimon._reap_stale_sessions!(0.0)
            @test !haskey(Kaimon.STANDALONE_SESSIONS, sid)
            _nd_call(url, sid)   # the client comes back under its old id
            Kaimon._register_dynamic_tools!([_nd_tool("nd_c")])
            _nd_tick()
            @test _nd_list_changed(_nd_call(url, sid))
        end

        @testset "C': a session the server forgot gets the board again when it returns" begin
            sid = _nd_session(url)
            @test !_nd_list_changed(_nd_call(url, sid))   # drained: nothing new for it
            Kaimon._reap_stale_sessions!(0.0)
            # Nothing changed, but the server cannot know what the client missed while it was
            # forgotten, so its first request back replays the board. A repeat is harmless.
            @test _nd_list_changed(_nd_call(url, sid))
            @test !_nd_list_changed(_nd_call(url, sid))   # once, then quiet again
        end

        @testset "D: a gate-path call carries the change it caused" begin
            sid = _nd_session(url)
            # A namespaced session tool whose handler registers tools, as the `ex` that loads
            # an extension does.
            loader = _nd_tool("nd.load",
                args -> (Kaimon._register_dynamic_tools!([_nd_tool("nd_d")]); "loaded"))
            Kaimon._register_dynamic_tools!([loader])
            _nd_call(url, sid)   # drain the loader's own announcement
            body = _nd_call(url, sid, "nd.load")
            @test occursin("loaded", body)
            @test _nd_list_changed(body)
            # The notification precedes the result, so a client refetches before it acts.
            @test findfirst("notifications/tools/list_changed", body).start <
                  findfirst("loaded", body).start
            @test !_nd_list_changed(_nd_call(url, sid))   # delivered once, not again
        end

        @testset "a GET stream the client reads receives it as well" begin
            sid = _nd_session(url)
            s = _nd_get_stream(url, sid; read = true)
            push!(streams, s)
            Kaimon._register_dynamic_tools!([_nd_tool("nd_e")])
            _nd_tick()
            @test any(_nd_list_changed, s[2])
            @test _nd_list_changed(_nd_call(url, sid))   # and the POST, independently
        end
    finally
        for (_, _, stop) in streams
            stop[] = true
        end
        Kaimon.GATE_MODE[] = saved_gate_mode
        Kaimon.SERVER[] = saved_server
        Kaimon.stop_mcp_server(server)
        for (task, _, _) in streams
            timedwait(() -> istaskdone(task), 5.0)
        end
    end
end
