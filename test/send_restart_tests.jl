using ReTest
using Kaimon
using Serialization

# ── send_restart! on stalled sessions ────────────────────────────────────────
# Regression: send_restart! rejected connections whose status was :stalled,
# so manage_repl restart — the lightweight remedy for a wedged session —
# refused exactly the sessions that needed it, forcing the heavier shutdown
# + re-spawn path. Sibling request paths (e.g. :cancel_job) already accepted
# :stalled; this brings send_restart! in line.

@testset "send_restart! accepts stalled sessions" begin
    conn = Kaimon.REPLConnection(session_id = "restart01", name = "julia")
    rc = Kaimon.RequestChannel(
        Kaimon.ZMQ.Socket(Kaimon.ZMQ.DEALER),      # never touched by the fake responder
        "ipc:///kaimon-test-unused",
        Channel{Tuple{UInt64, Vector{UInt8}}}(8),
        Dict{UInt64, Channel{Any}}(),
        ReentrantLock(),
        Threads.Atomic{UInt64}(0),
        nothing, nothing,
        Ref(true),
        nothing,
        ReentrantLock(),
        Threads.Event(true), Threads.Event(true))
    conn.req_channel = rc

    # Fake gate: drain send_q, answer every correlated request with (type=:ok)
    responder = Threads.@spawn begin
        while isopen(rc.send_q)
            corr_id, _payload = try
                take!(rc.send_q)
            catch
                break
            end
            io = IOBuffer()
            serialize(io, (type = :ok,))
            lock(rc.pending_lock) do
                haskey(rc.pending, corr_id) && put!(rc.pending[corr_id], take!(io))
            end
        end
    end

    try
        # THE regression: :stalled used to be rejected outright.
        conn.status = :stalled
        @test Kaimon.send_restart!(conn) == true

        # A disconnected session is still refused.
        conn.status = :disconnected
        @test Kaimon.send_restart!(conn) == false
    finally
        close(rc.send_q)
        wait(responder)
    end
end
