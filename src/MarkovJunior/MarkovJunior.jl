"Based on the amazing Github repo: [https://github.com/mxgmn/MarkovJunior](mxgmn/MarkovJunior)"
module MarkovJunior

using Random, Setfield, Profile
using OrderedCollections, GLFW
using Bplus; @using_bplus


Bplus.@make_toggleable_asserts markovjunior_
const SKIP_CACHE = false # Useful for debugging the cache

include("cells.jl")
include("rules.jl")
include("sequences.jl")
include("renderer.jl")


const DEFAULT_SEQUENCE = Sequence_Ordered([
    Sequence_DoN([
        CellRule("b", "w")
    ], 1),
    Sequence_DoAll([
        CellRule("bbw", "wEw")
    ]),
    Sequence_DoAll([
        CellRule("E", "w")
    ])
])

function main(; resolution::v2i = v2i(30, 30),
                sequence::AbstractSequence = DEFAULT_SEQUENCE,
                seed = rand(UInt32),
                profile::Bool = false
             )::Int
    println("Seed: ", seed)
    rng = PRNG(seed)

    grid = fill(CELL_CODE_BY_CHAR['b'], resolution.data)

    @game_loop begin
        # Bplus.GL.Context constructor parameters:
        INIT(v2i(400, 400), "Markov Junior Playground",
             vsync=VsyncModes.off)

        # Initialization:
        SETUP = begin
            profile && Profile.start_timer()

            grid_tex_ref = Ref{Texture}()
            grid_pixels_buffer = Ref{Matrix{v3f}}()

            sequence_state = execute_sequence(sequence, grid, rng, start_sequence(sequence, grid, rng))
            LOOP.max_fps = nothing
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

        TEARDOWN = begin
            profile && Profile.stop_timer()
        end
    end

    return 0
end

# Precompile code using a basic sequence.
# The sequence logic is super type-unstable, so this is very important to performance.
function run_game(; sequence::AbstractSequence = DEFAULT_SEQUENCE,
                    resolution::Int = 50)
    grid = fill(CELL_CODE_BY_CHAR['b'], (resolution, resolution))
    rng = PRNG(0x23423411)

    seq_state = start_sequence(sequence, grid, rng)
    while exists(seq_state)
        seq_state = execute_sequence(sequence, grid, rng, seq_state)
    end

    return grid
end
run_game()

end