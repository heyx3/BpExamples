abstract type AbstractSequence end
execute_sequence!(seq::AbstractSequence, state::State)::Nothing = error("Unimplemented: ", typeof(seq))

#TODO: Create a system for pooling arrays

"Executes a set of rules exactly N times"
struct Sequence_DoN <: AbstractSequence
    rules::Vector{CellRule}
    count::Int
    perfect::Bool # If true, then matches are recomputed after every application of a rule;
                  #    this catches new opportunities created by previous applications, but is also much slower.

    Sequence_DoN(rules, count, perfect::Bool = true) = new(
        collect(CellRule, rule),
        if !(count isa Integer)
            error("Received ", typeof(count), " for a count!")
        elseif count < 0
            error("Received a negative count for 'Do N' sequence!")
        else
            convert(Int, count)
        end,
        perfect
    )
end
function execute_sequence!(d::Sequence_DoN, state::State{N}) where {N}
    match_buffer = Bplus.Utilities.preallocated_vector(
        Pair{Int, CellLine{N}},
        let nCells = prod(size(state.grid))
            Int(round(sqrt(nCells)))
        end
    )
    function update_matches()
        @markovjunior_assert isempty(match_buffer)
        find_rule_matches(state, d.rules) do (i, at)
            push!(match_buffer, i=>at)
        end
        return !isempty(match_buffer)
    end

    next_match_idx() = rand(state.rng, 1:length(match_buffer))

    for i in 1:d.count
        # Find all possible matches.
        if (i == 1) || d.perfect
            update_matches()
        end
        if isempty(match_buffer)
            @warn "Ran out of matches before we were able to execute all $(d.count) iterations of sequence:\n$d\n"
            return nothing
        end

        # Pick a match to execute the rule on.
        chosen_match_idx = next_match_idx()
        (chosen_rule_idx, chosen_match) = match_buffer[chosen_match_idx]
        if !d.perfect
            # Matches may have become invalid after previous iterations.
            while !rule_applies(state, d.rules[chosen_rule_idx], chosen_match)
                deleteat!(match_buffer, chosen_match_idx)
                if empty(match_buffer) && !update_matches()
                    @warn "Ran out of matches before we were able to execute all $(d.count) imperfect iterations of rule $(d.rule)!"
                    return nothing
                end

                chosen_match_idx = next_match_idx()
                (chosen_rule_idx, chosen_match) = match_buffer[chosen_match_idx]
            end
        end
        rule_execute!(state, d.rules[chosen_rule_idx], chosen_match)

        # Update the match buffer for the next iteration.
        if d.perfect
            empty!(match_buffer)
        else
            deleteat!(match_buffer, chosen_match_idx)
        end
    end

    return nothing
end


"Executes a set of rules `round(N*C)` times, where C is the number of cells in the grid"
struct Sequence_DoNRelative <: AbstractSequence
    rules::Vector{CellRule}
    count_per_cell::Float64
    count_min::Int
    perfect::Bool # If true, then matches are recomputed after every application of a rule;
                  #    this is more correct but also much slower.

    Sequence_DoNRelative(rules, count_per_cell,
                         count_min = 1,
                         perfect::Bool = true) = new(
        collect(CellRule, rule),
        if !(count_per_cell isa Real)
            error("Received ", typeof(count_per_cell), " for count_per_cell!")
        elseif count < 0
            error("Received a negative count_per_cell!")
        else
            convert(Float64, count_per_cell)
        end,
        if !(count_min isa Integer)
            error("Received ", typeof(count_min), " for count_min!")
        elseif count_min < 0
            error("Receive a negative count_min!")
        else
            convert(Int, count_min)
        end,
        perfect
    )
end
function execute_sequence!(d::Sequence_DoNRelative, state::State{N}) where {N}
    n_cells = prod(size(state.grid))
    count = max(d.count_min, Int(round(n_cells * state.count_per_cell)))
    return execute_sequence!(Sequence_DoN(d.rules, count, d.perfect), state)
end


"Executes a set of rules until there are no more matches"
struct Sequence_DoAll <: AbstractSequence
    rules::Vector{CellRule}
    perfect::Bool # If true, then matches are recomputed after every application of a rule;
                  #    this has a more correct probability distribution but is much slower.

    Sequence_DoAll(rules, perfect::Bool = true) = new(collect(CellRule, rule), perfect)
end
function execute_sequence!(d::Sequence_DoAll, state::State{N}) where {N}
    match_buffer = Bplus.Utilities.preallocated_vector(
        Pair{Int, CellLine{N}},
        let nCells = prod(size(state.grid))
            Int(round(sqrt(nCells)))
        end
    )
    function refresh_matches()
        @markovjunior_assert isempty(match_buffer)
        find_rule_matches(state, d.rules) do (i, at)
            push!(match_buffer, i=>at)
        end
        return !isempty(match_buffer)
    end

    next_match_idx() = rand(state.rng, 1:length(match_buffer))

    while true
        if d.perfect || isempty(match_buffer)
            if !refresh_matches()
                return nothing
            end
        end

        # Pick a random match that is still valid;
        #    in imperfect mode some may have become invalid after previous iterations.
        chosen_match_idx = next_match_idx()
        (chosen_rule_idx, chosen_match) = match_buffer[chosen_match_idx]
        if !d.perfect
            while !rule_applies(state, d.rules[chosen_rule_idx], chosen_match)
                deleteat!(match_buffer, chosen_match_idx)
                if isempty(match_buffer) && !refresh_matches()
                    return nothing
                end

                chosen_match_idx = next_match_idx()
                (chosen_rule_idx, chosen_match) = match_buffer[chosen_match_idx]
            end
        end
        rule_execute!(state, d.rules[chosen_rule_idx], chosen_match)

        # Update the match buffer for the next iteration.
        if d.perfect
            empty!(match_buffer)
        else
            deleteat!(match_buffer, chosen_match_idx)
        end
    end

    return nothing
end

"Executes a list of sequences, in order"
struct Sequence_Ordered <: AbstractSequence
    list::Vector{AbstractSequence}
end
function execute_sequence!(o::Sequence_Ordered, state::State)
    for s in o.list
        execute_sequence!(s, state)
    end
    return nothing
end

#TODO: Slice a grid to individual M-dimensional areas, and execute a sequence on each such area