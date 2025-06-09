"Based on the amazing Github repo: [https://github.com/mxgmn/MarkovJunior](mxgmn/MarkovJunior)"
module MarkovJunior

using Random, Setfield
using OrderedCollections
using Bplus; @using_bplus


Bplus.@make_toggleable_asserts markovjunior_

include("cells.jl")
include("rules.jl")
include("sequences.jl")
include("renderer.jl")


function main()::Int

    grid::CellGrid{2} = fill(CELL_CODE_BY_CHAR['b'], (10, 10))
    grid[5, 5] = CELL_CODE_BY_CHAR['w']

    rng = PRNG(0x152433)

    sequence = Sequence_DoAll([
        CellRule("bbw", "bww")
    ])

    seq_state = execute_sequence(sequence, grid, rng, start_sequence(sequence, grid, rng))
    i = 0
    while (i < 20) && exists(seq_state)
        i += 1
        seq_state = execute_sequence(sequence, grid, rng, seq_state)
    end

    @game_loop begin
        # Bplus.GL.Context constructor parameters:
        INIT(convert(v2i, vsize(grid) * 20), "Markov Junior Playground",
             vsync=VsyncModes.on)

        # Initialization:
        SETUP = begin
            # Render the grid.
            grid_tex_ref = Ref{Texture}()
            render_markov_2d(grid, v3f(0.4, 0, 0.4), Ref{Matrix{v3f}}(), grid_tex_ref)
            grid_tex = grid_tex_ref[]
        end

        # Core loop:
        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break # Cleanly ends the game loop
            end

            clear_screen(@f32(1)) # Depth
            simple_blit(grid_tex, output_curve=@f32(2.2))
        end
    end

    return 0
end

end