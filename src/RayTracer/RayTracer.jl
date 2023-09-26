"Loosely based on *Ray-Tracing in a Weekend*"
module RayTracer

# External dependencies:
using GLFW, # The underlying window/input library used by B+
      CImGui, # The main GUI library integrated with B+
      Setfield # Helper macros ('@set!') to "modify" immutable data by copying it

# B+:
using Bplus,
      Bplus.Utilities,
      Bplus.Math, Bplus.GL,
      Bplus.Input, Bplus.GUI, Bplus.Helpers


# When debugging multithreaded apps, it helps to have thread-safe logging.
const LOG_ENABLED = false
const LOGGER = Ref{IO}(stdout)
const LOG_LOCKER = ReentrantLock()
function change_log_destination(dest::IO)
    lock(() -> (LOGGER[] = dest), LOG_LOCKER)
end
macro threaded_log(args...)
    if LOG_ENABLED
        args = esc.(args)
        return :(
            lock(() -> println(LOGGER[], $(args...)), LOG_LOCKER)
        )
    else
        return :( )
    end
end


include("utils.jl")
include("types.jl")

include("hitables.jl")
include("skies.jl")
include("materials.jl")

include("logic.jl")
include("render_task.jl")

const INITIAL_WINDOW_SIZE = 1000

const WORLD = World(
    # Objects:
    [
        # Floor
        H_Plane(v3f(0, 0, 0), v3f(0, 0, 1)) =>
            M_Lambertian(vRGBf(0.3, 0.85, 0.3)),

        # Random balls
        H_Sphere(v3f(8, 8, 1),     @f32(3.2)) => M_Lambertian(vRGBf(1,   0.5,   0.5)),
        H_Sphere(v3f(-8, 8, -0.5), @f32(3.0)) => M_Metal(     vRGBf(0.9, 0.825, 0.23), 0.01),
        H_Sphere(v3f(-8, -8, -8),  @f32(10)) =>  M_Metal(     vRGBf(0.9, 0.825, 0.23), 0.75),
        H_Sphere(v3f(8, 8, 8),     @f32(1.5)) => M_Dielectric(vRGBf(1.0, 1.0,   1.0), 2.0),

        # A rotated box
        H_Box(v3f(0, 0, 3.1), v3f(1, 2, 3), fquat(vnorm(v3f(1, 2, 3)), π*0.42)) =>
            M_Lambertian(vRGBf(0.1, 0.2, 0.15))
    ],

    # Sky:
    S_Plain(
        vRGBf(0.5, 0.5, 1.0),
        vRGBf(0.1, 0.1, 0.8),
        @f32(1.5)
    ),

    12345, 0
)


function main()
    @game_loop begin
        INIT(
            v2i(INITIAL_WINDOW_SIZE, INITIAL_WINDOW_SIZE), "B+ Ray-Tracer",
            vsync=VsyncModes.on,
            glfw_hints = Dict(
                GLFW.DEPTH_BITS => GLFW.DONT_CARE,
                GLFW.STENCIL_BITS => GLFW.DONT_CARE,
                GLFW.RESIZABLE => true
            )
        )

        SETUP = begin
            # The ray-tracer runs better with multithreading.
            if Threads.nthreads() == 1
                @warn "Julia is only running with 1 thread! RayTracer is faster with more threads. Pass '-t auto' when starting Julia to use all threads."
            end

            # Ray-tracers naturally have a very low framerate.
            # So increase the cap on this game loop's frame duration.
            # Units are in seconds.
            LOOP.max_frame_duration = 0.3

            # Configure the world and viewport.
            viewport = Viewport(
                Cam3D{Float32}(
                    pos = v3f(10, 10, 10),
                    forward = vnorm(v3f(-1, -1, -1)),
                    up = v3f(0, 0, 1),

                    fov_degrees = 60,
                    aspect_width_over_height = let s = get_window_size(LOOP.context.window)
                        s.x / s.y
                    end,

                    # Near/far clipping plane isn't used for ray-tracing.
                    clip_range = IntervalF(min=0.01, max=10.0)
                ),
                Cam3D_Settings{Float32}(
                    move_speed = 5,
                    turn_speed_degrees = 4
                    # Rest of the settings are fine with their defaults
                )
            )
            # Keep the rendering on its own thread (see "render_task.jl" for the implementation).
            renderer = RenderTask(
                # Mini-renders:
                RenderSettings(
                    max(one(v2i), get_window_size() ÷ 16),
                    2,
                    1
                ),
                # Full-size renders:
                RenderSettings(
                    get_window_size() ÷ 8,
                    5,
                    50
                ),
                WORLD, viewport
            )

            # Set up input.
            configure_world_inputs()
            Bplus.Input.create_button("quit", Bplus.Input.ButtonInput(GLFW.KEY_ESCAPE))
            GLFW.SetInputMode(LOOP.context.window, GLFW.CURSOR, GLFW.CURSOR_DISABLED)

            # When the window size changes, update the world data accordingly.
            push!(LOOP.context.glfw_callbacks_window_resized, new_size::v2i -> begin
                @set! viewport.cam.aspect_width_over_height = Float32(new_size.x / new_size.y)

                # Replace the renderer with a different-sized one.
                close(renderer)
                renderer = RenderTask(
                    # Resize the mini and full renderer settings to match the new window size.
                    # '@set' returns a modified copy of some data.
                    let setting = renderer.mini_render_settings
                        @set setting.resolution = max(one(v2i), new_size ÷ 16)
                    end,
                    let setting = renderer.full_render_settings
                        @set setting.resolution = new_size
                    end,
                    (viewport.cam, WORLD.current_frame),
                    renderer.full_render_delay_seconds
                )
            end)

            # To draw to the screen, we'll need to dump the ray-tracer results into a GL texture
            #    and render that to the screen.
            # The ray-tracer will generate textures of various sizes.
            screen_textures = Dict{v2u, Bplus.GL.Texture}()
            newest_texture = Ref{Bplus.GL.Texture}()
            function update_textures(new_pixels::Matrix{vRGBf})
                # Get or create a texture of the right size.
                tex_size::v2i = vsize(new_pixels)
                tex = get(screen_textures, tex_size) do
                    return Bplus.GL.Texture(
                        Bplus.GL.SimpleFormat(
                            Bplus.GL.FormatTypes.normalized_uint,
                            Bplus.GL.SimpleFormatComponents.RGB,
                            Bplus.GL.SimpleFormatBitDepths.B8
                        ),
                        tex_size
                        ;
                        # Use Point filtering to make individual pixels more apparent
                        sampler = TexSampler{2}(
                            pixel_filter = PixelFilters.rough
                        )
                    )
                end
                newest_texture[] = tex

                # Upload the pixels to the GPU.
                set_tex_color(tex, new_pixels)
            end
            # When the window size changes, so does the render size, so clear the old textures.
            push!(LOOP.context.glfw_callbacks_window_resized, new_size::v2i -> begin
                for tex in values(screen_textures)
                    close(tex)
                end
                empty!(screen_textures)
            end)

            # Initialize debug logging.
            total_seconds::Float32 = 0
            LOG_ENABLED && change_log_destination(open("TickLog.txt", "w"))
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window) || get_button("quit")
                break # Cleanly ends the game loop
            end

            # Update timing data.
            total_seconds += LOOP.delta_seconds
            if (LOOP.frame_idx % 11) == 0
                @threaded_log "\t\t\t\t\tGame tick: " total_seconds
            end
            WORLD.current_frame = LOOP.frame_idx

            # Update the camera, but don't let the player screw up the camera
            #    if we're in the middle of a full-size render.
            if !@atomic renderer.doing_full_render
                update_camera(viewport, LOOP.delta_seconds)
            end

            # In a single-threaded Julia process, we'll need to give the rendering task some space.
            # 'yield()' gives other tasks a chance to interrupt this one.
            yield()
            update_renderer_game_task(update_textures, renderer)

            # Display the most recent output from the render Task.
            #TODO: Display it as a plane in world space so you can visualize the camera delta
            GL.set_viewport(Box(min=v2i(1, 1), size=get_window_size()))
            GL.clear_screen(vRGBAf(0, 0, 0, 0)) # Clear color
            GL.clear_screen(@f32(1)) # Clear depth
            # We can use the 'SimpleGraphics' service to draw the texture to the screen;
            #    no custom shader necessary.
            if isassigned(newest_texture) # Don't draw if we haven't even produced a frame yet
                simple_blit(newest_texture[])
            end

            # If the full render is happening, display a notification window.
            if @atomic renderer.doing_full_render
                gui_next_window_space(Box(
                    min = v2f(0.1, 0.02),
                    max = v2f(0.9, 0.1)
                ))
                gui_window("Message Window", C_NULL, CImGui.LibCImGui.ImGuiWindowFlags_NoDecoration) do
                    CImGui.Text("Rendering high-quality view...")
                end
            end
        end

        TEARDOWN = begin
            # Kill the rendering thread.
            close(renderer)

            # Clean up the log file.
            if LOG_ENABLED
                log_file = LOGGER[]
                change_log_destination(stdout)
                close(log_file)
            end
        end
    end
end

end # module