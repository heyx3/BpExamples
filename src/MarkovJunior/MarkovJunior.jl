"Based on the amazing Github repo: [https://github.com/mxgmn/MarkovJunior](mxgmn/MarkovJunior)"
module MarkovJunior

using Random, Setfield
using OrderedCollections, GLFW
using Bplus; @using_bplus


Bplus.@make_toggleable_asserts markovjunior_
const SKIP_CACHE = false # Useful for debugging the cache

include("cells.jl")
include("rules.jl")
include("sequences.jl")
include("renderer.jl")


function main()::Int

    grid::CellGrid{2} = fill(CELL_CODE_BY_CHAR['b'], (10, 10))
    grid[5, 5] = CELL_CODE_BY_CHAR['w']

    rng = PRNG(rand(UInt32))

    sequence = Sequence_DoAll([
        CellRule("bbw", "bww")
    ])

    @game_loop begin
        # Bplus.GL.Context constructor parameters:
        INIT(v2i(200, 200), "Markov Junior Playground",
             vsync=VsyncModes.on)

        # Initialization:
        SETUP = begin
            grid_tex_ref = Ref{Texture}()
            grid_pixels_buffer = Ref{Matrix{v3f}}()

            sequence_state = execute_sequence(sequence, grid, rng, start_sequence(sequence, grid, rng))
        end

        # Core loop:
        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break # Cleanly ends the game loop
            end

            # Tick the algorithm.
            if exists(sequence_state)
                sequence_state = execute_sequence(sequence, grid, rng, sequence_state)
            end
            render_markov_2d(grid, v3f(0.4, 0, 0.4), grid_pixels_buffer, grid_tex_ref)

            # Render the algorithm state.
            clear_screen(vRGBAf(1, 0, 1, 1))
            clear_screen(@f32(1)) # Depth
            simple_blit(grid_tex_ref[], output_curve=@f32(2.2))
        end
    end

    return 0
end

end