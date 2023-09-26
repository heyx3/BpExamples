module BpExamples


include("Pong.jl")
export Pong

include("RayTracer/RayTracer.jl")
export RayTracer

include("TextureGen.jl")
export TextureGen

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
    "L-System" => LSystem.main
]

function main()
    chosen_module = Ref{Union{Base.Callable, Val{:MENU}, Val{:QUIT}}}(Val(:MENU))
    while true
        if chosen_module[] isa Val{:MENU}
            @game_loop begin

                INIT(
                    v2i(500, 900), "B+ Examples Main Menu",
                    glfw_hints = Dict(
                        GLFW.RESIZABLE => false
                    )
                )

                LOOP = begin
                    if GLFW.WindowShouldClose(LOOP.context.window)
                        chosen_module[] = Val(:QUIT)
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
                            if CImGui.Button(option, (200, 100))
                                chosen_module[] = run_option
                            end
                        end
                        CImGui.Dummy(0, 75)

                        CImGui.Dummy(125, 0)
                        CImGui.SameLine()
                        if CImGui.Button("Quit", (150, 75))
                            chosen_module[] = Val(:QUIT)
                        end
                    end

                    if !isa(chosen_module[], Val{:MENU})
                        break
                    end
                end
            end
        elseif chosen_module[] isa Val{:QUIT}
            break
        else
            chosen_module[]()
            chosen_module[] = Val(:MENU)
        end
    end
end

end # module
