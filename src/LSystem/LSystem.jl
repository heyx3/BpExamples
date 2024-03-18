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
using Random, Setfield

# External dependencies:
using StatsBase, DataStructures, CSyntax,
      Assimp, CImGui, GLFW,
      Colors

# B+:
using Bplus; @using_bplus

# Fix ambiguity between 'update!()' in B+ and in DataStructures:
const update! = BplusCore.Utilities.update!


# For performance, L-system characters are limited to 1-byte ascii.
# 'String' probably isn't good for high-performance array work anyway
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
            lsystem_render_settings = CommandSettings()
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
                min=Vec(0.32, 0.01),
                max=Vec(0.995, 0.995)
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
                vOut_worldNormal = normalize(worldNormal);
                vOut_uv = vIn_uv;
            }

            #START_FRAGMENT
            in vec3 vOut_worldPos;
            in vec2 vOut_uv;
            in vec3 vOut_worldNormal;

            uniform vec3 u_color;

            out vec4 fOut_color;

            void main() {
                fOut_color = vec4(u_color, 1);
            }
            """
            (node_mesh, node_mesh_buffers) = load_mesh_branch()

            # Set up render list.
            render_instances = Vector{RenderInstance}()
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break
            end

            # Update the camera.
            (cam, cam_settings) = cam_update(cam, cam_settings, get_cam_input(),
                                             LOOP.delta_seconds)

            # Clear the screen's color and depth.
            BplusApp.GL.clear_screen(vRGBAf(0.35, 0.35, 0.42, 1.0))
            BplusApp.GL.clear_screen(Float32(1))

            # Make a GUI window for editing/updating the L-system.
            gui_next_window_space(Box2Df(min=Vec(0.01, 0.01),
                                         max=Vec(0.3, 0.49)))
            gui_window("SystemEditor", C_NULL, STATIC_WINDOW_FLAGS) do
                LINE_BUTTON_SIZE = v2i(80, 40)

                # Draw the seed value in a textbox.
                # It should be vertically aligned with the buttons that come after it.
                textbox_vertical_indent = (LINE_BUTTON_SIZE.y / 2) -
                                            (CImGui.GetTextLineHeight() / 2) +
                                            (-10) # Fudge factor
                textbox_width = CImGui.GetContentRegionAvailWidth() - (2 * LINE_BUTTON_SIZE.x) - 50
                gui_with_item_width(textbox_width) do
                    gui_within_group() do
                        CImGui.Dummy((1.0, textbox_vertical_indent))
                        gui_text!(lsystem_gui_seed)
                    end
                end

                # Draw 'Reset' and 'Iterate' buttons next to it.
                CImGui.SameLine()
                if CImGui.Button("Reset", LINE_BUTTON_SIZE.data)
                    update!(lsystem_gui_state, lsystem_gui_seed.raw_value.julia)
                end
                CImGui.SameLine()
                if CImGui.Button("Iterate", LINE_BUTTON_SIZE.data)
                    iterate!(lsystem)
                    update_gui_state()
                end

                # Display the current state, using word-wrapping.
                CImGui.Text("State")
                @c CImGui.TextWrapped(&lsystem_gui_state.raw_value.c_buffer[0])

                CImGui.Dummy(1, 50)

                # Draw the "Render" button.
                if CImGui.Button("Render", (100, 40))
                    empty!(render_instances)
                    build_render_instances(lsystem.state, render_instances, lsystem_render_settings)
                end

                CImGui.Dummy(1, 50)

                # Draw the rules being used.
                CImGui.Combo
            end

            # Make a GUI window for system rendering.
            gui_next_window_space(Box2Df(min=Vec(0.01, 0.51),
                                         max=Vec(0.3, 0.99)))
            gui_window("RenderEditor", C_NULL, STATIC_WINDOW_FLAGS) do
                CImGui.Text("Sizing")
                gui_with_indentation(() -> gui_with_nested_id("Sizing") do
                    @c CImGui.InputFloat("initial scale", &lsystem_render_settings.initial_scale)
                    @c CImGui.InputFloat("length step", &lsystem_render_settings.length_step_scale)
                    @c CImGui.InputFloat("thickess step", &lsystem_render_settings.thickness_step_scale)
                end)
                CImGui.Text("Rotation Steps")
                gui_with_indentation(() -> gui_with_nested_id("Rotation") do
                    @c CImGui.SliderFloat("pitch", &lsystem_render_settings.pitch, 0, 360)
                    @c CImGui.SliderFloat("yaw", &lsystem_render_settings.yaw, 0, 360)
                    @c CImGui.SliderFloat("roll", &lsystem_render_settings.roll, 0, 360)
                end)
                CImGui.Text("Color")
                gui_with_indentation(() -> gui_with_nested_id("Color") do
                    @c CImGui.ColorEdit3("initial", &lsystem_render_settings.initial_color)
                    h, s, l = lsystem_render_settings.hsl_shift
                    @c CImGui.SliderFloat("hue step", &h, -1, 1)
                    @c CImGui.SliderFloat("saturation step", &s, -1, 1)
                    @c CImGui.SliderFloat("lightness step", &l, -1, 1)
                    lsystem_render_settings.hsl_shift = v3f(h, s, l)
                end)
                CImGui.Text("Dropoff by depth")
                gui_with_indentation(() -> gui_with_nested_id("Dropoff") do
                    h, s, l = lsystem_render_settings.depth_shrink_hsl_shift
                    @c CImGui.SliderFloat("hue", &h, 0, 1)
                    @c CImGui.SliderFloat("saturation", &s, 0, 1)
                    @c CImGui.SliderFloat("lightness", &l, 0, 1)
                    lsystem_render_settings.depth_shrink_hsl_shift = v3f(h, s, l)
                    CImGui.Spacing()
                    @c CImGui.SliderFloat("pitch", &lsystem_render_settings.depth_shrink_pitch, 0, 1)
                    @c CImGui.SliderFloat("yaw", &lsystem_render_settings.depth_shrink_yaw, 0, 1)
                    @c CImGui.SliderFloat("roll", &lsystem_render_settings.depth_shrink_roll, 0, 1)
                    CImGui.Spacing()
                    @c CImGui.SliderFloat("scale", &lsystem_render_settings.depth_shrink_scale_change, 0, 1)
                end)
            end

            #TODO: if system/settings are out of date, make the Render button green
            #TODO: A GUI window that lists all the generated instances.

            # Render the 3D view next to the GUI window.
            window_size = get_window_size(LOOP.context)
            render_pixel_area = Box2Di(
                min=map(f->floor(Int32, f),
                        min_inclusive(DRAW_AREA) * window_size),
                max=map(f->floor(Int32, f),
                        max_inclusive(DRAW_AREA) * window_size)
            )
            set_viewport(render_pixel_area)
            set_scissor(render_pixel_area)
            set_depth_test(ValueTests.less_than)
            set_depth_writes(true)
            clear_screen(vRGBAf(0.0, 0.0, 0.0, 1.0))
            clear_screen(Float32(1))
            mat_view = cam_view_mat(cam)
            mat_proj = cam_projection_mat(cam)
            mat_vp = m_combine(cam_view_mat(cam), cam_projection_mat(cam))
            for instance in render_instances
                render(instance, node_mesh, node_render_program, mat_vp)
            end
            # Finish rendering.
            set_viewport(Box2Di(min=Vec(1, 1), size=window_size))
            set_scissor(nothing)
        end
    end
end


end # module