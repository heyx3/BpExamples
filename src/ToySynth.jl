"A very simple synth made from scratch, using Bplus.Fields and some external Julia audio packages"
module ToySynth

# Import audio generation:
using LibSndFile, PortAudio, SampledSignals, FileIO

# Import window and GUI libs:
using GLFW, CImGui
const LibCImGui = CImGui.LibCImGui
using CSyntax # The '@c' macro simplifies CImGui calls

# Import B+:
using Bplus; @using_bplus


# Extend the B+ Fields DSL with 'oscillate(a, b, t, period=1, sharpness=1, dullness=0, phase=0)',
#    which blends between two values using a sine wave.
const OSCILLATOR_TAG = :TOY_SYNTH_OSCILLATE
function OscillateField(a::AbstractField{NIn, NOut, F},
                        b::AbstractField{NIn, NOut, F},
                        t::AbstractField{NIn, 1, F},
                        period::AbstractField{NIn, 1, F} = Bplus.Fields.ConstantField{NIn}(Vec{1, F}(1)),
                        sharpness::AbstractField{NIn, 1, F} = Bplus.Fields.ConstantField{NIn}(Vec{1, F}(1)),
                        dullness::AbstractField{NIn, 1, F} = Bplus.Fields.ConstantField{NIn}(Vec{1, F}(0)),
                        phase::AbstractField{NIn, 1, F} = Bplus.Fields.ConstantField{NIn}(Vec{1, F}(0))
                       ) where {NIn, NOut, F}
    raw_sine_field = Bplus.Fields.LerpField(
        Bplus.Fields.ConstantField{1}(Vec{1, F}(0.5)),
        Bplus.Fields.ConstantField{1}(Vec{1, F}(1.0)),
        Bplus.Fields.SinField(
            Bplus.Fields.MultiplyField(
                Bplus.Fields.ConstantField{1}(Vec{1, F}(3.14159265 * 2)),
                Bplus.Fields.AddField(
                    phase,
                    Bplus.Fields.MultiplyField(
                        period,
                        t
                    )
                )
            )
        )
    )
    #TODO: re-use the raw_sine_field computation somehow 

    dull_target_field = Bplus.Fields.StepField(
        Bplus.Fields.ConstantField{NIn}(Vec{1, F}(0.5)),
        raw_sine_field
    )

    output_t_field = Bplus.Fields.PowField(
        Bplus.Fields.LerpField(
            raw_sine_field,
            dull_target_field,
            dullness
        ),
        sharpness
    )

    output = Bplus.Fields.LerpField(a, b, output_t_field)
    return Bplus.Fields.AggregateField{OSCILLATOR_TAG}(output)
end
@inline function Bplus.Fields.dsl_from_field(::Bplus.Fields.AggregateField{OSCILLATOR_TAG},
                                             args...)
    return :( oscillate($(dsl_from_field.(args)...)) )
end
function Bplus.Fields.field_from_dsl_func(::Val{:oscillate},
                                          context::DslContext,
                                          state::DslState,
                                          args::Tuple)
    return OscillateField(Bplus.Fields.field_from_dsl.(args, Ref(context), Ref(state))...)
end

#TODO: If wave generator's input is 2D, compute samples serially and use the previous sample value as the 'y' coordinate.
#TODO: Generate wave-form to an array, then let a list of "filter" Fields sample from it to generate filtered output.



"
A constant sampling rate for the synth, for simplicity.
PortAudio can resample it for us when writing to the speakers.
"
const SYNTH_SAMPLE_RATE = 44100

"
Named preset waveforms, each represented as a factory function
  `(n_channels, sample_float_type) -> String`
"
const SYNTH_BUILTINS = Dict(
    "Pure" => """sin(
        pos * 440 * (2 * 3.1415927)
    )""",

    "Spaceship" => """sin(
        (
            pow(sin(pos * 20), 3) *
            sin(pos * 3) *
            500
        ) + 
        (
            sin(pos * 200) *
            6
        )
    )""",

    "Train" => """1.5 * lerp(
        oscillate(-1, 0, pos, 10, 1, 0.4),
        oscillate(0, 1, pos, 33, 1, 0, 0),
        perlin(pos * 700)
    )""",

    "Alarm" => """lerp(-1, 1,
        pow(perlin((pos * 300) +
                   oscillate(0, 100, pos, 1, 4, 0.8)),
            0.63)
    ) * tan(pos * 1.4)
    """
)
# For display purposes, tab out the builtin waveform code.
for name in collect(keys(SYNTH_BUILTINS))
    SYNTH_BUILTINS[name] = replace(SYNTH_BUILTINS[name],
                                   r"        ^ "=>"    ", r"\t\t^\t"=>"\t")
end


"Loads a builtin synth waveform. Returns a fallback if the given name doesn't exist"
function load_builtin_synth(n_channels::Int, sample_type::DataType, name::String)::Bplus.Fields.AbstractField
    if !haskey(SYNTH_BUILTINS, name)
        return Bplus.Fields.ConstantField{1}(zero(Vec{n_channels, sample_type}))
    else
        ast = Meta.parse(SYNTH_BUILTINS[name])
        raw_field = Bplus.Fields.field_from_dsl(
            ast,
            Bplus.Fields.DslContext(1, sample_type)
        )
        if n_channels == 1
            return raw_field
        else
            # All channels come from the single output of the field.
            return Bplus.Fields.SwizzleField(raw_field, ntuple(i->1, n_channels)...)
        end
    end
end


"Our audio generator, which can be directly written to an `AudioSink`"
mutable struct SynthAudioSource{NChannels, FSample<:AbstractFloat} <: SampledSignals.SampleSource
    # A function mapping time (in seconds) to an audio sample.
    source::Bplus.Fields.AbstractField{1, NChannels, FSample}
    # A flat multiplier on the synth's output.
    volume::FSample

    # The absolute index of the next sample to be written.
    next_sample_idx::Int

    # Whether the synth should close.
    should_close::Bool

    SynthAudioSource(source::Bplus.Fields.AbstractField{1, NChannels, FSample},
                     volume::FSample = one(FSample),
                     next_sample_idx::Int = 0
                    ) where {NChannels, FSample} = new{NChannels, FSample}(source, volume, next_sample_idx, false)
    SynthAudioSource{NChannels, FSample}(volume = 1.0) where {NChannels, FSample} = new{NChannels, FSample}(
        load_builtin_synth(NChannels, FSample, "Pure"),
        convert(FSample, volume),
        0,
        false
    )
end

# Implement the audio-source interface for our synth:
SampledSignals.samplerate(::SynthAudioSource) = SYNTH_SAMPLE_RATE
SampledSignals.nchannels(::SynthAudioSource{NChannels}) where {NChannels} = NChannels
SampledSignals.eltype(::SynthAudioSource{NChannels, FSample}) where {NChannels, FSample} = FSample

# Implement the actual audio sample generation for our synth:
function SampledSignals.unsafe_read!(s::SynthAudioSource{N, F}, samples::Array,
                                     buf_offset, sample_count
                                    )::typeof(sample_count) where {N, F}
    if s.should_close
        return zero(typeof(sample_count))
    end

    # Sample the field's values to get the waveform.
    sample_time_increment::Vec{1, F} = one(Vec{1, F}) / SYNTH_SAMPLE_RATE
    local_sample_idcs = (1:sample_count) .+ buf_offset
    absolute_sample_idcs = (1:sample_count) .+ (s.next_sample_idx - 1)

    # Do this in an inner lambda which will know the field's type at compile-time by paying an up-front JIT cost,
    #    otherwise we'd pay that cost for every individual call to sample the field.
    function do_sampling(field::AbstractField)
        #TODO: Pretty sure multi-channel doesn't work right yet, due to axes being out-of-order.
        field_prep = Bplus.Fields.prepare_field(field)
        # Use Julia's broadcast operator ('.') to succinctly and efficiently generate all buffer samples at once.
        # Note that 'Ref(x)' is used to broadcast one value 'x' across all instances of the computation.
        samples[local_sample_idcs, 1:N] = s.volume .* clamp.(Bplus.Fields.get_field.(
            Ref(field),
            absolute_sample_idcs .* sample_time_increment,
            Ref(field_prep)
        ),   #= Clamp min =# Ref(-one(F)),    #= Clamp max =# Ref(one(F)))
    end
    do_sampling(s.source)

    # Move forward in time.
    s.next_sample_idx += sample_count

    return sample_count
end


function main()
    Bplus.@game_loop begin
        INIT(
            v2i(1600, 900),
            "Toy Synth",
            # Turn vsync off so the audio task has plenty of time to run, even in single-threaded Julia
            vsync = Bplus.GL.VsyncModes.off
        )

        SETUP = begin
            elapsed_seconds::Float64 = 0

            # Start the synth and link it to this computer's default speakers.
            if Threads.nthreads() < 2
                @error string("Julia is running single-threaded! ",
                              "The ToySynth project will likely encounter audio stuttering. ",
                              "Pass `-t auto` or `-t 4` when starting Julia.")
            end
            synth = SynthAudioSource{1, Float64}()
            stream = PortAudioStream(0, 1, latency=0.2)
            @async write(stream, synth)

            # Provide a GUI text editor for the synth code.
            synth_code_gui = Bplus.GUI.GuiText(
                string(dsl_from_field(synth.source)),

                is_multiline = true,
                label = " = w(pos)"
            )
            synth_code_changed::Bool = false

            # Provide a GUI to visualize the waveform over time.
            #TODO: Make these parameters editable
            WAVE_GUI_N_SAMPLES::Int = 512
            WAVE_GUI_WINDOW_SECONDS::Float64 = 0.01
            WAVE_GUI_SAMPLE_RATE::Float64 = WAVE_GUI_N_SAMPLES / WAVE_GUI_WINDOW_SECONDS
            WAVE_GUI_ANIMATION_WAVE_SECONDS_PER_REAL_SECOND::Float64 = 0.01
            waveform_animation_next_sample_idx::UInt = 0
            # Dear ImGUI plot samples are float32, but our samples are float64,
            #    so we need to cast them.
            waveform_gui_samples_raw = fill(zero(Vec{1, Float64}), WAVE_GUI_N_SAMPLES)
            waveform_gui_samples     = fill(zero(Vec{1, Float32}), WAVE_GUI_N_SAMPLES)
            function gui_waveform()
                # Resample the waveform at the current simulated time.
                Bplus.Fields.sample_field!(
                    waveform_gui_samples_raw, synth.source,
                    use_threading=false,
                    sample_space=Bplus.Box1Dd(
                        min = Vec(waveform_animation_next_sample_idx / WAVE_GUI_SAMPLE_RATE),
                        size = Vec(WAVE_GUI_WINDOW_SECONDS)
                    )
                )
                waveform_gui_samples = convert.(Ref(Vec{1, Float32}), waveform_gui_samples_raw)

                # Plot this data.
                CImGui.PlotLines(
                    "##Waveform", waveform_gui_samples, length(waveform_gui_samples),
                    0, C_NULL,
                    -1, 1,
                    (0, round(Int, CImGui.GetWindowHeight() - 100))
                )

                # Calculate how many new samples we should step forward by.
                animation_delta_seconds::Float64 = LOOP.delta_seconds * WAVE_GUI_ANIMATION_WAVE_SECONDS_PER_REAL_SECOND
                n_new_samples = max(1, round(Int, animation_delta_seconds * SYNTH_SAMPLE_RATE))
                n_new_samples = min(n_new_samples, WAVE_GUI_N_SAMPLES)
                waveform_animation_next_sample_idx += n_new_samples
            end
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break # Exit the game loop
            end
            elapsed_seconds += LOOP.delta_seconds

            # Reserve the top of the screen for any warnings or important messages.
            vertical_offset::Int = 0
            # [none yet]

            # Our GUI layout:
            #=
                  Wave math text editor      |   Volume slider
                                             |
                                             |----------------------------------------------
                                             |    TBD
                                             |
                                             |
                                             |
                                             |
                -----------------------------------------------------------------------------
                   Wave math compiler/graph



            =#
            GUI_BORDER::Int = 3

            # Wave math text editor:
            Bplus.GUI.gui_next_window_space(Box2Df(min=v2f(0, 0), max=v2f(0.5, 0.6)),
                                            v2i(GUI_BORDER, GUI_BORDER),
                                            v2i(0, vertical_offset))
            Bplus.GUI.gui_window("Waveform", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                synth_code_gui.multiline_requested_size = (
                    0,
                    round(Int, CImGui.GetWindowHeight() - 80)
                )
                synth_code_changed |= Bplus.GUI.gui_text!(synth_code_gui)

                # Buttons to pick presets:
                for (i, (name, code)) in enumerate(SYNTH_BUILTINS)
                    ((i%4) != 1) && CImGui.SameLine()
                    if CImGui.Button(name)
                        Bplus.GUI.update!(synth_code_gui, code)
                        synth.source = load_builtin_synth(1, Float64, name)
                        synth_code_changed = false # Because we just compiled it ourselves
                    end
                end
            end

            # Volume slider:
            Bplus.GUI.gui_next_window_space(Box2Df(min=v2f(0.5, 0.0), max=v2f(1, 0.15)),
                                            v2i(GUI_BORDER, GUI_BORDER),
                                            v2i(0, vertical_offset))
            Bplus.GUI.gui_window("Volume", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                vol_f32 = convert(Float32, synth.volume)
                @c CImGui.SliderFloat("Volume", &vol_f32,
                                      zero(Float32), one(Float32))
                synth.volume = vol_f32
            end

            # Wave file output:
            Bplus.GUI.gui_next_window_space(Box2Df(min=v2f(0.5, 0.15), max=v2f(1, 0.6)),
                                            v2i(GUI_BORDER, GUI_BORDER),
                                            v2i(0, vertical_offset))
            Bplus.GUI.gui_window("TBD", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                # Nothing for now
            end

            # Waveform compiler/grapher:
            Bplus.GUI.gui_next_window_space(Box2Df(min=v2f(0, 0.6), max=v2f(1, 1)),
                                            v2i(GUI_BORDER, GUI_BORDER),
                                            v2i(0, vertical_offset))
            Bplus.GUI.gui_window("Viewer", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                # Disable the button if no compilation is needed.
                (!synth_code_changed) && CImGui.PushStyleColor(
                    CImGui.LibCImGui.ImGuiCol_Button,
                    CImGui.ImVec4(0.6, 0.6, 0.6, 1.0)
                )
                if CImGui.Button("Compile waveform") && synth_code_changed
                    try
                        ast = Meta.parse(string(synth_code_gui))
                        synth.source = Bplus.Fields.field_from_dsl(
                            ast,
                            Bplus.Fields.DslContext(1, Float64)
                        )
                    catch e
                        @error "Unable to parse your waveform. " ex=(e, catch_backtrace())
                    end
                end
                # Un-disable the GUI.
                (!synth_code_changed) && CImGui.PopStyleColor()

                # Plot the waveform.
                CImGui.Text("Waveform at $(round(waveform_animation_next_sample_idx / WAVE_GUI_SAMPLE_RATE, digits=3))s")
                CImGui.SameLine()
                gui_waveform()
            end

            # It's important to give other tasks (like audio interrupts) more time,
            #    especially since Julia runs single-threaded by default.
            yield()
        end
        TEARDOWN = begin
            synth.should_close = true
            sleep(1)
            close(stream)
        end
    end
end


end # module