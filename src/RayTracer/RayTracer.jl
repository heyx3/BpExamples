"Loosely based on *Ray-Tracing in a Weekend*"
module RayTracer

# External dependencies:
using GLFW, # The underlying window/input library used by B+
      Setfield # Helper macros ('@set!') to "modify" immutable data by copying it

# B+:
@using_bplus


include("utils.jl")
include("types.jl")

include("hitables.jl")
include("skies.jl")
include("materials.jl")

include("logic.jl")

"
The resolution of the renderer is kept roughly around here,
but increased along one axis to correct for aspect ratio.

Usually kept much smaller than the window size, because ray-tracing is slow.
"
const SOFT_MAX_RESOLUTION = 200

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
                ),
                Matrix{vRGBf}(undef, get_window_size(LOOP.context.window)...)
            )

            configure_world_inputs()
            rt_buffers = RayBuffer(v2i(SOFT_MAX_RESOLUTION, SOFT_MAX_RESOLUTION))
            # When the window size changes, update the world data accordingly.
            push!(LOOP.context.glfw_callbacks_window_resized, new_size::v2i -> begin
                @set! viewport.cam.aspect_width_over_height = Float32(new_size.x / new_size.y)

                # The RT render size will max out at a certain value,
                #    give or take aspect ratio.
                rt_size = min(new_size, v2i(SOFT_MAX_RESOLUTION, SOFT_MAX_RESOLUTION))
                if new_size.x > new_size.y
                    @set! rt_size.x = Int(round(rt_size.x * viewport.cam.aspect_width_over_height))
                else
                    @set! rt_size.y = Int(round(rt_size.y / viewport.cam.aspect_width_over_height))
                end

                rt_buffers = RayBuffer(rt_size)
            end)

            # To draw to the screen, we'll need to dump the ray-tracer results into a GL texture
            #    and render that texture.
            final_pixels = Matrix{vRGBf}(undef, rt_buffers.size...)
            screen_tex = Bplus.GL.Texture(
                Bplus.GL.SimpleFormat(
                    Bplus.GL.FormatTypes.normalized_uint,
                    Bplus.GL.SimpleFormatComponents.RGB,
                    Bplus.GL.SimpleFormatBitDepths.B8
                ),
                rt_buffers.size
                ;
                # Use Point filtering to make individual pixels more apparent
                sampler = TexSampler{2}(
                    pixel_filter = PixelFilters.rough
                )
            )
            # When the window size changes, reallocate the output texture.
            push!(LOOP.context.glfw_callbacks_window_resized, new_size::v2i -> begin
                # Use the downscaled size that was calculated in the above callback.
                rt_size = rt_buffers.size
                if screen_tex.size.xy != rt_size
                    tex_format = screen_tex.format
                    close(screen_tex)
                    screen_tex = Bplus.GL.Texture(tex_format, rt_size)
                end
            end)

            Bplus.Input.create_button("quit", ButtonInput(GLFW.KEY_ESCAPE))
            GLFW.SetInputMode(LOOP.context.window, GLFW.CURSOR, GLFW.CURSOR_DISABLED)
        end

        LOOP = begin
            if get_button("quit")
                break
            end

            # Update.
            update_camera(viewport, LOOP.delta_seconds)
            WORLD.current_frame = LOOP.frame_idx

            # Render with ray-tracing.
            fill!(final_pixels, zero(vRGBf))
            collision_precomputation = [precompute(h, WORLD) for (h, _) in WORLD.objects]
            N_BOUNCES = 5
            N_AA_SAMPLES = 5
            for aa_idx::Int in 1:N_AA_SAMPLES
                pass_prng = ConstPRNG(aa_idx, WORLD.current_frame, WORLD.rng_seed)

                # Do AA by randomly shifting each ray by fractions of a pixel.
                (jitter_x, pass_prng) = rand(pass_prng, Float32)
                (jitter_y, pass_prng) = rand(pass_prng, Float32)
                aa_jitter = v2f(jitter_x, jitter_y)
    
                render_pass(WORLD, viewport,
                            rt_buffers, collision_precomputation,
                            RayParams(atol=0.001),
                            N_BOUNCES,
                            aa_jitter)
                final_pixels .+= rt_buffers.color_left
            end
            final_pixels ./= N_AA_SAMPLES

            # Apply gamma-correction and other tonemapping.
            # Obviously this could be sped up in a shader, but it's a good example
            #    of how to write high-performance Julia code.
            tonemap(c) = clamp(c ^ @f32(1 / 2.0), 0, 1)
            final_pixels .= tonemap.(final_pixels)

            # Render the ray-traced scene to the screen.
            GL.set_viewport(Box(min=v2i(1, 1), size=get_window_size(LOOP.context)))
            GL.render_clear(LOOP.context, GL.Ptr_Target(), vRGBAf(0, 0, 0, 0))
            GL.render_clear(LOOP.context, GL.Ptr_Target(), @f32(1)) # Clears the depth buffer
            # We can use the 'SimpleGraphics' service to draw the texture to the screen;
            #    no custom shader necessary.
            set_tex_color(screen_tex, final_pixels)
            simple_blit(screen_tex)
        end
    end
end

end # module