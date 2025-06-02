const CellIdx{N} = Vec{N, Int32}

"A contiguous line of cells"
struct CellLine{N}
    start_cell::CellIdx{N}
    length::Int32
    move_axis::Int32
    move_dir::Int32

    function CellLine(start::Vec{N, <:Integer}, length,
                      move_axis, move_dir) where {N}
        @markovjunior_assert(
            in(move_axis, 1:N),
            "move_axis should be 1-N, but is ", move_axis
        )
        @markovjunior_assert(
            in(move_dir, (-1, 1)),
            "move_dir should be -1 or +1 but is ", move_dir
        )
        return new{N}(convert(CellIdx{N}, start),
                      convert(Int32, length),
                      convert(Int32, move_axis),
                      convert(Int32, move_dir))
    end
end


"Walks through every cell in a small contiguous line"
function for_each_cell_in_line(toDo, line::CellLine{N})::Bool where {N}
    for i in Int32(1):line.length
        cell = line.start_cell + CellIdx{N}(
            j -> (j == line.move_axis) ? (i * line.move_dir) : zero(Int32)
        )
        toDo(i, cell)
    end
end


function rule_applies(state::State{N}, rule::CellRule,
                      at::CellLine{N}
                     )::Bool where {N}
    for_each_cell_in_line(at) do i::Int, cell::CellIdx{N}
        if exists(rule.input[i])
            return rule.input[i] == state.grid[cell]
        end
    end
end
function rule_execute!(state::State{N}, rule::CellRule,
                       at::CellLine{N}
                      )::Nothing where {N}
    for_each_cell_in_line(start_cell, rule.length, move_axis, move_dir
                         ) do i::Int, cell::CellIdx{N}
        if exists(rule.output[i])
            state.grid[cell] = rule.output[i]
        end
    end
    return nothing
end

"Finds matches of the given rule in the given grid, and sends them into your lambda"
function find_rule_matches(process_rule, # CellLine{N} -> Nothing
                           state::State{N},
                           rule::CellRule)::Nothing where {N}
    for (move_axis, move_dir) in Iterators.product(Int32.((1, 2, 3)), Int32.((-1, 1)))
        move_dir_idx = (move_dir + 1) ÷ 2
        first_grid_idx = one(CellIdx{N}) + ((move_dir == 1) ? zero(Int32) : rule.length)
        last_grid_idx = vsize(state.grid) - ((move_dir == 0) ? zero(Int32) : rule.length)
        for grid_idx::CellIdx{N} in first_grid_idx:last_grid_idx
            at = CellLine(grid_idx, rule.length, move_axis, move_dir)
            if rule_applies(state, rule, at)
                process_rule(at)
            end
        end
    end
    return nothing
end
"
Find matches of the given rules in the given grid, and send them into your lambda.
Rules are ordered by your own rules iterator,
    e.g. the first batch of outputs are all for your first rule.
"
function find_rule_matches(process_rule, # (rule_idx::Int32, CellLine{N}) -> Nothing
                           state::State{N},
                           rules)::Nothing where {N}
    for (i, rule) in enumerate(rules)
        find_matching_rules(at -> process_rule(i, at), state, rule)
    end
    return nothing
end