using ReTest
using Kaimon
using Kaimon: MCPTool
using HTTP
using JSON
using Dates
using Sockets

# Create test tools
time_tool =
    @mcp_tool :get_time "Get current time in specified format" Kaimon.text_parameter(
        "format",
        "DateTime format string (e.g., 'yyyy-mm-dd HH:MM:SS')",
    ) args -> Dates.format(now(), get(args, "format", "yyyy-mm-dd HH:MM:SS"))

reverse_tool = @mcp_tool :reverse_text "Reverse the input text" Kaimon.text_parameter(
    "text",
    "Text to reverse",
) args -> reverse(get(args, "text", ""))

calc_tool = @mcp_tool :calculate "Evaluate a simple Julia expression" Kaimon.text_parameter(
    "expression",
    "Julia expression to evaluate (e.g., '2 + 3 * 4')",
) function (args)
    try
        expr = Meta.parse(get(args, "expression", "0"))
        result = eval(expr)
        string(result)
    catch e
        "Error: $e"
    end
end

server_tools = [time_tool, reverse_tool, calc_tool]

@testset "Server Startup and Shutdown" begin
    # Start on an OS-assigned ephemeral port (0) to avoid fixed-port collisions.
    server = Kaimon.start_mcp_server(server_tools, 0)
    test_port = server.port

    @test server.port > 0
    @test length(server.tools) == 3
    @test haskey(server.tools, :get_time)
    @test haskey(server.tools, :reverse_text)
    @test haskey(server.tools, :calculate)

    # Give server time to start
    sleep(0.1)

    # Stop server
    Kaimon.stop_mcp_server(server)

    # Give server time to stop
    sleep(0.1)
end

@testset "Invalid Requests" begin
    # Start server for invalid request tests
    server = Kaimon.start_mcp_server(server_tools, 0)
    test_port = server.port

    # Give server time to start
    sleep(0.1)

    try
        # Test empty body - HTTP.jl throws exception for 400 status by default
        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            "";
            status_exception = false,
        )

        @test response.status == 400

        # Parse error response
        body = String(response.body)
        json_response = JSON.parse(body)

        @test haskey(json_response, :error)
        @test occursin("empty body", json_response.error.message)

    finally
        # Always stop server
        Kaimon.stop_mcp_server(server)
        sleep(0.1)
    end
end

@testset "Requests in a newer, initialize-less MCP are turned away" begin
    # MCP 2026-07-28 has no `initialize`: a client that speaks it and the older versions sends a
    # new-style request first and falls back to `initialize` on a 400 whose error is not one of
    # 2026-07-28's own (-32020 to -32022).
    server = Kaimon.start_mcp_server(server_tools, 0)
    port = server.port
    sleep(0.1)
    post(body; headers = String[]) = HTTP.post("http://localhost:$port/",
        ["Content-Type" => "application/json", headers...], JSON.json(body); status_exception = false)
    rpc(method; id = 7, meta = nothing) = (p = Dict{String,Any}();
        meta === nothing || (p["_meta"] = meta);
        Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => p))
    # `String(r.body)` empties the byte vector, so each body is read once.
    reply(r) = (r.status, JSON.parse(String(r.body)))
    turned_away(r) = ((s, j) = reply(r); s == 400 && j.error.code == -32600)
    try
        @test turned_away(post(rpc("tools/list"); headers = ["MCP-Protocol-Version" => "2026-07-28"]))
        s, j = reply(post(rpc("server/discover"; id = 42)))
        @test s == 400 && j.error.code == -32600
        @test j.id == 42
        @test occursin("initialize", j.error.message)
        @test turned_away(post(rpc("tools/list";
            meta = Dict("io.modelcontextprotocol/protocolVersion" => "2026-07-28"))))

        # The versions this server speaks are unaffected, with or without the `_meta` field.
        @test post(rpc("tools/list";
            meta = Dict("io.modelcontextprotocol/protocolVersion" => "2025-11-25"))).status == 200
        @test post(rpc("tools/list")).status == 200
        init = Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => Dict(
            "protocolVersion" => "2025-11-25", "capabilities" => Dict(),
            "clientInfo" => Dict("name" => "test", "version" => "0")))
        @test post(init).status == 200
    finally
        Kaimon.stop_mcp_server(server)
        sleep(0.1)
    end
end

@testset "Tool Listing" begin
    # Start server for tool listing tests
    server = Kaimon.start_mcp_server(server_tools, 0)
    test_port = server.port

    # Give server time to start
    sleep(0.1)

    try
        # Test tools/list request
        request_body =
            JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"))

        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            request_body,
        )

        @test response.status == 200

        # Parse response
        body = String(response.body)
        json_response = JSON.parse(body)

        @test json_response.jsonrpc == "2.0"
        @test json_response.id == 1
        @test haskey(json_response.result, "tools")
        @test length(json_response.result.tools) == 3

        # Check tool names
        tool_names = [tool.name for tool in json_response.result.tools]
        @test "get_time" in tool_names
        @test "reverse_text" in tool_names
        @test "calculate" in tool_names

    finally
        # Always stop server
        Kaimon.stop_mcp_server(server)
        sleep(0.1)
    end
end

@testset "Tool Execution" begin
    # Start server for tool execution tests
    server = Kaimon.start_mcp_server(server_tools, 0)
    test_port = server.port

    # Give server time to start
    sleep(0.1)

    try
        # Test reverse_text tool
        request_body = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "reverse_text",
                    "arguments" => Dict("text" => "hello"),
                ),
            ),
        )

        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            request_body,
        )

        @test response.status == 200

        # Parse response
        body = String(response.body)
        json_response = JSON.parse(body)

        @test json_response.result.content[1].text == "olleh"

        # Test calculate tool
        request_body = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 3,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "calculate",
                    "arguments" => Dict("expression" => "2 + 3 * 4"),
                ),
            ),
        )

        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            request_body,
        )

        @test response.status == 200

        # Parse response
        body = String(response.body)
        json_response = JSON.parse(body)

        @test json_response.result.content[1].text == "14"

    finally
        # Always stop server
        Kaimon.stop_mcp_server(server)
        sleep(0.1)
    end
end

@testset "Tool Call Invalid Arguments (HTTP 200 + JSON-RPC error)" begin
    # A tools/call with bad arguments is a JSON-RPC *application* error, not an
    # HTTP transport error: it MUST return HTTP 200 with a JSON-RPC error
    # payload. Returning 4xx makes MCP clients tear down the entire SSE session
    # (the connection-crash bug reported with type_info / qdrant / list_names).
    server = Kaimon.start_mcp_server(server_tools, 0)
    test_port = server.port
    sleep(0.1)

    try
        # (1) Unknown parameter name (e.g. passing the wrong arg key)
        unknown_arg = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 10,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "reverse_text",
                    "arguments" => Dict("wrong_name" => "hello"),
                ),
            ),
        )
        r1 = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            unknown_arg;
            status_exception = false,
        )
        @test r1.status == 200            # NOT 400 — must keep the transport alive
        j1 = JSON.parse(String(r1.body))
        @test j1.id == 10
        @test haskey(j1, :error)
        @test j1.error.code == -32602
        @test occursin("Unknown parameter", j1.error.message)

        # (2) Missing required parameter
        missing_arg = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 11,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "reverse_text",
                    "arguments" => Dict{String,Any}(),
                ),
            ),
        )
        r2 = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            missing_arg;
            status_exception = false,
        )
        @test r2.status == 200
        j2 = JSON.parse(String(r2.body))
        @test haskey(j2, :error)
        @test j2.error.code == -32602
        @test occursin("Missing required parameter", j2.error.message)

        # (3) The connection must still be usable after the errors (no crash).
        followup =
            JSON.json(Dict("jsonrpc" => "2.0", "id" => 12, "method" => "tools/list"))
        r3 = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            followup;
            status_exception = false,
        )
        @test r3.status == 200
        @test haskey(JSON.parse(String(r3.body)).result, "tools")

    finally
        Kaimon.stop_mcp_server(server)
        sleep(0.1)
    end
end

# Open a raw GET SSE stream for `sid` and return the socket once the stream is idle:
# past the response head and the `roots/list` request every new stream sends. A client
# that leaves before that request would be caught by its write, not by the keepalive.
function _open_sse(port, sid)
    sock = Sockets.connect(Sockets.localhost, port)
    write(sock, "GET /mcp HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n" *
                "Mcp-Session-Id: $sid\r\n\r\n")
    head = readuntil(sock, "\r\n\r\n")
    @test occursin("200", first(split(head, "\r\n")))
    @test occursin("roots/list", readuntil(sock, "roots/list"; keep = true))
    return sock
end

_stream_registered(sid) = lock(() -> haskey(Kaimon._SESSION_OUTBOX, sid), Kaimon._SESSION_OUTBOX_LOCK)

@testset "SSE GET stream ends when the client goes away" begin
    server = Kaimon.start_mcp_server(server_tools, 0)
    saved = Kaimon._SSE_KEEPALIVE_SECS[]
    Kaimon._SSE_KEEPALIVE_SECS[] = 0.5
    try
        # A client that disconnects: the keepalive write fails and the loop unregisters.
        sid = "sse-gone-$(rand(UInt32))"
        sock = _open_sse(server.port, sid)
        @test timedwait(() -> _stream_registered(sid), 5.0) === :ok
        close(sock)
        @test timedwait(() -> !_stream_registered(sid), 15.0) === :ok
        # ...and HTTP.jl then closes the server side of the connection.
        @test timedwait(() -> isempty(HTTP._server_conns(server.server)), 5.0) === :ok

        # A stream replaced by a newer one for the same session ends its response (the
        # chunked terminator arrives; the connection itself stays keep-alive).
        sid2 = "sse-replaced-$(rand(UInt32))"
        first_sock = _open_sse(server.port, sid2)
        @test timedwait(() -> _stream_registered(sid2), 5.0) === :ok
        second_sock = _open_sse(server.port, sid2)
        body = IOBuffer()
        ended = Threads.Atomic{Bool}(false)
        @async try
            while !eof(first_sock)
                write(body, readavailable(first_sock))
                endswith(String(copy(body.data[1:body.size])), "0\r\n\r\n") && break
            end
        catch
        finally
            ended[] = true
        end
        @test timedwait(() -> ended[], 15.0) === :ok
        @test _stream_registered(sid2)          # the newer stream still owns the session
        close(second_sock)
        close(first_sock)
    finally
        Kaimon._SSE_KEEPALIVE_SECS[] = saved
        Kaimon.stop_mcp_server(server)
        sleep(0.1)
    end
end

