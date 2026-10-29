using Test
using KaimonGate
using REPL

# ─────────────────────────────────────────────────────────────────────────────
# Regression: mt=true evals lost :gate_request_id across REPL.call_on_backend.
#
# call_on_backend ships the eval closure to the REPL backend task, whose
# task-local storage is separate from the async-eval task where
# :gate_request_id was set. Inside an mt=true eval, is_cancelled(), stash()
# and progress() then read an empty request id and silently no-op —
# cancellation never reached cooperative loops, stashes and progress events
# went nowhere.
#
# The fake backend below mirrors the real REPL wire format: the interactive
# loop receives `(f, 2)` (REPL.exchange_on_backend) and calls f() ITSELF —
# i.e. on a task that does NOT hold the caller's task-locals. That is the
# exact property the fix has to defeat by re-scoping the request id.
# ─────────────────────────────────────────────────────────────────────────────

function fake_repl_backend()
    repl_channel = Channel{Any}(32)
    response_channel = Channel{Any}(32)
    task = Threads.@spawn begin
        while isopen(repl_channel)
            request = try
                take!(repl_channel)
            catch
                break
            end
            ast_or_func, show_value = request
            show_value == -1 && break   # exit flag, same as the real backend loop
            if show_value == 2          # 2 indicates a function to be called
                ret = try
                    ast_or_func()
                catch
                    nothing
                end
                put!(response_channel, Pair{Any, Bool}(ret, false))
            end
        end
    end
    return (repl_channel = repl_channel, response_channel = response_channel, task = task)
end

@testset ":gate_request_id forwarded through call_on_backend" begin
    fb = fake_repl_backend()
    backend = REPL.REPLBackendRef(fb.repl_channel, fb.response_channel)
    # Base.active_repl is declared-but-unassigned until a real REPL starts;
    # gate_eval guards with isdefined, so mirror that here.
    had_repl = isdefined(Base, :active_repl)
    old_repl = had_repl ? Base.active_repl : nothing
    # gate_eval detects the REPL via Base.active_repl + a .backendref property.
    Base.active_repl = (backendref = backend,)
    try
        # Evaluated in Main by _eval_with_capture, so KaimonGate must be
        # reachable from Main, not just from this test module.
        @eval Main using KaimonGate

        rid = "mt-fwd-test-rid"

        # gate_eval must run on the :interactive pool to route through
        # call_on_backend — the same routing mt=true evals take in production.
        # The caller (this spawned task) holds :gate_request_id, exactly like
        # Kaimon's _do_async_eval before calling gate_eval.
        result = fetch(Threads.@spawn :interactive begin
            task_local_storage(:gate_request_id, rid) do
                KaimonGate.gate_eval("KaimonGate.is_cancelled()")
            end
        end)
        @test result.value_repr == "false"   # job id seen, not yet cancelled

        KaimonGate.cancel_job!(rid)
        result2 = fetch(Threads.@spawn :interactive begin
            task_local_storage(:gate_request_id, rid) do
                KaimonGate.gate_eval("KaimonGate.is_cancelled()")
            end
        end)
        # THE regression: with the bug the backend task read an empty request
        # id and this returned "false" even though the job was cancelled.
        @test result2.value_repr == "true"

        # stash() binds to the same id from inside an mt eval (safehouse is
        # keyed by the request id read through the forwarded task-local).
        fetch(Threads.@spawn :interactive begin
            task_local_storage(:gate_request_id, rid) do
                KaimonGate.gate_eval("KaimonGate.stash(\"k\", 42)")
            end
        end)
        @test KaimonGate.get_stash(rid)["k"] == 42

        # Output attribution: _eval_with_capture tags captured (and published)
        # output with the request id read from the SAME task-local. Without the
        # forwarding, live output from an mt=true eval was attributed to no
        # request. Assert both the sink's id and that the line was captured.
        result3 = fetch(Threads.@spawn :interactive begin
            task_local_storage(:gate_request_id, rid) do
                KaimonGate.gate_eval("println(\"attributed line\"); KaimonGate._current_sink().request_id")
            end
        end)
        @test result3.value_repr == "\"$rid\""
        @test occursin("attributed line", result3.stdout)
    finally
        Base.active_repl = had_repl ? old_repl : nothing
        put!(fb.repl_channel, (nothing, -1))
        wait(fb.task)
    end
end
