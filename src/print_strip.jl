# ── Print stripping: remove agent "chatter" from submitted code ───────────────
#
# Agents given a REPL tend to narrate through it: println/@show/@info calls whose only
# purpose is to talk to the user, which floods the mirrored terminal and the agent's own
# token budget. This removes those calls from the code an agent submits, at a level the
# user chooses:
#
#   :off       nothing is modified.
#   :moderate  with q=true only: calls the cell itself executes, in statement position,
#              outside any definition. Function/macro/lambda/do bodies, struct and quote
#              contents, and call arguments are left alone. With q=false nothing is removed.
#   :high      print calls everywhere, including inside definitions and call arguments,
#              whatever q is; @show with q=true.
#
# At every level only Base's print/println/printstyled are candidates (unqualified or
# `Base.`-qualified): `Profile.print(io; …)` is a different function. A call whose first of
# two or more positional arguments is an IO variable is writing to that IO and is kept.
# Logging macros (@info/@warn/@error/@debug) are only removed as the cell's own top-level
# statements, because inside a try/catch or a loop they are usually real error reporting.
# Redundant `Revise.revise()` calls are removed at both levels regardless of q. A removed
# `@show` is replaced by its arguments, which still run.
#
# Removal works on the SOURCE TEXT, by byte range from Base's JuliaSyntax parse, so
# everything that isn't removed reaches the REPL exactly as written (a re-serialized AST
# mangles `$` interpolation inside macros, among other things). Calls and macros are
# identified from the source text of their callee or name, confirmed on the node's `Expr`;
# the tree's kind names are only used for structure, since they differ between Julia
# versions (see rename_symbol.jl).

const PRINT_STRIP_LEVELS = (:off, :moderate, :high)

const _PRINT_FUNCS = (:println, :print, :printstyled)
const _LOG_MACROS = (Symbol("@info"), Symbol("@warn"), Symbol("@error"), Symbol("@debug"))

# Kinds looked up by name so one a given Julia lacks is simply absent (see _js_kind).
_kinds(names...) = Tuple(k for k in map(_js_kind, names) if k !== nothing)
const _K_STMT_PARENT = _kinds("toplevel", "block")
const _K_DEFINITION = _kinds("function", "macro", "->", "do", "struct", "quote", "module")
const _K_CALL = _js_kind("call")
const _K_MACROCALL = _js_kind("macrocall")

"""
    print_strip_level() -> Symbol

The configured level: `KAIMON_PRINT_STRIP` env var, else the Config-tab preference, else
`:moderate`. An unrecognised value falls back to `:moderate`.
"""
function print_strip_level()::Symbol
    env = lowercase(strip(get(ENV, "KAIMON_PRINT_STRIP", "")))
    isempty(env) || return _parse_strip_level(env)
    return get_print_strip_preference()
end

_parse_strip_level(s) = (lv = Symbol(lowercase(strip(String(s))))) in PRINT_STRIP_LEVELS ? lv : :moderate

# `print`/`println`/`printstyled`, unqualified or `Base.`-qualified.
function _base_print_name(callee)
    callee isa Symbol && return callee in _PRINT_FUNCS ? callee : nothing
    if callee isa Expr && callee.head === :. && length(callee.args) == 2 &&
       callee.args[1] === :Base && callee.args[2] isa QuoteNode &&
       callee.args[2].value in _PRINT_FUNCS
        return callee.args[2].value
    end
    return nothing
end

_is_std_stream(x) = x in (:stdout, :stderr) ||
    (x isa Expr && x.head === :. && length(x.args) == 2 && x.args[1] === :Base &&
     x.args[2] isa QuoteNode && x.args[2].value in (:stdout, :stderr))

# A Base print call that writes to stdout (not to an IO argument).
function _is_stdout_print(ex::Expr)
    ex.head === :call || return false
    _base_print_name(ex.args[1]) === nothing && return false
    pos = [a for a in ex.args[2:end] if !(a isa Expr && a.head in (:kw, :parameters))]
    io_targeted = length(pos) >= 2 && pos[1] isa Symbol && !_is_std_stream(pos[1])
    return !io_targeted
end

"""Match a `Revise.revise()` / `Main.Revise.revise()` call (by callee; args ignored). The
gate replays Revise's `revise_first` ast-transform before every eval, so an explicit call
is always a redundant no-op."""
function _is_revise_revise_call(func)
    (func isa Expr && func.head == :. && length(func.args) >= 2) || return false
    (func.args[end] isa QuoteNode && func.args[end].value == :revise) || return false
    base = func.args[1]
    base === :Revise && return true
    return base isa Expr && base.head == :. && length(base.args) >= 2 &&
           base.args[end] isa QuoteNode && base.args[end].value == :Revise
end

_node_expr(node) = try Expr(node) catch; nothing end

# Source text of a node's first child: a call's callee (`println`, `Base.println`) or a
# macro's name (`info` on 1.12, `@info` on 1.13, `Base.@info`).
function _head_text(node, cu)
    kids = _JS.children(node)
    (kids === nothing || isempty(kids)) && return ""
    return strip(String(view(cu, _JS.byte_range(first(kids)))))
end

const _PRINT_HEADS = Set(vcat(String.(collect(_PRINT_FUNCS)), ["Base.$f" for f in _PRINT_FUNCS]))
const _LOG_NAMES = Set(chop(String(m); head = 1, tail = 0) for m in _LOG_MACROS)

# What (if anything) this node is, as a candidate for removal. The callee text is a cheap
# filter; only a likely match is converted to an `Expr` (which copies the whole subtree)
# to confirm it.
function _strip_class(node, cu)
    k = _JS.kind(node)
    if k === _K_CALL
        head = _head_text(node, cu)
        if endswith(head, "Revise.revise")
            ex = _node_expr(node)
            ex isa Expr && _is_revise_revise_call(ex.args[1]) && return :revise
        elseif head in _PRINT_HEADS
            ex = _node_expr(node)
            ex isa Expr && _is_stdout_print(ex) && return :print
        end
    elseif k === _K_MACROCALL
        name = lstrip(last(split(_head_text(node, cu), '.')), '@')
        name == "show" && return :show
        name in _LOG_NAMES && return :log
    end
    return nothing
end

# `@show a b` keeps evaluating its arguments (`@show x = 42` must still assign `x`), so
# it is replaced by their source rather than removed. The first child is the macro name.
function _show_replacement(node, cu)
    args = something(_JS.children(node), [])[2:end]
    isempty(args) && return nothing
    texts = [String(strip(String(view(cu, _JS.byte_range(a))))) for a in args]
    return length(texts) == 1 ? texts[1] : "(" * join(texts, "; ") * ")"
end

# Walk the tree collecting byte ranges to remove, each with the text to put in its place
# (`nothing` = remove). `stmt`: the node is a statement of its parent block. `top`: every
# ancestor is the cell itself or a plain block. `in_def`: inside a definition's body.
function _collect_strips!(out, node, cu, level::Symbol, quiet::Bool; stmt::Bool, top::Bool, in_def::Bool)
    cls = _strip_class(node, cu)
    if cls !== nothing
        remove = if cls === :revise
            true
        elseif cls === :log
            top
        elseif level === :high
            cls === :print || quiet
        else  # :moderate
            quiet && stmt && !in_def
        end
        if remove
            repl = cls === :show ? _show_replacement(node, cu) : nothing
            push!(out, (range = _JS.byte_range(node), stmt = stmt, repl = repl, output = cls !== :revise))
            return out
        end
    end
    kids = _JS.children(node)
    kids === nothing && return out
    k = _JS.kind(node)
    child_stmt = k in _K_STMT_PARENT
    child_top = top && child_stmt
    child_def = in_def || k in _K_DEFINITION
    for c in kids
        _collect_strips!(out, c, cu, level, quiet; stmt = child_stmt, top = child_top, in_def = child_def)
    end
    return out
end

# Widen a statement's range to its whole line(s) when nothing else shares them, so the
# mirrored code doesn't keep a blank or `nothing` line where the call was.
function _line_span(cu, r::UnitRange{Int})
    a, b = first(r), last(r)
    i = a - 1
    while i >= 1 && cu[i] in (UInt8(' '), UInt8('\t')); i -= 1; end
    (i == 0 || cu[i] == UInt8('\n')) || return nothing
    j = b + 1
    while j <= length(cu) && cu[j] in (UInt8(' '), UInt8('\t'), UInt8(';')); j += 1; end
    j > length(cu) && return (i + 1):length(cu)
    cu[j] == UInt8('\n') || return nothing
    return (i + 1):j
end

"""
    strip_agent_output(code; level=print_strip_level(), quiet=true) -> (code::String, stripped::Bool)

Remove agent chatter from `code` according to `level` (see the notes at the top of this
file). Returns the code with only the removed calls cut out, and whether any output call
was among them.
Code that doesn't parse is returned unchanged, so the REPL reports the real syntax error.
"""
function strip_agent_output(code::AbstractString; level::Symbol = print_strip_level(), quiet::Bool = true)
    src = String(code)
    level === :off && return (src, false)
    tree = try
        _JS.parseall(_JS.SyntaxNode, src)
    catch
        return (src, false)
    end
    cu = codeunits(src)
    hits = _collect_strips!(
        NamedTuple{(:range, :stmt, :repl, :output),Tuple{UnitRange{Int},Bool,Union{Nothing,String},Bool}}[],
        tree, cu, level, quiet; stmt = false, top = true, in_def = false)
    isempty(hits) && return (src, false)

    io = IOBuffer()
    prev = 1
    for h in hits
        span = (h.repl === nothing && h.stmt) ? _line_span(cu, h.range) : nothing
        cut = something(span, h.range)
        first(cut) < prev && continue
        write(io, view(cu, prev:(first(cut) - 1)))
        # A whole-line statement just disappears. Anything sharing its line, and any call in
        # argument position (`:high` only), becomes `nothing` so the code stays valid.
        span === nothing && write(io, something(h.repl, "nothing"))
        prev = last(cut) + 1
    end
    write(io, view(cu, prev:length(cu)))
    # A dropped `Revise.revise()` isn't output, so it alone doesn't earn the agent a note.
    return (String(take!(io)), any(h -> h.output, hits))
end

"""The note appended to a result when calls were removed, worded for the active level."""
function print_strip_note(level::Symbol = print_strip_level())
    return level === :high ?
        "⚠️  Note: println/print/logging calls were removed. Use q=false with a final expression to see values." :
        "⚠️  Note: println/print/@show/logging calls in this cell were removed because q=true. Use q=false to keep them, or end the cell with the value you want."
end
