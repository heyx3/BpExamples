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

    spawn_length_scale::Float32 = 1
    initial_scale::Float32 = 1

    hsv_shift::v3f = v3f(0.2, -0.2, -0.2)
end

