##   Commands   ##

# Typical "turtle graphics" drawing commands.
# Each character in the L-system string may map to a command.
@bp_enum(Commands,
    pitch, yaw, roll,
    spawn,
    scale,
    shift_hue, shift_saturation, shift_lightness,
    push, pop,
)

const COMMAND_CHARS = Dict{E_Commands, AsciiChar}(
    Commands.pitch => 'P',
    Commands.yaw => 'Y',
    Commands.roll => 'R',

    Commands.spawn => '*',

    Commands.scale => 'C',

    Commands.shift_hue => 'H',
    Commands.shift_saturation => 'S',
    Commands.shift_lightness => 'L',

    Commands.push => '[',
    Commands.pop => ']'
)
const CHAR_COMMANDS = Dict{AsciiChar, E_Commands}(
    (ca => co) for (co, ca) in COMMAND_CHARS
)

const COMMAND_GUI_NAMES = map(Commands.instances()) do cmd
    output = Vector{Char}()
    capitalize_next::Bool = true
    for char::Char in string(cmd)
        if char == '_'
            push!(output, ' ')
            capitalize_next = true
        else
            if capitalize_next
                char = uppercase(char)
                capitalize_next = false
            end
            push!(output, char)
        end
    end
    return String(output)
end


"Parameters for the various commands. Angles are in degrees."
@kwdef mutable struct CommandSettings
    pitch::Float32 = 15
    yaw::Float32 = 15
    roll::Float32 = 15

    initial_scale::Float32 = 0.7
    length_step_scale::Float32 = 0.4
    thickness_step_scale::Float32 = 0.3

    initial_color::vRGBf = vRGBf(1, 0.3, 0.01)
    hsl_shift::v3f = v3f(0.2, -0.2, -0.2)

    # The above settings become smaller and smaller as you go deeper in the tree,
    #    by scaling them down with these values:
    depth_shrink_scale_change::Float32 = 1.0
    depth_shrink_pitch::Float32 = 0.8
    depth_shrink_yaw::Float32 = 0.8
    depth_shrink_roll::Float32 = 0.8
    depth_shrink_hsl_shift::v3f = v3f(0.5, 0.6, 0.7)
end


##   Rendering   ##

struct RenderInstance
    depth::UInt16
    pos::v3f
    local_scale::v3f
    rotation::fquat
    color::vRGBf
end

function render(instance::RenderInstance,
                mesh::Bplus.GL.Mesh, prog::Bplus.GL.Program,
                mat_viewproj::fmat4)
    mat_world::fmat4 = m4_world(
        instance.pos,
        instance.rotation,
        instance.local_scale
    )
    mat_world_normals::fmat3 = m_transpose(m_invert(m_to_mat3x3(mat_world)))

    set_uniform(prog, "u_mat_points_to_world", mat_world)
    set_uniform(prog, "u_mat_normals_to_world", mat_world_normals)
    set_uniform(prog, "u_mat_world_to_ndc", mat_viewproj)
    set_uniform(prog, "u_color", instance.color)

    render_mesh(mesh, prog)
end

function build_render_instances(input::AsciiString,
                                output::Vector{RenderInstance},
                                settings::CommandSettings
                                ;
                                initial_pos::v3f = zero(v3f),
                                initial_rot::fquat = fquat()
                                )::Nothing
    # Turtle graphics works with a stack of render states.
    state_stack = Stack{RenderInstance}()
    push!(state_stack, RenderInstance(
        0,
        initial_pos,
        v3f(i -> settings.initial_scale),
        initial_rot,
        settings.initial_color
    ))

    for command_char in input
        command::Optional{E_Commands} = get(CHAR_COMMANDS, command_char, nothing)
        if isnothing(command)
            continue
        end

        # Stack commands:
        if command in (Commands.push, Commands.pop)
            if command == Commands.push
                next_state = top(state_stack)
                @set! next_state.depth += 1
                push!(state_stack, next_state)
            elseif command == Commands.pop
                pop!(state_stack)
            else
                error("Stack command: ", command)
            end
        # Spawn command:
        elseif command == Commands.spawn
            current_state = pop!(state_stack)
            push!(output, current_state)
            # Move the current position to the tip of the newly-spawned instance.
            @set! current_state.pos += current_state.local_scale.z * 3 * #TODO: update the mesh so it's 1 tall in Z
                                       q_basis(current_state.rotation).up
            push!(state_stack, current_state)
        # State commands:
        else
            current_state = pop!(state_stack)
            new_state = current_state

            # Rotation commands:
            if command in (Commands.pitch, Commands.yaw, Commands.roll)
                basis = q_basis(new_state.rotation)

                new_rot = fquat()
                if command == Commands.pitch
                    angle = settings.pitch * (settings.depth_shrink_pitch ^ current_state.depth)
                    new_rot = Quaternion(basis.right, deg2rad(angle))
                elseif command == Commands.yaw
                    angle = settings.yaw * (settings.depth_shrink_yaw ^ current_state.depth)
                    new_rot = Quaternion(basis.up, deg2rad(angle))
                elseif command == Commands.roll
                    angle = settings.roll * (settings.depth_shrink_roll ^ current_state.depth)
                    new_rot = Quaternion(basis.forward, deg2rad(angle))
                else
                    error("Rotation: ", command)
                end

                @set! new_state.rotation >>= new_rot
            # Color commands:
            elseif command in (Commands.shift_hue, Commands.shift_saturation, Commands.shift_lightness)
                color_hsl = convert(HSL, RGB(new_state.color...))
                # Hue is 0-360 in the Colors package.
                @set! color_hsl.h /= 360

                if command == Commands.shift_hue
                    @set! color_hsl.h = fract(color_hsl.h + settings.hsl_shift.x)
                elseif command == Commands.shift_saturation
                    @set! color_hsl.s = saturate(color_hsl.s + settings.hsl_shift.y)
                elseif command == Commands.shift_lightness
                    @set! color_hsl.l = saturate(color_hsl.l + settings.hsl_shift.z)
                else
                    error("Color: ", command)
                end

                @set! color_hsl.h *= 360
                color_rgb = convert(RGB, color_hsl)
                @set! new_state.color = vRGBf(red(color_rgb), green(color_rgb), blue(color_rgb))
            # Scale command:
            elseif command == Commands.scale
                @set! new_state.local_scale *= v3f(
                    settings.thickness_step_scale,
                    settings.thickness_step_scale,
                    settings.length_step_scale
                )
            else
                error("State command: ", command)
            end

            push!(state_stack, new_state)
        end
    end

    return nothing
end