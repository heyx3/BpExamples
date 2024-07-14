"A very simple synth made from scratch, using Bplus.Fields and some external Julia audio packages"
module ToySynth


# This program has multiple different threads:
#   1. Audio generator, 


# Import audio generation:
using LibSndFile, PortAudio, SampledSignals, FileIO

# Import window and GUI libs:
using GLFW, CImGui
const LibCImGui = CImGui.LibCImGui

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


"
A constant sampling rate for the synth, for simplicity.
PortAudio can resample it for us when writing to the speakers.
"
const SYNTH_SAMPLE_RATE = 44100

"
Named preset waveforms, each represented as a factory function
  `(n_channels, sample_float_type) -> AbstractField{1, n_channels, sample_float_type}`.
"
const SYNTH_BUILTINS = Dict(
    :Pure => (N, F) -> Bplus.Fields.SwizzleField(
        Bplus.Fields.SinField(
            Bplus.Fields.MultiplyField(
                Bplus.Fields.PosField{1, F}(),
                Bplus.Fields.ConstantField{1}(Vec{1, F}(
                    440 * (2 * 3.1415927)
                ))
            )
        ),
        ntuple(i->1, Val(N))...
    )
)

"Our audio generator, which can be directly written to an `AudioSink`"
mutable struct SynthAudioSource{NChannels, FSample<:AbstractFloat} <: SampledSignals.SampleSource
    # A function mapping time (in seconds) to an audio sample.
    source::Bplus.Fields.AbstractField{1, NChannels, FSample}

    # The absolute index of the next sample to be written.
    next_sample_idx::Int

    # Whether the synth should close.
    should_close::Bool

    SynthAudioSource(source::Bplus.Fields.AbstractField{1, NChannels, FSample},
                     next_sample_idx::Int = 0
                    ) where {NChannels, FSample} = new{NChannels, FSample}(source, next_sample_idx, false)
    SynthAudioSource{NChannels, FSample}() where {NChannels, FSample} = new{NChannels, FSample}(
        SYNTH_BUILTINS[:Pure](NChannels, FSample),
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
    #DEBUG: Hard-coded sine wave.
    local_sample_idcs = (1:sample_count) .+ buf_offset
    absolute_sample_idcs = (1:sample_count) .+ (s.next_sample_idx - 1)
    if true
        frequency = 440 * 3.1415925 * 2
        samples[local_sample_idcs, 1:N] = sin.(
            absolute_sample_idcs .* (frequency * sample_time_increment)
        )
        # println("\tSamples (", sample_count, " total): ",
        #         samples[first(local_sample_idcs), 1], " ... ",
        #         samples[(first(local_sample_idcs) + last(local_sample_idcs)) ÷ 2, 1], " ... ",
        #         samples[last(local_sample_idcs), 1])
    else
        # Do this in an inner lambda which will know the field's type at compile-time by paying an up-front JIT cost,
        #    otherwise we'd pay that cost for every individual call to sample the field.
        function do_sampling(f::AbstractField)
            field_prep = Bplus.Fields.prepare_field(f)
            #TODO: Pretty sure multi-channel doesn't work right yet, due to axes being out-of-order.
            samples[local_sample_idcs, 1:N] = Bplus.Fields.get_field.(
                Ref(f),
                absolute_sample_idcs .* sample_time_increment,
                Ref(field_prep)
            )
        end
        do_sampling(s.source)
    end

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
            # Start the synth and link it to this computer's default speakers.
            if Threads.nthreads() < 2
                @error string("Julia is running single-threaded! ",
                              "The ToySynth project will likely encounter audio stuttering. ",
                              "Pass `-t auto` or `-t 4` when starting Julia.")
            end
            synth = SynthAudioSource{1, Float32}()
            stream = PortAudioStream(0, 1, latency=0.2)
            @async write(stream, synth)
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window)
                break # Exit the game loop
            end

            # Reserve the top of the screen for any warnings or important messages.
            vertical_offset::Int = 0
            # [none yet]

            # Our GUI layout:
            #=
                  Wave math text editor      |   Volume slider
                                             |
                                             |----------------------------------------------
                                             |    Wave math file envelope and file output
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
                CImGui.Text("#TODO: Wave math text editor")
            end

            # Volume slider:
            Bplus.GUI.gui_next_window_space(Box2Df(min=v2f(0.5, 0.0), max=v2f(1, 0.15)),
                                            v2i(GUI_BORDER, GUI_BORDER),
                                            v2i(0, vertical_offset))
            Bplus.GUI.gui_window("Volume", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                CImGui.Text("#TODO: Volume slider")
            end

            # Wave file output:
            Bplus.GUI.gui_next_window_space(Box2Df(min=v2f(0.5, 0.15), max=v2f(1, 0.6)),
                                            v2i(GUI_BORDER, GUI_BORDER),
                                            v2i(0, vertical_offset))
            Bplus.GUI.gui_window("File Output", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                CImGui.Text("#TODO: File output (with envelope)")
            end

            # Waveform compiler/grapher:
            Bplus.GUI.gui_next_window_space(Box2Df(min=v2f(0, 0.6), max=v2f(1, 1)),
                                            v2i(GUI_BORDER, GUI_BORDER),
                                            v2i(0, vertical_offset))
            Bplus.GUI.gui_window("Viewer", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                CImGui.Text("#TODO: Waveform compiler/grapher")
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