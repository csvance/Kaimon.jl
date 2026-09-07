using Test
using KaimonGate

# `_source_docstring` reads a tool's docstring back out of its source file by
# stripping the `"""` delimiters. Those are ASCII, but the content next to them
# need not be — a character-counting strip keeps a multi-byte character adjacent
# to the closing delimiter from silently blanking the description.
@testset "Source docstring extraction" begin
    mktempdir() do dir
        path = joinpath(dir, "tools.jl")

        # Each function is preceded by a docstring in one of the three shapes the
        # extractor handles, with a multi-byte character hard against the closer.
        write(path, """
        \"\"\"Run the thing — fast\"\"\"
        one_line() = nothing

        \"\"\"
        Multi line, closing content ends in an em dash —\"\"\"
        content_before_close() = nothing

        \"\"\"
        Plain block with a — dash inside
        \"\"\"
        lone_delimiter() = nothing

        \"\"\"Plain ASCII single line\"\"\"
        ascii_one_line() = nothing
        """)

        mod = Module(:DocFixture)
        Base.include(mod, path)

        doc(name) = KaimonGate._source_docstring(getfield(mod, name))

        # The regression: each of these threw StringIndexError internally, and the
        # extractor's catch-all turned that into a silently empty description.
        @test doc(:one_line) == "Run the thing — fast"
        @test doc(:content_before_close) ==
              "Multi line, closing content ends in an em dash —"
        @test doc(:lone_delimiter) == "Plain block with a — dash inside"
        @test doc(:ascii_one_line) == "Plain ASCII single line"

        # None of them may come back blank — that was the failure mode.
        for name in (:one_line, :content_before_close, :lone_delimiter, :ascii_one_line)
            @test !isempty(doc(name))
        end
    end
end

# A client reflects every tool on every heartbeat ping, and reflecting one tool reads the whole file
# that defines it. Tools are declared together, so uncached this reads one file once per tool,
# forever, on a gate doing nothing.
@testset "Source docstring caching" begin
    mktempdir() do dir
        path = joinpath(dir, "many.jl")
        names = [Symbol("tool_$i") for i in 1:8]
        write(path, join(["\"\"\"Doc for $n\"\"\"\n$n() = nothing\n" for n in names], "\n"))

        mod = Module(:CacheFixture)
        Base.include(mod, path)
        fns = [getfield(mod, n) for n in names]

        # The cold pass reads the file ONCE, not once per tool: eight tools, one line-cache entry.
        KaimonGate._clear_source_cache!()
        docs = [KaimonGate._source_docstring(f) for f in fns]
        @test docs == ["Doc for $n" for n in names]
        @test length(KaimonGate._SRC_CACHE) == 1
        @test length(KaimonGate._DOC_CACHE) == length(names)

        # A warm gate reads nothing at all. Emptying only the LINE cache and reflecting again leaves
        # it empty, which it could not do if any tool had gone back to the file.
        lock(KaimonGate._SRC_LOCK) do; empty!(KaimonGate._SRC_CACHE); end
        @test [KaimonGate._source_docstring(f) for f in fns] == docs
        @test isempty(KaimonGate._SRC_CACHE)

        # ...but an edit must still be visible, because these files are edited live under Revise.
        # Same path and the SAME LENGTH, so the mtime is the only thing that can catch it.
        write(path, join(["\"\"\"Edt for $n\"\"\"\n$n() = nothing\n" for n in names], "\n"))
        @test KaimonGate._source_docstring(first(fns)) == "Edt for $(first(names))"
    end
end

# The docstring is only part of what a ping recomputes per tool; the argument schema is the rest.
@testset "Reflection caching" begin
    mktempdir() do dir
        path = joinpath(dir, "reflected.jl")
        # A closure factory, which is the pattern `_source_docstring` exists for: the inner function
        # has no module-level binding, so its description can only come from the file.
        fixture(doc) = """
        function make_greet()
            \"\"\"$doc\"\"\"
            function greet(name::String; loud::Bool = false)
                name
            end
        end
        """
        write(path, fixture("Greet somebody"))
        mod = Module(:ReflectFixture)
        Base.include(mod, path)
        # `invokelatest` around the whole access: the factory is newer than this scope's world.
        tool = KaimonGate.GateTool("greet", Base.invokelatest(() -> getfield(mod, :make_greet)()))

        KaimonGate._clear_source_cache!()
        first_pass = KaimonGate._reflect_tool(tool)
        @test first_pass["description"] == "Greet somebody"
        @test Set(a["name"] for a in first_pass["arguments"]) == Set(["name", "loud"])
        @test length(KaimonGate._REFLECT_CACHE) == 1
        @test KaimonGate._reflect_tool(tool) == first_pass       # the cached answer is the same answer

        # The caller owns its copy: adding to one result must not reach the next one.
        first_pass["injected"] = true
        @test !haskey(KaimonGate._reflect_tool(tool), "injected")

        # An edit to the defining file re-reflects rather than serving the old schema. Same line
        # layout, so the handler's recorded line still points at its own definition.
        write(path, fixture("Greet somebody loudly"))
        @test KaimonGate._reflect_tool(tool)["description"] == "Greet somebody loudly"

        # The superseded entry is dropped rather than kept alongside the new one. Each edit and
        # each re-registration produces a fresh key, so without this the cache would gain an
        # entry per reload for the life of the process.
        @test length(KaimonGate._REFLECT_CACHE) == 1
    end
end
