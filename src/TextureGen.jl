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

using Bplus,
      Bplus.Utilities,
      Bplus.Math, Bplus.GL, Bplus.SceneTree,
      Bplus.Input, Bplus.GUI, Bplus.Helpers,
      Bplus.Fields

const BUILTIN_FIELDS = Dict{String, String}(
    "UV" => "pos",
    "Clouds" => "perlin(pos * 3)",
    "Uneven Clouds" => "perlin({ pos.x * 2, pos.y * 30 })",

    # This one is a multiline field.
    "Stripes" => "
# Declare some local variables
let body = 0.5 + (0.5 * sin(pos.x * 26)), # Oscillate between 0 and 1
    details = 0.25 * lerp(-1, 1, perlin(pos * 16)) # Small signed pertubations
  clamp(body + details, 0, 1) # Output Red value between 0 and 1, automatically copied to Green and Blue
end
",

    #TODO: "Ripples" => "clamp(sin(distance(pos, 0.5) * 10), 0, 1)",
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
            # Adds or removes extra components as necessary to make a field have 4 output components.
            # This way the user can specify e.x. only RG components and the rest are filled in.
            function pad_field_components(f::AbstractField{2, NOut, Float32}) where {NOut}
                # Base case.
                if NOut == 4
                    return f
                # If it's missing an alpha component, append a constant alpha of 1.
                elseif NOut == 3
                    return AppendField(f, ConstantField{2}(Vec(@f32 1)))
                # If it's missing color components, append 0 for them until we hit another case.
                elseif NOut < 3
                    return pad_field_components(
                        AppendField(f, ConstantField{2}(Vec(@f32 0)))
                    )
                # If it has extra fields, truncate them.
                elseif NOut > 4
                    return SwizzleField(f, :xyzw)
                else
                    error("Invalid case: ", NOut)
                end
            end

            # DSL data.
            # Dear ImGUI works with C-strings, so the DSL string is stored as a byte buffer.
            current_dsl_c_buffer = Vector{UInt8}(undef, 4096)
            current_field::AbstractField{2, 4, Float32} = ConstantField{2}(vRGBAf(0, 0, 0, 1))
            field_error_msg::Optional{String} = nothing
            function load_dsl_string(s::String)
                bytes = codeunits(s)
                copyto!(current_dsl_c_buffer, bytes)
                # Add a null terminator.
                current_dsl_c_buffer[length(bytes) + 1] = 0
            end
            load_dsl_string(BUILTIN_FIELDS["UV"])

            function compile_field()
                # Make sure we can see the above variables by trying to access them.
                # Otherwise, if we set them later in this function,
                #    we'll just be making new local variables that hide them.
                #TODO: Test this is really needed. If so, make a helper macro for it.
                _ = isnothing(current_field)
                _ = isnothing(field_error_msg)
                _ = isnothing(current_dsl_c_buffer)

                # Copy the C string into our Julia string.
                null_terminator_idx::Optional{Int} = findfirst(iszero, current_dsl_c_buffer)
                if isnothing(null_terminator_idx)
                    field_error_msg = "Couldn't find the null terminator in the C string buffer"
                    return
                end
                current_dsl = String(@view current_dsl_c_buffer[1 : null_terminator_idx-1])

                # Parse the syntax of the DSL string.
                ast = Ref{Any}()
                try
                    ast[] = Meta.parse(current_dsl)
                catch e
                    field_error_msg = "Unable to parse your field's syntax: $(sprint(showerror, e))"
                    return
                end

                # Convert that syntax into a Field.
                field = Ref{Any}()
                try
                    field[] = field_from_dsl(ast[], DslContext(2, Float32))
                catch e
                    field_error_msg = "Unable to parse/compile your field: $(sprint(showerror, e))"
                    return
                end

                # Pad the field's components to make it RGBA.
                # If it's a multi-expression field, we need to pad the last expression specifically.
                if field[] isa AbstractField
                    field[] = pad_field_components(field[])
                elseif field[] isa MultiField
                    field[] = MultiField(field[].sequence,
                                         pad_field_components(field[].finale))
                else
                    error("Unexpected type of parsed DSL: ", typeof(field[]))
                end

                field_error_msg = nothing
                current_field = field[]
            end

            #TODO: Allow a fifth output which is the bumpmap of the field

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

            # Set up the initial state.
            compile_field()
            if exists(field_error_msg)
                throw(error(field_error_msg))
            end
            execute_field()
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break # Cleanly ends the loop
            end

            # Clear the screen to a nice background color.
            render_clear(LOOP.context, Bplus.GL.Ptr_Target(), vRGBAf(0.4, 0.4, 0.4, 1))

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
            dsl_changed::Bool = @c CImGui.InputTextMultiline(
                "Field",
                &current_dsl_c_buffer[0], length(current_dsl_c_buffer),
                (0, 100),
                CImGui.ImGuiInputTextFlags_AllowTabInput
            )

            # Draw the image:
            CImGui.Image(Bplus.GUI.gui_tex(tex), CImGui.ImVec2(tex.size.xy...))

            # Provide a selection grid for one of the built-in fields.
            FIELDS_PER_ROW::Int = 3
            for (i, (name, value)) in enumerate(BUILTIN_FIELDS)
                # If this isn't the first element in a row, put it next to the previous widget.
                if !iszero((i-1) % FIELDS_PER_ROW)
                    CImGui.SameLine()
                end
                if CImGui.Button(name)
                    load_dsl_string(value)
                    compile_field()
                    if isnothing(field_error_msg)
                        execute_field()
                    end
                end
            end
        end
    end
end

end # module