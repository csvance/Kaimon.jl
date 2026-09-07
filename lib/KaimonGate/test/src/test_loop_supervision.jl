# Control-plane supervision, the parts checkable without a live Kaimon: ZMQ error
# classification, worker-slot accounting, the supervisor's lifecycle gate, and
# _ensure_router! against a real socket. test_integration.jl covers the loop itself.

using Test
using KaimonGate
using Serialization

const KG = KaimonGate
const ZMQ = KG.ZMQ

# ── ZMQ.StateError classification ─────────────────────────────────────────────
# Messages are built the way ZMQ.jl builds them (libzmq's zmq_strerror).

@testset "ZMQ error disposition" begin
    eintr = ZMQ.StateError(KG._zmq_errno_msg(Base.Libc.EINTR))
    @test KG._zmq_error_disposition(eintr) === :retry
    @test KG._zmq_error_disposition(ZMQ.StateError("Interrupted system call")) === :retry

    eterm = ZMQ.StateError(KG._zmq_errno_msg(ZMQ.lib.ETERM))
    @test KG._zmq_error_disposition(eterm) === :restart
    enotsock = ZMQ.StateError(KG._zmq_errno_msg(Base.Libc.ENOTSOCK))
    @test KG._zmq_error_disposition(enotsock) === :restart
    # Unrecognised text goes to the supervisor too.
    @test KG._zmq_error_disposition(ZMQ.StateError("some new libzmq condition")) === :restart
end

# ── Worker-slot accounting ────────────────────────────────────────────────────

function _drain_outbox!()
    while isready(KG._GATE_OUTBOX)
        take!(KG._GATE_OUTBOX)
    end
end

@testset "_serve_request releases its slot and always replies" begin
    # A session, because handling a request bumps the per-session message and ping counters.
    saved = KG._SESSION[]
    KG._SESSION[] = KG.GateSession(; running = true)
    try
        _drain_outbox!()
        base = KG._GATE_INFLIGHT[]
        id, cid = UInt8[1, 2], UInt8[3, 4]

        # Normal path: a ping is handled, replied to, and the slot comes back.
        Threads.atomic_add!(KG._GATE_INFLIGHT, 1)
        KG._serve_request(id, cid, (type = :ping,))
        @test KG._GATE_INFLIGHT[] == base
        (rid, rcid, bytes) = take!(KG._GATE_OUTBOX)
        @test rid == id && rcid == cid
        @test deserialize(IOBuffer(bytes)).type === :pong
        @test KG._ping_count() == 1        # counted against this session, not a global

        # handle_message cannot dispatch a non-NamedTuple: error reply, slot released.
        Threads.atomic_add!(KG._GATE_INFLIGHT, 1)
        KG._serve_request(id, cid, Dict(:type => :ping))
        @test KG._GATE_INFLIGHT[] == base
        reply = deserialize(IOBuffer(take!(KG._GATE_OUTBOX)[3]))
        @test reply.type === :error

        # An unknown request type is still a reply, not a leaked slot.
        Threads.atomic_add!(KG._GATE_INFLIGHT, 1)
        KG._serve_request(id, cid, (type = :no_such_message,))
        @test KG._GATE_INFLIGHT[] == base
        @test isready(KG._GATE_OUTBOX)
        _drain_outbox!()
    finally
        KG._SESSION[] = saved
    end
end

# ── Supervisor lifecycle gate ─────────────────────────────────────────────────
# stop, restart, :shutdown and :restart each clear _running() and may raise
# `shutting_down` or `restarting` first; the supervisor must stand down on any of them.

@testset "_gate_should_run honours every lifecycle flag" begin
    saved = KG._SESSION[]     # all three flags live on the session, so this restores them all
    try
        # A session with no sockets is enough: the supervisor only reads flags.
        KG._SESSION[] = KG.GateSession(; running = true)
        @test KG._gate_should_run()
        KG._shutting_down!(true)
        @test !KG._gate_should_run()
        KG._shutting_down!(false); KG._restarting!(true)
        @test !KG._gate_should_run()
        KG._restarting!(false); KG._running!(false)
        @test !KG._gate_should_run()
        # Dropping the session is the other way to stop being runnable, and it is the one
        # _cleanup uses.
        KG._running!(true)
        KG._SESSION[] = nothing
        @test !KG._gate_should_run()
        # The fault-path backoff returns as soon as the gate is asked to stop.
        KG._SESSION[] = KG.GateSession(; running = true)
        t = @elapsed begin
            @async (sleep(0.1); KG._running!(false))
            KG._sleep_while_running(5.0)
        end
        @test t < 2.0
    finally
        KG._SESSION[] = saved
    end
end

# ── Rebind helper against a real socket (no Kaimon involved) ──────────────────

@testset "_ensure_router! keeps a live socket and rebinds a dead one" begin
    if KG._running() || Sys.iswindows()
        @test_skip true
    else
        saved = (KG._GATE_CONTEXT[], KG._GATE_SOCKET[], KG._SESSION[])
        ctx = ZMQ.Context()
        sid = "test-rebind-$(bytes2hex(rand(UInt8, 4)))"
        path = joinpath(KG.sock_dir(), "$sid.sock")
        try
            KG._GATE_CONTEXT[] = ctx
            # _ensure_router! rebuilds the endpoint from the session's mode and id.
            KG._SESSION[] = KG.GateSession(; running = true, mode = :ipc, id = sid)
            s = KG._zmq_socket(ctx, ZMQ.ROUTER)
            KG._configure_router_socket!(s; curve = false, allow_any = false)
            ZMQ.bind(s, "ipc://$path")
            KG._GATE_SOCKET[] = s

            # Live socket: returned untouched.
            @test KG._ensure_router!(s) === s
            @test KG._GATE_SOCKET[] === s

            # Dead socket (the ENOTSOCK case): rebound on the same endpoint with
            # the same options.
            close(s)
            s2 = @test_logs (:warn, r"rebound") KG._ensure_router!(s)
            @test s2 !== s
            @test isopen(s2)
            @test KG._GATE_SOCKET[] === s2
            @test ispath(path)
            @test s2.rcvtimeo == KG._GATE_RCVTIMEO_IDLE[]
            @test s2.linger == 0

            # A client reaches the rebound endpoint.
            d = ZMQ.Socket(ctx, ZMQ.DEALER)
            d.linger = 0
            ZMQ.connect(d, "ipc://$path")
            ZMQ.send(d, "hello")
            s2.rcvtimeo = 2000
            parts = KG._recv_multipart(s2)
            @test String(parts[end]) == "hello"
            close(d)
            close(s2)
        finally
            KG._GATE_CONTEXT[], KG._GATE_SOCKET[], KG._SESSION[] = saved
            try; close(ctx); catch; end
            rm(path; force = true)
        end
    end
end
