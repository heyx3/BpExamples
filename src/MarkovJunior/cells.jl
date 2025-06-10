struct CellType
    code::UInt8
    name::String
    char::Char
    color::v3f # Linear color
end

const CELL_TYPES::NTuple{16, CellType} = tuple(
    CellType(0, "Black",   'b', v3f(0, 0, 0)),
    CellType(1, "Gray",    'g', v3f(0.5, 0.5, 0.5)),
    CellType(2, "White",   'w', v3f(1, 1, 1)),
    CellType(3, "Red",     'R', v3f(1, 0, 0)),
    CellType(4, "Green",   'G', v3f(0, 1, 0)),
    CellType(5, "Blue",    'B', v3f(0, 0, 1)),
    CellType(6, "Yellow",  'Y', v3f(1, 1, 0)),
    CellType(7, "Magenta", 'M', v3f(1, 0, 1)),
    CellType(8, "Teal",    'T', v3f(0, 1, 1)),
    CellType(9, "Orange",  'O', v3f(1, 0.5, 0)),
    CellType(10, "Pink",   'P', v3f(1, 0, 0.5)),
    CellType(11, "Olive",  'L', v3f(0, 0.5, 0.2)),
    CellType(12, "Indigo", 'I', v3f(0, 0.2, 0.5)),
    CellType(13, "Brown",  'N', v3f(0.5, 0.2, 0)),
    CellType(14, "Beige",  'E', v3f(1, 0.9, 0.8)),
    CellType(15, "SkyBlue", 'S', v3f(0.7, 0.85, 1))
)

const CELL_CODE_BY_CHAR::Dict{Char, UInt8} = Dict(
    t.char => t.code for t in CELL_TYPES
)
"Represents 'null' or an unset cell"
const CELL_CODE_INVALID = convert(UInt8, 255)


"A grid of cell values (by their code)"
const CellGrid{N} = AbstractArray{UInt8, N}
"Reference to a N-dimensional grid cell"
const CellIdx{N} = Vec{N, Int32}


"
An orthogonal direction along some N-dimensional grid.
The set of all possible directions is well-ordered
    (1/-1, 1/+1, 2/-1, 2/+1, etc),
    so you can refer to them by index as well.
"
struct GridDir
    # 1 - N
    axis::Int32
    # -1 or +1
    dir::Int32

    GridDir(axis, dir) = if (axis < 1) || !in(dir, (-1, +1))
        error("Axis must be >0 and dir must be -1 or +1! Got ", axis, " and ", dir)
    else
        new(convert(Int32, axis), convert(Int32, dir))
    end
end

"Gets the index of the given grid direction"
grid_dir_index(d::GridDir)::Int32 = (d.axis * Int32(2)) + ((d.dir + 1) ÷ 2)
"Gets the grid direction at the given index"
grid_dir_index(_i) = let i = convert(Int32, _i)
    GridDir((i + 1) ÷ 2, (2 * ((i - 1) % 2)) - 1)
end
"Gets the number of grid directions for the given number of dimensions"
@inline grid_dir_count(N) = N * convert(typeof(N), 2)

# Optimize hashing by compressing the GridDir into its index.
Base.hash(d::GridDir, u::UInt) = Base.hash(grid_dir_index(d), u)


"A contiguous line of cells"
struct CellLine{N}
    start_cell::CellIdx{N}
    movement::GridDir
    length::Int32
end
function Base.print(io::IO, l::CellLine)
    p_start = l.start_cell
    p_end = p_start
    @set! p_end[l.movement.axis] += l.movement.dir * (l.length - 1)
    print(io, "<", p_start, " to ", p_end, ">")
end

"Walks through every cell in a small contiguous line"
function for_each_cell_in_line(toDo, line::CellLine{N})::Nothing where {N}
    for iz in zero(Int32):(line.length - one(Int32))
        cell = line.start_cell
        @set! cell[line.movement.axis] += (iz * line.movement.dir)
        toDo(iz + one(Int32), cell)
    end
    return nothing
end

function cell_line_aabb(line::CellLine{N})::Box{N, Int32} where {N}
    start_pos = line.start_cell
    end_pos = start_pos
    @set! end_pos[line.movement.axis] += line.movement.dir * (line.length - 1)
    (start_pos, end_pos) = Bplus.Math.minmax(start_pos, end_pos)
    return Box{N, Int32}(
        min=start_pos,
        max=end_pos
    )
end