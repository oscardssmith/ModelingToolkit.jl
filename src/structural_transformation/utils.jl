###
### Bipartite graph utilities
###

"""
    maximal_matching(s::SystemStructure, eqfilter=eq->true, varfilter=v->true) -> Matching

Find equation-variable maximal bipartite matching. `s.graph` is a bipartite graph.
"""
BipartiteGraphs.maximal_matching(s::SystemStructure, eqfilter=eq->true, varfilter=v->true) =
    maximal_matching(s.graph, eqfilter, varfilter)

function error_reporting(state, bad_idxs, n_highest_vars, iseqs)
    io = IOBuffer()
    if iseqs
        error_title = "More equations than variables, here are the potential extra equation(s):\n"
        out_arr = equations(state)[bad_idxs]
    else
        error_title = "More variables than equations, here are the potential extra variable(s):\n"
        out_arr = state.fullvars[bad_idxs]
    end

    Base.print_array(io, out_arr)
    msg = String(take!(io))
    neqs = length(equations(state))
    if iseqs
        throw(ExtraEquationsSystemException(
            "The system is unbalanced. "
            * "There are $n_highest_vars highest order derivative variables "
            * "and $neqs equations.\n"
            * error_title
            * msg
        ))
    else
        throw(ExtraVariablesSystemException(
            "The system is unbalanced. "
            * "There are $n_highest_vars highest order derivative variables "
            * "and $neqs equations.\n"
            * error_title
            * msg
        ))
    end
end

###
### Structural check
###
function check_consistency(state::TearingState)
    fullvars = state.fullvars
    @unpack graph, var_to_diff = state.structure
    n_highest_vars = count(v->length(outneighbors(var_to_diff, v)) == 0, vertices(var_to_diff))
    neqs = nsrcs(graph)
    is_balanced = n_highest_vars == neqs

    if neqs > 0 && !is_balanced
        varwhitelist = var_to_diff .== nothing
        var_eq_matching = maximal_matching(graph, eq->true, v->varwhitelist[v]) # not assigned
        # Just use `error_reporting` to do conditional
        iseqs = n_highest_vars < neqs
        if iseqs
            eq_var_matching = invview(complete(var_eq_matching)) # extra equations
            bad_idxs = findall(isnothing, @view eq_var_matching[1:nsrcs(graph)])
        else
            bad_idxs = findall(isequal(unassigned), var_eq_matching)
        end
        error_reporting(state, bad_idxs, n_highest_vars, iseqs)
    end

    # This is defined to check if Pantelides algorithm terminates. For more
    # details, check the equation (15) of the original paper.
    extended_graph = (@set graph.fadjlist = Vector{Int}[graph.fadjlist; map(collect, edges(var_to_diff))])
    extended_var_eq_matching = maximal_matching(extended_graph)

    unassigned_var = []
    for (vj, eq) in enumerate(extended_var_eq_matching)
        if eq === unassigned
            push!(unassigned_var, fullvars[vj])
        end
    end

    if !isempty(unassigned_var) || !is_balanced
        io = IOBuffer()
        Base.print_array(io, unassigned_var)
        unassigned_var_str = String(take!(io))
        errmsg = "The system is structurally singular! " *
                 "Here are the problematic variables: \n" *
                 unassigned_var_str
        throw(InvalidSystemException(errmsg))
    end

    return nothing
end

###
### BLT ordering
###

"""
    find_var_sccs(g::BipartiteGraph, assign=nothing)

Find strongly connected components of the variables defined by `g`. `assign`
gives the undirected bipartite graph a direction. When `assign === nothing`, we
assume that the ``i``-th variable is assigned to the ``i``-th equation.
"""
function find_var_sccs(g::BipartiteGraph, assign=nothing)
    cmog = DiCMOBiGraph{true}(g, Matching(assign === nothing ? Base.OneTo(nsrcs(g)) : assign))
    sccs = Graphs.strongly_connected_components(cmog)
    foreach(sort!, sccs)
    return sccs
end

function sorted_incidence_matrix(sys, val=true; only_algeqs=false, only_algvars=false)
    var_eq_matching, var_scc = algebraic_variables_scc(sys)
    s = structure(sys)
    @unpack fullvars, graph = s
    g = graph
    varsmap = zeros(Int, ndsts(graph))
    eqsmap = zeros(Int, nsrcs(graph))
    varidx = 0
    eqidx = 0
    for vs in scc, v in vs
        eq = var_eq_matching[v]
        if eq !== unassigned
            eqsmap[eq] = (eqidx += 1)
            varsmap[var] = (varidx += 1)
        end
    end
    for i in diffvars_range(s)
        varsmap[i] = (varidx += 1)
    end
    for i in dervars_range(s)
        varsmap[i] = (varidx += 1)
    end
    for i in 1:nsrcs(graph)
        if eqsmap[i] == 0
            eqsmap[i] = (eqidx += 1)
        end
    end

    I = Int[]
    J = Int[]
    for eq in 𝑠vertices(g)
        only_algeqs && (isalgeq(s, eq) || continue)
        for var in 𝑠neighbors(g, eq)
            only_algvars && (isalgvar(s, var) || continue)
            i = eqsmap[eq]
            j = varsmap[var]
            (iszero(i) || iszero(j)) && continue
            push!(I, i)
            push!(J, j)
        end
    end
    #sparse(I, J, val, nsrcs(g), ndsts(g))
    sparse(I, J, val)
end

###
### Structural and symbolic utilities
###

function find_eq_solvables!(state::TearingState, ieq; may_be_zero=false, allow_symbolic=false)
    fullvars = state.fullvars
    @unpack graph, solvable_graph = state.structure
    eq = equations(state)[ieq]
    term = value(eq.rhs - eq.lhs)
    to_rm = Int[]
    for j in 𝑠neighbors(graph, ieq)
        var = fullvars[j]
        isinput(var) && continue
        a, b, islinear = linear_expansion(term, var)
        a = unwrap(a)
        islinear || continue
        if a isa Symbolic
            allow_symbolic || continue
            add_edge!(solvable_graph, ieq, j)
            continue
        end
        (a isa Number) || continue
        if a != 0
            add_edge!(solvable_graph, ieq, j)
        else
            if may_be_zero
                push!(to_rm, j)
            else
                @warn "Internal error: Variable $var was marked as being in $eq, but was actually zero"
            end
        end
    end
    for j in to_rm
        rem_edge!(graph, ieq, j)
    end
end

function find_solvables!(state::TearingState; allow_symbolic=false)
    @assert state.structure.solvable_graph === nothing
    eqs = equations(state)
    graph = state.structure.graph
    state.structure.solvable_graph = BipartiteGraph(nsrcs(graph), ndsts(graph))
    for ieq in 1:length(eqs)
        find_eq_solvables!(state, ieq; allow_symbolic)
    end
    return nothing
end

# debugging use
function reordered_matrix(sys, torn_matching)
    s = TearingState(sys)
    complete!(s.structure)
    @unpack graph = s.structure
    eqs = equations(sys)
    nvars = ndsts(graph)
    max_matching = complete(maximal_matching(graph))
    torn_matching = complete(torn_matching)
    sccs = find_var_sccs(graph, max_matching)
    I, J = Int[], Int[]
    ii = 0
    M = Int[]
    solved = BitSet(findall(torn_matching .!== unassigned))
    for vars in sccs
        append!(M, filter(in(solved), vars))
        append!(M, filter(!in(solved), vars))
    end
    M = invperm(vcat(M, setdiff(1:nvars, M)))
    for vars in sccs
        e_solved = [torn_matching[v] for v in vars if torn_matching[v] !== unassigned]
        for es in e_solved
            isdiffeq(eqs[es]) && continue
            ii += 1
            js = [M[x] for x in 𝑠neighbors(graph, es) if isalgvar(s.structure, x)]
            append!(I, fill(ii, length(js)))
            append!(J, js)
        end

        e_residual = setdiff([max_matching[v] for v in vars if max_matching[v] !== unassigned], e_solved)
        for er in e_residual
            isdiffeq(eqs[er]) && continue
            ii += 1
            js = [M[x] for x in 𝑠neighbors(graph, er) if isalgvar(s.structure, x)]
            append!(I, fill(ii, length(js)))
            append!(J, js)
        end
    end
    # only plot algebraic variables and equations
    sparse(I, J, true)
end

"""
    uneven_invmap(n::Int, list)

returns an uneven inv map with length `n`.
"""
function uneven_invmap(n::Int, list)
    rename = zeros(Int, n)
    for (i, v) in enumerate(list)
        rename[v] = i
    end
    return rename
end

function torn_system_jacobian_sparsity(sys)
    state = get_tearing_state(sys)
    state isa TearingState || return nothing
    s = structure(sys)
    graph = state.structure.graph
    fullvars = state.fullvars

    states_idxs = findall(!isdifferential, fullvars)
    var2idx = Dict{Int,Int}(v => i for (i, v) in enumerate(states_idxs))
    I = Int[]; J = Int[]
    for ieq in 𝑠vertices(graph)
        for ivar in 𝑠neighbors(graph, ieq)
            nivar = get(var2idx, ivar, 0)
            nivar == 0 && continue
            push!(I, ieq)
            push!(J, nivar)
        end
    end
    return sparse(I, J, true)
end

###
### Nonlinear equation(s) solving
###

@noinline nlsolve_failure(rc) = error("The nonlinear solver failed with the return code $rc.")

function numerical_nlsolve(f, u0, p)
    prob = NonlinearProblem{false}(f, u0, p)
    sol = solve(prob, NewtonRaphson())
    rc = sol.retcode
    rc === :DEFAULT || nlsolve_failure(rc)
    # TODO: robust initial guess, better debugging info, and residual check
    sol.u
end
