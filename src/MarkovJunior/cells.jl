struct CellState
    code::UInt8
    name::String
    char::Char
    color::v3f # Linear color
end

const CELL_TYPES::NTuple{16, CellState} = tuple(
    CellState(0, "Black",   'b', v3f(0, 0, 0)),
    CellState(1, "Gray",    'g', v3f(0.5, 0.5, 0.5)),
    CellState(2, "White",   'w', v3f(1, 1, 1)),
    CellState(3, "Red",     'R', v3f(1, 0, 0)),
    CellState(4, "Green",   'G', v3f(0, 1, 0)),
    CellState(5, "Blue",    'B', v3f(0, 0, 1)),
    CellState(6, "Yellow",  'Y', v3f(1, 1, 0)),
    CellState(7, "Magenta", 'M', v3f(1, 0, 1)),
    CellState(8, "Teal",    'T', v3f(0, 1, 1)),
    CellState(9, "Orange",  'O', v3f(1, 0.5, 0)),
    CellState(10, "Pink",   'P', v3f(1, 0, 0.5)),
    CellState(11, "Olive",  'L', v3f(0, 0.5, 0.2)),
    CellState(12, "Indigo", 'I', v3f(0, 0.2, 0.5)),
    CellState(13, "Brown",  'N', v3f(0.5, 0.2, 0)),
    CellState(14, "Beige",  'E', v3f(1, 0.9, 0.8)),
    CellState(15, "SkyBlue", 'S', v3f(0.7, 0.85, 1))
)
const CELL_CODE_INVALID = convert(UInt8, 255)

struct CellRule
    length::Int32
    # A 'nothing' entry means anything can be in that cell.
    input::Vector{Optional{UInt8}}
    # A 'nothing' entry means that cell is unchanged.
    output::Vector{Optional{UInt8}}

    function CellRule(input::Vector, output::Vector)
        if length(input) != length(output)
            error("Input and output rules must be the same size!")
        end
        return new(convert(Int32, length(input)),
                   collect(Optional{UInt8}, input),
                   collect(Optional{UInt8}, output))
    end
end

struct State{N, TArray<:AbstractArray{UInt8, N}}
    grid::TArray
    rng::PRNG

    function State(size::Vec{N, <:Integer}, fill_value::UInt8,
                   special_values::Dict,
                   rng_seeds...) where {N}
        grid = fill(fill_value, size.data)
        for (cell::Vec{N, <:Integer}, state::Integer) in special_values
            grid[cell] = convert(Uint8, state)
        end
        return new{N, typeof(grid)}(grid, PRNG(rng_seeds...))
    end
    function State(array::AbstractArray{UInt8, N},
                   rng_seeds...) where {N}
        return new{N, typeof(array)}(array, PRNG(rng_seeds...))
    end
end