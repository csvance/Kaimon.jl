# Headless terminal handling.
#
# A headless server backgrounded from a shell (`kaimon --headless >>log 2>&1 &`) still has the
# terminal on stdin. Reading it, or putting it in raw mode, raises SIGTTIN/SIGTTOU on a
# background process group and stops every process in it — the port stays bound while nothing
# is left to accept on it, so the server looks alive and answers nothing.
#
# The process-group stop itself needs a pty and a job-control shell, so it is not reproducible
# here. What is testable is the decision that keeps us off the terminal, and the signal
# disposition that turns a stray access into an error instead of a stop.

using ReTest
using Kaimon

@testset "headless never touches a terminal it does not own" begin
    # The suite's own stdin is a pipe, i.e. exactly the shape `</dev/null` or a launcher
    # pipe produces: no terminal to read, so no terminal access.
    @test Kaimon._stdin_is_foreground_tty() == false
    @test Kaimon._stdin_is_foreground_tty() isa Bool   # never throws, whatever fd 0 is

    # With no readable terminal the quit-key wait must park rather than read or raise.
    t = @async Kaimon._wait_for_quit_key()
    @test timedwait(() -> istaskdone(t), 0.5) == :timed_out   # still parked
    @test !istaskfailed(t)

    # …and the startup banner must not advertise a key that cannot be pressed.
    hint = Kaimon._headless_shutdown_hint()
    @test occursin("SIGTERM", hint)
    @test occursin(string(getpid()), hint)
    @test !occursin("Ctrl-Q", hint)
end

@testset "headless ignores the terminal stop signals" begin
    if Sys.iswindows()
        # No signals, no process groups, no controlling terminal — nothing to disarm.
        @test Kaimon._ignore_terminal_stop_signals!() === nothing
    else
        sig_ign, sig_dfl = Ptr{Cvoid}(1), Ptr{Cvoid}(0)
        prev = [ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), s, sig_dfl)
                for s in (Kaimon._SIGTTIN, Kaimon._SIGTTOU)]
        try
            Kaimon._ignore_terminal_stop_signals!()
            # `signal` hands back the disposition it replaced, so re-setting reveals what
            # was installed. A bogus signal number would return SIG_ERR (-1) instead, so
            # this also pins 21/22 to real signals on this platform.
            for s in (Kaimon._SIGTTIN, Kaimon._SIGTTOU)
                @test ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), s, sig_ign) == sig_ign
            end
        finally
            for (s, p) in zip((Kaimon._SIGTTIN, Kaimon._SIGTTOU), prev)
                ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), s, p)
            end
        end
    end
end
