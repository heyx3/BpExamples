"A rewriting rule in an L-system"
struct Rule
    input::AsciiChar
    output::AsciiString
    weight::Float32

    function Rule(input, output, weight = 1)
        if input isa AbstractString
            @bp_check(length(input) == 1)
            input = input[1]
        end
        if input isa AbstractChar
            input = codepoint(input)
        end
        input = convert(UInt8, input)

        if output isa AbstractString
            output = collect(codeunits(output))
        end

        weight = convert(Float32, weight)

        return new(input, output, weight)
    end
end

@inline is_applicable(rule::Rule, c::AsciiChar)::Bool = (rule.input == c)

const Ruleset = Vector{Rule}