using ReTest
using Kaimon

# Every stripped result must still be valid Julia.
_parses(code) = !(Meta.parseall(code) isa Expr && any(a -> a isa Expr && a.head in (:error, :incomplete), Meta.parseall(code).args))

@testset "Print stripping" begin
    S(code; level = :moderate, quiet = true) = Kaimon.strip_agent_output(code; level, quiet)
    kept(code; kw...) = S(code; kw...) == (code, false)

    @testset "off never modifies code" begin
        @test kept("println(1)"; level = :off)
        @test kept("@show x = 1\n@info \"hi\""; level = :off)
        @test kept("Revise.revise()"; level = :off)
    end

    @testset "moderate: statements the cell runs" begin
        @test S("println(\"a\")\nx = 42") == ("x = 42", true)
        @test S("print(\"a\"); y = 1") == ("nothing; y = 1", true)
        @test S("printstyled(\"x\"; color = :red)\nz = 2") == ("z = 2", true)
        @test S("Base.println(1)\nw = 3") == ("w = 3", true)
        @test S("println(stdout, \"t\")\nx = 1") == ("x = 1", true)
        @test S("for i in 1:3\n    println(i)\nend") == ("for i in 1:3\nend", true)
        @test S("if c\n    print(x)\nend")[2]
        @test S("let x = 1\n    println(x)\n    x\nend") == ("let x = 1\n    x\nend", true)
    end

    @testset "moderate: definitions and arguments are untouched (#94)" begin
        @test kept("greet(name) = println(\"Hello, \", name)")
        @test kept("function f(x)\n    println(x)\n    x^2\nend")
        @test kept("macro m(x)\n    println(x)\nend")
        @test kept("g = x -> println(x)")
        @test kept("map([1, 2]) do x\n    println(x)\nend")
        @test kept("s = sprint(io -> println(io, 1))")
        @test kept("y = println(1)")                    # value position, not a statement
        @test kept("struct P\n    x::Int\nend")
    end

    @testset "moderate: q=false lets output through" begin
        @test kept("println(1)\n@show x\nx"; quiet = false)
        @test S("Revise.revise()\nx"; quiet = false) == ("x", false)
    end

    @testset "high: everywhere, whatever q is" begin
        @test S("greet(name) = println(\"Hello, \", name)"; level = :high) == ("greet(name) = nothing", true)
        @test S("function f(x)\n    println(\"debug\")\n    x^2\nend"; level = :high) ==
              ("function f(x)\n    x^2\nend", true)
        @test S("g = x -> (println(x); x^2)"; level = :high)[2]
        @test S("map([1]) do x; println(x); x^2 end"; level = :high)[2]
        @test S("println(1)\nx"; level = :high, quiet = false) == ("x", true)
        # @show follows q at every level
        @test kept("@show x"; level = :high, quiet = false)
        for code in ("greet(n) = println(n)", "g = x -> (println(x); x^2)",
                     "try println(1); 1/0 catch e println(e) end", "a && println(b)")
            @test _parses(first(S(code; level = :high)))
        end
    end

    @testset "only Base printing, and not when writing to an IO" begin
        for level in (:moderate, :high)
            @test kept("Profile.print(io; format = :flat)"; level)   # #94
            @test kept("sprint(io -> Profile.print(io; format = :flat))"; level)
            @test kept("io = IOBuffer(); println(io, \"hello\")"; level)
            @test kept("print(buf, \"data\")"; level)
            @test kept("printstyled(io, \"x\"; color = :red)"; level)
            @test kept("MyModule.println(1)"; level)
        end
        @test kept("function f(io)\n    println(io, \"data\")\nend"; level = :high)
    end

    @testset "untouched code reaches the REPL as written (#95)" begin
        code = "v = [1, 2, 3]\nt = Threads.@spawn sum(\$v)\nprintln(\"unrelated\")\nfetch(t)"
        @test S(code) == ("v = [1, 2, 3]\nt = Threads.@spawn sum(\$v)\nfetch(t)", true)
        @test S("@btime sum(\$xs)  # timing\nprintln(1)") == ("@btime sum(\$xs)  # timing\n", true)
        @test S("x = 1  # keep this comment\nprintln(x)") == ("x = 1  # keep this comment\n", true)
    end

    @testset "@show keeps evaluating its arguments" begin
        @test S("@show x = 42\ny = x + 1") == ("x = 42\ny = x + 1", true)
        @test S("@show a b") == ("(a; b)", true)
        @test S("Base.@show 1") == ("1", true)
        @test S("function f(x)\n    @show x\n    x^2\nend"; level = :high) ==
              ("function f(x)\n    x\n    x^2\nend", true)
    end

    @testset "logging macros: only the cell's own statements" begin
        @test S("@info \"a\"\n@warn \"b\"\n@error \"c\"\n@debug \"d\"\nx = 1") == ("x = 1", true)
        @test S("begin\n    @info \"a\"\n    x = 1\nend") == ("begin\n    x = 1\nend", true)
        @test kept("try\n    f()\ncatch e\n    @error \"failed\" exception = e\nend")
        @test kept("for i in 1:2\n    @info i\nend")
        @test kept("function f()\n    @warn \"inside\"\nend"; level = :high)
    end

    @testset "Revise.revise() is dropped without a note" begin
        @test S("Revise.revise()\nx = 1") == ("x = 1", false)
        @test S("Main.Revise.revise(); x") == ("nothing; x", false)
    end

    @testset "code that doesn't parse is left for the REPL to report" begin
        @test kept("println(1\nx")
        @test kept("")
    end

    @testset "calls the agent makes are kept" begin
        @test kept("include(\"script.jl\")")
        @test S("println(\"starting\")\nresult = compute(data)\nresult") == ("result = compute(data)\nresult", true)
    end
end

@testset "Print strip level resolution" begin
    saved = get(ENV, "KAIMON_PRINT_STRIP", nothing)
    try
        ENV["KAIMON_PRINT_STRIP"] = "high"
        @test Kaimon.print_strip_level() === :high
        ENV["KAIMON_PRINT_STRIP"] = " OFF "
        @test Kaimon.print_strip_level() === :off
        ENV["KAIMON_PRINT_STRIP"] = "loud"
        @test Kaimon.print_strip_level() === :moderate
        delete!(ENV, "KAIMON_PRINT_STRIP")
        @test Kaimon.print_strip_level() === Kaimon.get_print_strip_preference()
        @test_throws ArgumentError Kaimon.set_print_strip_preference!(:loud)
    finally
        saved === nothing ? delete!(ENV, "KAIMON_PRINT_STRIP") : (ENV["KAIMON_PRINT_STRIP"] = saved)
    end
end
