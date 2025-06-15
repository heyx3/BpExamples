"
Executes some rules/inner sequences on a grid, according to some logic.

Works much like an iterator (`start_sequence()` returns some state,
    while `execute_sequence()` takes that state and returns the next one).
"
abstract type AbstractSequence end
"Returns the state used for the first iteration of the sequence."
start_sequence(  seq::AbstractSequence, grid::CellGrid, prng       )::Any           = error("Unimplemented: ", typeof(seq))
"Executes the given iteration of the sequence and returns the next iteration (or `nothing` if finished)"
execute_sequence(seq::AbstractSequence, grid::CellGrid, prng, state)::Optional{Any} = error("Unimplemented: ", typeof(seq))

#TODO: Pool RuleCache instances by their # of rules

"Executes a set of rules exactly N times"
struct Sequence_DoN <: AbstractSequence
    rules::Vector{CellRule}
    count::Int
end
start_sequence(d::Sequence_DoN, grid::CellGrid{N}, rng::PRNG) where {N} = (1, RuleCache(grid, d.rules))
function execute_sequence(d::Sequence_DoN, grid::CellGrid{N}, rng::PRNG,
                          (next_i, cache)::Tuple{Int, RuleCache{N}}
                         ) where {N}
    if SKIP_CACHE
        if (next_i > d.count)
            return nothing
        end
        options = Vector{Pair{Int32, CellLine{N}}}()
        find_rule_matches(grid, d.rules) do (i, c)
            push!(options, i => c)
        end
        if isempty(options)
            return nothing
        end
        option = rand(rng, options)
        rule_execute!(grid, d.rules[option[1]], option[2])
        return (next_i + 1, cache)
    end

    n_options = n_cached_rule_applications(cache)
    if (n_options < 1) || (next_i > d.count)
        return nothing
    else
        application = get_cached_rule_application(
            cache,
            rand(rng, 1:n_options)
        )
        rule = d.rules[application.rule_idx]

        @markovjunior_assert rule_applies(grid, rule, application.at) application.at

        rule_execute!(grid, rule, application.at)
        update_cache!(cache, grid, application.rule_idx, application.at)

        return (next_i + 1, cache)
    end
end


"Executes a set of rules `round(N*C)` times, where C is the number of cells in the grid"
struct Sequence_DoNRelative <: AbstractSequence
    rules::Vector{CellRule}
    count_per_cell::Float64
    count_min::Int
end
function start_sequence(d::Sequence_DoNRelative, grid::CellGrid{N}, rng::PRNG) where {N}
    n_cells = prod(size(state.grid))
    count = max(d.count_min, Int(round(n_cells * state.count_per_cell)))
    inner_sequence = Sequence_DoN(d.rules, count, d.perfect)
    inner_state = start_sequence(inner_sequence, grid, rng)
    return (inner_sequence, inner_state)
end
function execute_sequence(d::Sequence_DoNRelative, grid::CellGrid{N}, rng::PRNG,
                          (inner_sequence, inner_state)::Tuple{Sequence_DoN, Any}
                         ) where {N}
    new_inner_state = execute_sequence(inner_sequence, grid, rng, inner_state)
    if isnothing(new_inner_state)
        return nothing
    else
        return (inner_sequence, new_inner_state)
    end
end


"Executes a set of rules until there are no more matches"
struct Sequence_DoAll <: AbstractSequence
    rules::Vector{CellRule}
end
start_sequence(d::Sequence_DoAll, grid::CellGrid{N}, rng::PRNG) where {N} = RuleCache(grid, d.rules)
function execute_sequence(d::Sequence_DoAll, grid::CellGrid{N}, rng::PRNG, cache::RuleCache{N}) where {N}
    if SKIP_CACHE
        options = Vector{Pair{Int32, CellLine{N}}}()
        find_rule_matches(grid, d.rules) do i, c
            push!(options, i => c)
        end
        if isempty(options)
            return nothing
        end
        option = rand(rng, options)
        rule_execute!(grid, d.rules[option[1]], option[2])
        return cache
    end

    n_options = n_cached_rule_applications(cache)
    if n_options < 1
        return nothing
    else
        application_i = rand(rng, 1:n_options)
        application = get_cached_rule_application(
            cache,
            application_i
        )
        rule = d.rules[application.rule_idx]

        @markovjunior_assert rule_applies(grid, rule, application.at) application.at

        rule_execute!(grid, rule, application.at)
        update_cache!(cache, grid, application.rule_idx, application.at)

        return cache
    end
end


"Executes a list of sequences, in order"
struct Sequence_Ordered <: AbstractSequence
    list::Vector{AbstractSequence}
end
function start_sequence(d::Sequence_Ordered, grid::CellGrid{N}, rng::PRNG) where {N}
    if isempty(d.list)
        return nothing
    else
        return (1, start_sequence(d.list[1], grid, rng))
    end
end
execute_sequence(d::Sequence_Ordered, grid::CellGrid, rng::PRNG, ::Nothing) = nothing
function execute_sequence(d::Sequence_Ordered, grid::CellGrid{N}, rng::PRNG,
                          (current_i, element_state)::Tuple{Int, Any}) where {N}
    next_from_element = execute_sequence(d.list[current_i], grid, rng, element_state)
    if exists(next_from_element)
        return (current_i, next_from_element)
    elseif current_i < length(d.list)
        return execute_sequence(d, grid, rng,
                                (current_i + 1,
                                 start_sequence(d.list[current_i + 1], grid, rng)))
    else
        return nothing
    end
end


#TODO: Slice a grid to individual M-dimensional areas, and execute a sequence on each such area