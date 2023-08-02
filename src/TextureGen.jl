"
A little tool to generate interesting 2D textures using `Bplus.Fields`.

Fields are a data representation of functions mapping an input vector to an output vector.
In this case, we are mapping 2D vectors (UV coordinate) to 4D vectors (RGBA pixel).

Fields have a special Domain-Specific Language, or DSL, allowing you to generate them from plain-text.
Several examples will be included with the program.

Some features of `Fields` are quite advanced; for example, you can get the gradient of a field
   (like a multidimensional derivative) and in many cases it is computed analytically,
   meaning it's efficient and precise. In the rest of cases it is approximated with Finite Differences.
"
module TextureGen

using GLFW, CImGui
using CSyntax # Helps when making some CImGui calls
using Images # Saving images to disk

using Bplus,
      Bplus.Utilities,
      Bplus.Math, Bplus.GL, Bplus.SceneTree,
      Bplus.Input, Bplus.GUI, Bplus.Helpers,
      Bplus.Fields

# Define some built-in fields for the user to reference.
# Fields are defined with a custom Julia macro, '@field [InputDimensions] [NumberType] [DSL]'.
const BUILTIN_FIELDS = Dict{String, String}(
    "UV" => "@field 2 Float32 pos",
    "Clouds" => "@field 2 Float32 perlin(pos * 3)",

    "Ripples" => "@field 2 Float32 clamp(sin(vdist(pos, 0.5) * 24 * { 1, 1.75, 2.75 }), 0, 1)",

    "Stripes" => "# Julia has an alternative macro call syntax, for multi-line statements:
@field(2, Float32,
    # Declare some local variables.
    let body = 0.5 + (0.5 * sin(pos.x * 26)), # Oscillate between 0 and 1
        details = 0.25 * { 0.6, 1, 10/6 } * lerp(-1, 1, perlin(pos * 16)) # Small signed pertubations
      # Now output the main value.
      clamp(body + details, 0, 1) # Output Red value between 0 and 1, automatically copied to Green and Blue
    end
)",

    #TODO: Nested 'let' blocks, as an example
)

function main()
    @game_loop begin
        INIT(
            v2i(1600, 900), "Texture generator",
            glfw_hints = Dict(
                GLFW.DEPTH_BITS => GLFW.DONT_CARE,
                GLFW.STENCIL_BITS => GLFW.DONT_CARE,
            )
        )

        SETUP = begin
            # DSL data.
            # The user will edit the DSL in a multiline text-box.
            dsl_gui = GuiText(
                BUILTIN_FIELDS["UV"],
                is_multiline=true,
                multiline_requested_size=(0, 100),
                imgui_flags = CImGui.ImGuiInputTextFlags_AllowTabInput
            )
            current_field::AbstractField{2, 4, Float32} = ConstantField{2}(vRGBAf(0, 0, 0, 1))
            field_error_msg::Optional{String} = nothing

            function standardize_field(f::AbstractField{2})::AbstractField{2, 4, Float32}
                @nospecialize f # The type of 'f' isn't known by the caller anyway,
                                #    and there are **many** possible types of fields.
                # Cast to Float32.
                if field_component_type(f) != Float32
                    f = ConversionField(f, Float32)
                end

                # If it's greyscale, spread the greyscale value across RGB.
                if field_output_size(f) == 1
                    f = SwizzleField(f, :rrr)
                # If it's RG, add a B channel of 0.
                elseif field_output_size(f) == 2
                    f = SwizzleField(f, :rg0)
                end

                # If it's missing alpha, add an A channel of 1.
                if field_output_size(f) == 3
                    f = SwizzleField(f, :rgb1)
                end

                # If it has extra components, truncate them.
                if field_output_size(f) > 4
                    f = SwizzleField(f, :rgba)
                end

                return f
            end
            function compile_field()
                current_dsl = string(dsl_gui)

                # Parse the syntax of the DSL string.
                local ast # Stands for 'Abstract Syntax Tree'
                try
                    ast = Meta.parse(current_dsl)
                catch e
                    field_error_msg = "Syntax error: $(sprint(showerror, e))"
                    return
                end
                if !Base.is_expr(ast, :macrocall) || (ast.args[1] != Symbol("@field"))
                    field_error_msg = "Field should be defined using the @field macro"
                    return
                end

                # Convert that syntax into a Field.
                local field
                try
                    field = Bplus.Fields.eval(ast)
                catch e
                    field_error_msg = "Unable to compile your field: $(sprint(showerror, e))"
                    return
                end

                current_field = standardize_field(field) # VSCode thinks this is a new variable, but it's not
                field_error_msg = nothing
            end

            #TODO: Allow a fifth output channel which is the bumpmap of the field
            #TODO: Show/allow export of bump-map, normal-map, etc

            # Texture settings:
            tex_size = v2i(256, 256)
            tex_data_type = FormatTypes.normalized_uint
            tex_components = SimpleFormatComponents.RGB
            tex_bit_depth = SimpleFormatBitDepths.B16
            tex = Texture(SimpleFormat(tex_data_type, tex_components, tex_bit_depth), tex_size)
            clear_tex_color(tex, vRGBf(0, 0, 0))

            # execute_field() uses the current field to generate the texture's pixels.
            tex_pixels = Matrix{vRGBAf}(undef, tex_size...)
            function execute_field()
                if vsize(tex_pixels) != tex_size
                    tex_pixels = Matrix{vRGBAf}(undef, tex_size...)
                end
                sample_field!(tex_pixels, current_field)
                set_tex_color(tex, tex_pixels)
            end

            # Allow the user to save the image to a location.
            home_path_gui = GuiText(pwd(); label="Absolute Path")
            file_path_gui = GuiText("MyImage.png"; label="File Name")
            get_full_save_path() = joinpath(string(home_path_gui), string(file_path_gui))
            function save_image()
                # Convert B+ pixel type to ImageIO pixel type.
                # Also clamp the values to fit into a PNG.
                pixel_converter(v::Bplus.Math.vRGBAf) = clamp01nan(ColorTypes.RGBA(v...))
                file_pixel_data::Matrix = map(pixel_converter, tex_pixels)
                # Swap the axes or else the image will look flipped along a diagonal.
                file_pixel_data = permutedims(file_pixel_data, (2, 1))
                save(get_full_save_path(), file_pixel_data)
            end
            is_confirming_save::Bool = false

            # When the window resizes, update Dear ImGUI.
            push!(LOOP.context.glfw_callbacks_window_resized, (new_size::v2i) -> begin
                #TODO: Try using this snippet, and building this whole callback into the game loop: https://github.com/ocornut/imgui/issues/2442#issuecomment-487364993
            end)

            # Set up the initial state.
            compile_field()
            if exists(field_error_msg)
                throw(error(field_error_msg))
            end
            execute_field()

            # Bring the window to the front of the user's desktop.
            GLFW.ShowWindow(LOOP.context.window)
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break # Cleanly ends the loop
            end

            # Clear the screen to a nice background color.
            render_clear(LOOP.context, Bplus.GL.Ptr_Target(), vRGBAf(0.4, 0.4, 0.4, 1))

            # Size each sub-window in terms of the overall window size.
            window_size::v2i = Bplus.GL.get_window_size(LOOP.context)
            function size_window_proportionately(uv_space::Box2Df)
                pos = window_size * min_inclusive(uv_space)
                w_size = window_size * size(uv_space)
                CImGui.SetNextWindowPos(CImGui.ImVec2(pos...))
                CImGui.SetNextWindowSize(CImGui.ImVec2(w_size...))
            end

            # Show a GUI winndow for the text editor.
            size_window_proportionately(Box2Df(min=Vec(0.01, 0.01), max=Vec(0.5, 0.99)))
            gui_window("##Editor", C_NULL, CImGui.ImGuiWindowFlags_NoDecoration) do
                if CImGui.Button("Regenerate")
                    compile_field()
                    if isnothing(field_error_msg)
                        execute_field()
                    end
                end

                # Display any error messages:
                if exists(field_error_msg)
                    gui_with_style_color(CImGui.LibCImGui.ImGuiCol_Text, 0xFF1111FF) do
                        CImGui.Text(field_error_msg)
                    end
                end

                # Provide the DSL text editor:
                gui_with_item_width(-1) do
                    gui_text!(dsl_gui)
                end

                # Provide a selection grid for one of the built-in fields.
                CImGui.Spacing()
                CImGui.Text("Built-in fields")
                FIELDS_PER_ROW::Int = 4
                for (i, (name, value)) in enumerate(BUILTIN_FIELDS)
                    # If this isn't the first element in a row, put it next to the previous widget.
                    if !iszero((i-1) % FIELDS_PER_ROW)
                        CImGui.SameLine()
                    end
                    if CImGui.Button(name)
                        update!(dsl_gui, value)
                        compile_field()
                        if isnothing(field_error_msg)
                            execute_field()
                        end
                    end
                end
            end

            # Show a GUI window for the generated image.
            size_window_proportionately(Box2Df(min=Vec(0.5, 0.01), max=Vec(0.99, 0.5)))
            gui_window("##Image", C_NULL, CImGui.ImGuiWindowFlags_NoDecoration) do
                # Draw the image:
                CImGui.Image(Bplus.GUI.gui_tex(tex), CImGui.ImVec2(tex.size.xy...))

                # Allow the user to save/load an image.
                CImGui.Dummy(1, 50)
                CImGui.Text("Save image to disk")
                gui_text!(home_path_gui)
                gui_text!(file_path_gui)
                if CImGui.Button("Save")
                    if isfile(get_full_save_path())
                        is_confirming_save = true
                    else
                        save_image()
                    end
                end
            end

            # Show a GUI window to confirm overwriting an image file.
            if is_confirming_save
                size_window_proportionately(Box2Df(center=Vec(0.5, 0.5), size=Vec(0.25, 0.25)))
                gui_window("##ConfirmOverwrite", C_NULL, CImGui.ImGuiWindowFlags_NoDecoration) do
                    BUTTON_SIZE = v2i(100, 100)
                    BUTTON_SPACE = 50
                    dialog_size = let v = CImGui.GetWindowSize()
                        v2i(v.x, v.y)
                    end
                    spacing = (dialog_size / 2) - BUTTON_SIZE - (v2i(BUTTON_SPACE, 0) / 2)

                    CImGui.Text("Are you sure you want to overwrite this file?")
                    CImGui.Dummy(1, spacing.y - CImGui.GetTextLineHeight())

                    CImGui.Dummy(spacing.x, 1)
                    CImGui.SameLine()
                    gui_with_style_color(CImGui.ImGuiCol_Button, CImGui.ImVec4(vRGBAf(1, 0.15, 0.15, 1)...)) do
                        if CImGui.Button("Cancel", CImGui.ImVec2(BUTTON_SIZE...))
                            is_confirming_save = false
                        end
                    end
                    CImGui.SameLine()
                    CImGui.Dummy(BUTTON_SPACE, 1)
                    CImGui.SameLine()
                    if CImGui.Button("Confirm", CImGui.ImVec2(BUTTON_SIZE...))
                        is_confirming_save = false
                        save_image()
                    end

                    CImGui.SameLine()
                    CImGui.Dummy(spacing.x, 1)

                    CImGui.Dummy(1, spacing.y)
                end
            end
        end
    end
end

end # module