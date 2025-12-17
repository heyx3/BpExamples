module BpExamples


include("Pong.jl")
export Pong

include("RayTracer/RayTracer.jl")
export RayTracer

include("TextureGen.jl")
export TextureGen

include("ToySynth.jl")
export ToySynth

include("LSystem/LSystem.jl")
export LSystem


# Display a main menu to choose from the above titles.

using CImGui, GLFW

using Bplus
@using_bplus

const APP_OPTIONS = Pair{String, Base.Callable}[
    "Pong" => Pong.main,
    "Ray Tracer" => RayTracer.main,
    "Texture Generator" => TextureGen.main,
    "Toy Synthesizer" => ToySynth.main,

    # L-system is half-finished :(
    # "L-System" => LSystem.main
]

function main()
    # Three states for this app: run a game, show the menu, or go quit.
    current_state = Ref{Union{Base.Callable, Val{:MENU}, Val{:QUIT}}}(Val(:MENU))
    while true
        if current_state[] isa Val{:MENU}
            @game_loop begin

                INIT(
                    v2i(500, 900), "B+ Examples Main Menu",
                    glfw_hints = Dict(
                        GLFW.RESIZABLE => false
                    )
                )

                LOOP = begin
                    if GLFW.WindowShouldClose(LOOP.context.window)
                        current_state[] = Val(:QUIT)
                        break
                    end

                    clear_screen(vRGBAf(0.2, 0.5, 0.3, 1.0))

                    CImGui.SetNextWindowSize((400, 725))
                    CImGui.SetNextWindowPos((250, 450), 0, (0.5, 0.5))
                    gui_window("Options", C_NULL, CImGui.ImGuiWindowFlags_NoDecoration) do
                        for (option, run_option) in APP_OPTIONS
                            CImGui.Dummy(0, 25)

                            CImGui.Dummy(100, 0)
                            CImGui.SameLine()
                            if CImGui.Button(option, (200, 65))
                                current_state[] = run_option
                            end
                        end
                        CImGui.Dummy(0, 75)

                        CImGui.Dummy(125, 0)
                        CImGui.SameLine()
                        if CImGui.Button("Quit", (150, 75))
                            current_state[] = Val(:QUIT)
                        end
                    end

                    if !isa(current_state[], Val{:MENU})
                        break
                    end
                end
            end
        elseif current_state[] isa Val{:QUIT}
            break
        else
            current_state[]()
            current_state[] = Val(:MENU)
        end
    end
end

end # module
