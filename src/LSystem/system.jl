mutable struct System
    state::AsciiString
    rules::Ruleset

    function System(state, rules)
        if state isa AbstractString
            state = codeunits(state)
        end
        if state isa AbstractVector
            state = UInt8.(state)
        end

        rules = collect(Rule, rules)

        return new(state, rules)
    end
end

"Steps the L-system one step forward"
function iterate!(system::System, rng::AbstractRNG = Random.GLOBAL_RNG)
    # Turn the vector of rules and vector of chars into a matrix of "is_applicable(rule, char)".
    # This can be done by transposing the chars into a row-vector using the apostrophe unary operator,
    #    then using Julia's broadcast syntax to spread the so-called "scalar" expression
    #    across the entire matrix.
    # The scalar expression is "is_applicable(rule, char)".
    # The matrix expression is "is_applicable.(rules, chars')".
    # The rules vector is spread across rows so that each row represents one rule.
    # The chars vector is spread across columns so that each column represents one char.
    # Note that matrices are referenced by row and then by column (e.x. "m[r, c]").
    legal_elements::AbstractMatrix{Bool} = is_applicable.(system.rules, system.state')

    # For each rule+char, get the weight of the rule, using 0 if it's not applicable.
    # The scalar expression for this is 'ifelse(legal_element, rule.weight, zero(Float32))'.
    weights::AbstractMatrix{Float32} = ifelse.(legal_elements,
                                               [r.weight for r in system.rules], # This value gets broadcast across every char
                                               Ref(zero(Float32)))

    # For each char, randomly pick one of the rules using weighted randomness,
    #    falling back to a null value if all weights are 0.
     # This turns the matrix data back into a row of indices.
    # The scalar expression is "ifelse(all(iszero, weights_column), 0,
    #                                  StatsBase.sample(rng, 1:length(system.rules),
    #                                                   Weights(weights_column))".
    #NOTE: The below flattened arrays should be a Vector, but they're techically a 1xM matrix.
    skip_chars::AbstractArray{Bool} =
        all(iszero, weights; dims=1)
    #NOTE: The 'Weights' struct is itself an AbstractVector, so
    #    to avoid it mucking up the array operations I hide it in a 1-tuple.
    sampling_weights::AbstractArray{Tuple{StatsBase.Weights}} =
        mapslices(tuple ∘ Weights,
                  weights; dims=1)
    # Because of the complexity of this expression, we'll run it through the "@." macro,
    #    which makes every expression broadcast by default
    #    and use the prefix '$' to avoid broadcasting a value.
    chosen_rule_idcs_raw =
        sample.(Ref(rng),
                Ref(1:length(system.rules)),
                getindex.(sampling_weights, Ref(1)))
    chosen_rule_idcs::AbstractArray{Int} =
        @. ifelse(skip_chars, $0, chosen_rule_idcs_raw)

    # Now apply each rule, modifying the string.
    output = preallocated_vector(AsciiChar, length(system.state) * 4)
    for (original_char, rule_idx) in zip(system.state, chosen_rule_idcs)
        if rule_idx > 0
            append!(output, system.rules[rule_idx].output)
        else
            push!(output, original_char)
        end
    end
    system.state = output

    return nothing
end