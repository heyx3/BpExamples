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
using StatsBase, Assimp, CSyntax, CImGui, GLFW

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

    println(stderr, "Inline unit tests passed!")
end
unit_tests()


function main()
    @game_loop begin
        INIT(
            v2i(1600, 900),
            "L-Systems",

            # Optional args:
            glfw_hints = Dict(
                GLFW.DEPTH_BITS => 32,
                GLFW.STENCIL_BITS => GLFW.DONT_CARE,
            )
        )

        SETUP = begin
            STATIC_WINDOW_FLAGS = |(
                0,
                CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration
            )

            lsystem = System("a", PRESETS["Regular"])
            lsystem_gui_seed = GuiText(String(@view lsystem.state[:]);
                label = "seed"
            )
            lsystem_gui_state = GuiText(String(@view lsystem.state[:]);
                label = "state"
            )

            # Helper to update the GUI representation of state from the actual state.
            function update_gui_state()
                # Copy the string bytes over, with extra space for a null terminator.
                resize!(lsystem_gui_state.raw_value.c_buffer,
                        length(lsystem.state) + 1)
                lsystem_gui_seed.raw_value.c_buffer[end] = 0
                copyto!(lsystem_gui_state.raw_value.c_buffer, lsystem.state)
                update!(lsystem_gui_state.raw_value)
            end

            # Draw in a subset of the full window.
            DRAW_AREA = Box2Df(
                min=Vec(0.51, 0.51),
                max=Vec(0.99, 0.99)
            )

            # Initialize the camera.
            cam = Cam3D{Float32}(
                pos=v3f(-5, -5, 5),
                forward=vnorm(v3f(1, 1, -1))
            )
            cam_settings = Cam3D_Settings{Float32}(
                move_speed = 10
            )

            # Configure the camera's input.
            create_axis("Cam:forward", AxisInput([
                ButtonAsAxis(GLFW.KEY_W),
                ButtonAsAxis_Negative(GLFW.KEY_S)
            ]))
            create_axis("Cam:rightward", AxisInput([
                ButtonAsAxis(GLFW.KEY_D),
                ButtonAsAxis_Negative(GLFW.KEY_A)
            ]))
            create_axis("Cam:upward", AxisInput([
                ButtonAsAxis(GLFW.KEY_E),
                ButtonAsAxis_Negative(GLFW.KEY_Q)
            ]))
            create_axis("Cam:yaw", AxisInput([
                ButtonAsAxis(GLFW.KEY_RIGHT),
                ButtonAsAxis_Negative(GLFW.KEY_LEFT)
            ]))
            create_axis("Cam:pitch", AxisInput([
                ButtonAsAxis(GLFW.KEY_UP),
                ButtonAsAxis_Negative(GLFW.KEY_DOWN)
            ]))
            get_cam_input() = Cam3D_Input{Float32}(
                controlling_rotation = true,
                forward=get_axis("Cam:forward"),
                right=get_axis("Cam:rightward"),
                up=get_axis("Cam:upward"),
                yaw=get_axis("Cam:yaw"),
                pitch=get_axis("Cam:pitch")
            )

            # Set up resources.
            node_render_program = bp_glsl"""
            #START_VERTEX
            in vec3 vIn_pos;
            in vec2 vIn_uv;
            in vec3 vIn_normal;

            uniform mat4 u_mat_points_to_world;
            uniform mat3 u_mat_normals_to_world;
            uniform mat4 u_mat_world_to_ndc;

            out vec3 vOut_worldPos;
            out vec2 vOut_uv;
            out vec3 vOut_worldNormal;

            void main() {
                vec4 worldPos4 = u_mat_points_to_world * vec4(vIn_pos, 1);
                vec3 worldNormal = u_mat_normals_to_world * vIn_normal;

                gl_Position = u_mat_world_to_ndc * worldPos4;
                vOut_worldPos = worldPos4.xyz / worldPos4.w;
                vOut_worldNormal = worldNormal;
                vOut_uv = vIn_uv;
            }

            #START_FRAGMENT
            in vec3 vOut_worldPos;
            in vec2 vOut_uv;
            in vec3 vOut_worldNormal;

            uniform vec3 u_color;

            out vec4 fOut_color;

            void main() {
                fOut_color = vec4(u_color * abs(vOut_worldNormal), 1);
            }
            """
            (node_mesh, node_mesh_buffers) = load_mesh_branch()
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break
            end

            # Update the camera.
            (cam, cam_settings) = cam_update(cam, cam_settings, get_cam_input(),
                                             LOOP.delta_seconds)

            # Clear the screen's color and depth.
            Bplus.GL.render_clear(LOOP.context,
                                  Bplus.GL.Ptr_Target(),
                                  vRGBAf(0.35, 0.35, 0.42, 1.0))
            Bplus.GL.render_clear(LOOP.context,
                                  Bplus.GL.Ptr_Target(),
                                  Float32(1))

            # Make a GUI window for editing/updating the L-system.
            gui_next_window_space(Box2Df(min=Vec(0.01, 0.01),
                                         max=Vec(0.49, 0.49)))
            gui_window("SystemEditor", C_NULL, STATIC_WINDOW_FLAGS) do
                gui_text!(lsystem_gui_seed)
                if CImGui.Button("Reset")
                    update!(lsystem_gui_state, lsystem_gui_seed.raw_value.julia)
                end
                CImGui.SameLine()
                if CImGui.Button("Iterate")
                    iterate!(lsystem)
                    update_gui_state()
                end
            end

            # Render the 3D view next to the GUI window.
            window_size = get_window_size(LOOP.context)
            render_pixel_area = Box2Di(
                min=window_size ÷ 2,
                max=window_size
            )
            set_viewport(render_pixel_area)
            set_scissor(render_pixel_area)
            set_depth_test(ValueTests.less_than)
            set_depth_writes(true)
            Bplus.GL.render_clear(LOOP.context,
                                  Bplus.GL.Ptr_Target(),
                                  vRGBAf(0.0, 0.0, 0.0, 1.0))
            Bplus.GL.render_clear(LOOP.context,
                                  Bplus.GL.Ptr_Target(),
                                  Float32(1))
            # Draw one node:
            mat_world = m4_world(
                v3f(0, 0, 0),
                fquat(),
                v3f(1, 1, 1)
            )
            mat_normals_world = m_transpose(m_invert(m_to_mat3x3(mat_world)))
            mat_vp = m_combine(cam_view_mat(cam), cam_projection_mat(cam))
            set_uniform(node_render_program, "u_mat_points_to_world", mat_world)
            set_uniform(node_render_program, "u_mat_normals_to_world", mat_normals_world)
            set_uniform(node_render_program, "u_mat_world_to_ndc", mat_vp)
            set_uniform(node_render_program, "u_color", vRGBf(1, 1, 1))
            render_mesh(node_mesh, node_render_program)
            # Finish rendering.
            set_viewport(Box2Di(min=Vec(1, 1), size=window_size))
            set_scissor(nothing)
        end
    end
end


end # module