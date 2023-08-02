"
Uses an L-system to generate a hierarchical tree-like structure.
Showcases the SceneTree system, loading of assets from files,
    and some interesting GUI stuff as well.

Also shows how to use Julia's array-processing features,
    originally intended for scientific computing,
    to hugely simplify syntax without sacrificing performance.
This array-processing syntax also helps to prototype GPU techniques on the CPU.
"
module LSystem

# Built-in dependencies:
using Random

# External dependencies:
using StatsBase, Assimp

# B+:
using Bplus
using Bplus.Utilities, Bplus.Math,
      Bplus.GL, Bplus.SceneTree,
      Bplus.GUI, Bplus.Input, Bplus.Helpers


# For performance, characters are limited to 1-byte ascii.
const AsciiChar = UInt8
const AsciiString = Vector{UInt8}

include("rules.jl")
include("system.jl")

include("interpreter.jl")
include("assets.jl")


"Some pre-made interesting rules"
const PRESETS::Dict{String, Ruleset} = Dict(
    "Regular" => [
        # 'a' represents a new branch.
        # 'b' represents three new branches.
        # 'r' represents a rotation.
        # 'c' represents a change in color.
        Rule('a', "[*Ccrb]"),
        Rule('b', "aYaYa"),
        Rule('r', "PYR"),
        Rule('c', "HSL")
    ]
)

"Quick inline unit tests"
function unit_tests()
    # Test the LSystem's core algorithm.
    sys = System("a", PRESETS["Regular"])
    function check_iteration(expected::String)
        iterate!(sys)
        actual = String(@view sys.state[:])
        @bp_check(actual == expected,
                  "Expected '", expected, "'.\n\tGot: '", actual, "'")
    end
    check_iteration("[*Ccrb]")
    check_iteration("[*CHSLPYRaYaYa]")
    check_iteration("[*CHSLPYR[*Ccrb]Y[*Ccrb]Y[*Ccrb]]")

    println(stderr, "Unit tests passed!")
end
unit_tests()

end # module