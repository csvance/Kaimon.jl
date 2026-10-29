# FtsIndex and Database load SQLite on first use, so a task whose world predates that
# load (the startup coverage sync, an indexing job) must still reach SQLite's methods.
# That needs a process where SQLite isn't loaded yet, so this runs in a fresh subprocess.

using ReTest
using Kaimon

@testset "SQLite ops from a world older than the SQLite load" begin
    script = """
    using Kaimon
    const F = Kaimon.FtsIndex
    const D = Kaimon.Database
    function fts_ops(path)
        F.init!(path)
        F.add_chunks!([(point_id = "p1", collection = "c", file = "/x.jl", name = "f",
                        type = "function", start_line = 1, end_line = 2, text = "hello world")])
        r = (files = F.distinct_files("c"), total = F.coverage().total,
             hits = length(F.search("hello"; collection = "c").word))
        F.delete_file!("c", "/x.jl")
        F.clear_collection!("c")
        F.close!()
        r
    end
    function db_ops(path)
        D.init_db!(path)
        D.persist_job!("job-1", "sess", "1 + 1", 1.0, 2.0)
        D.update_job!("job-1"; status = "completed")
        job = D.get_job("job-1")
        D.close_db!()
        job === nothing ? "missing" : job["status"]
    end
    loaded = any(m -> nameof(m) == :SQLite, values(Base.loaded_modules))
    w = Base.get_world_counter()
    r = Base.invoke_in_world(w, fts_ops, joinpath(mktempdir(), "fts.db"))
    s = Base.invoke_in_world(w, db_ops, joinpath(mktempdir(), "kaimon.db"))
    print(loaded, " ", r.files == ["/x.jl"], " ", r.total, " ", r.hits, " ", s)
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(Kaimon)) -e $script`
    out = read(pipeline(ignorestatus(cmd); stderr = devnull), String)
    @test out == "false true 1 1 completed"
end
