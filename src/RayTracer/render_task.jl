# Rendering is done on its own task (i.e. a different thread),
#    to prevent the UI from being slow due to a high-quality render.

struct RenderSettings
    resolution::v2u
    n_bounces::Int
    n_samples_per_pixel::Int
end

"
Manages the ray-tracing computations in a separate task.
Takes 'mini' renders until the world stands still for a while, then kicks off a high-quality render.
"
mutable struct RenderTask
    mini_render_settings::RenderSettings
    full_render_settings::RenderSettings

    image_submitter::Channel # Game thread takes images from here
    image_acknowledger::Condition # Game thread acknowledges each image it consumes

    mini_render_output::Matrix{vRGBf}
    full_render_output::Matrix{vRGBf}

    mini_render_rays::RayBuffer
    full_render_rays::RayBuffer

    world::World
    viewport::Viewport
    @atomic kill_task::Bool # Don't set this directly; call 'close()' instead.
    @atomic doing_full_render::Bool # Render task sets this when starting the big render

    # This forces the end-of-frame logic to always happen at once, with no interruption from other tasks:
    #    kill_task, image_submitter, and image_acknowledger.
    # Both sides will utilize this lock when dealing with the end of a render frame.
    frame_complete_locker::ReentrantLock

    full_render_delay_seconds::Float32 # Full-size render won't start until the camera is unmoving for this much time.
end

"Kicks off a new render thread"
function RenderTask(mini_render_settings::RenderSettings, full_render_settings::RenderSettings,
                    world::World, viewport::Viewport,
                    full_render_delay_seconds = 2.0)
    # Warn the user if they gave bad settings.
    mini_complexity = prod(mini_render_settings.resolution) *
                          mini_render_settings.n_bounces *
                          mini_render_settings.n_samples_per_pixel
    full_complexity = prod(full_render_settings.resolution) *
                          full_render_settings.n_bounces *
                          full_render_settings.n_samples_per_pixel
    if mini_complexity > full_complexity
        @warn "Mini render size does more work than full size: $mini_complexity max rays vs $full_complexity. Are you sure about that?"
    end

    # There shouldn't be much more than a single full-size image in the channel at once.
    # To be safe, make the channel big enough for two full-size images.
    image_submitter = Channel(sizeof(vRGBf) * 2 * prod(full_render_settings.resolution))
    image_acknowledger = Condition()

    instance = RenderTask(mini_render_settings, full_render_settings,
                          image_submitter, image_acknowledger,
                          fill(zero(vRGBf), mini_render_settings.resolution.data),
                          fill(zero(vRGBf), full_render_settings.resolution.data),
                          RayBuffer(convert(v2i, mini_render_settings.resolution)),
                          RayBuffer(convert(v2i, full_render_settings.resolution)),
                          world, viewport,
                          false, false, ReentrantLock(),
                          full_render_delay_seconds)

    # Start running the render task, then return the data.
    @async begin
        try
            run_render_task(instance)
        catch e
            @error "Render task failed!" ex=(e, catch_backtrace())
        end
    end
    return instance
end

function Base.close(controller::RenderTask)
    lock(controller.frame_complete_locker) do
        @atomic controller.kill_task = true
        # The render thread might be waiting for us to acknowledge a new image.
        if isready(controller.image_submitter)
            take!(controller.image_submitter)
            notify(controller.image_acknowledger)
        end
    end
end

"The core loop of the render thread"
function run_render_task(controller::RenderTask)
    # Helper function that finishes a rendered frame by sending it to the game thread.
    # Returns 'false' if the task should end itself.
    function submit_rendered_frame(image::Matrix{vRGBf})::Bool
        # Submit the image and wait for acknowledgement.
        should_end::Bool = false
        lock(controller.frame_complete_locker) do 
            if @atomic controller.kill_task
                should_end = true
                return nothing
            end
            put!(controller.image_submitter, image)
            wait(controller.image_acknowledger)
            return nothing
        end
        return !should_end
    end

    # Each time the world changes, recompute collision data.
    local collision_precomputation::Vector{Any}
    function prepare_for_raytracing()
        collision_precomputation = [precompute(h, controller.world) for (h, _) in controller.world.objects]
    end

    # Helper function that renders a frame into the given pixel array.
    function calculate_rendered_frame(settings::RenderSettings, buffers::RayBuffer, output::Matrix{vRGBf})
        # If Julia is running single-threaded, we need to give it periodic chances
        #    to switch between this render task and the game task.
        # That's what the 'yield()' statements are for.
        # Dynamic dispatch is another way that Julia can interrupt tasks,
        #    but this code is specifically optimized to reduce those.

        fill!(output, zero(vRGBf))

        # Take multiple jittered samples to get Anti-Aliasing.
        # At the end, average the samples together.
        aa_rng = PRNG(controller.world.current_frame, controller.world.rng_seed)
        for aa_idx::Int in 1:settings.n_samples_per_pixel
            aa_jitter = rand(aa_rng, v2f)
            render_pass(controller.world, controller.viewport,
                        buffers, collision_precomputation,
                        RayParams(atol=0.001),
                        settings.n_bounces,
                        aa_jitter)
            output .+= buffers.color_left
        end
        output ./= settings.n_samples_per_pixel

        # Apply gamma-correction. In the future, maybe we can add other tonemapping.
        tonemap(c) = clamp(c ^ @f32(1 / 2.0), 0, 1)
        output .= tonemap.(output)
    end

    # Helper function that hashes together any data which should trigger a fresh render upon changing.
    function hash_scene_state()::UInt
        return hash((
            controller.world.objects,
            controller.world.sky,
            controller.viewport.cam
        ))
    end

    start_time_ns = time_ns()
    current_elapsed_seconds() = (time_ns() - start_time_ns) / 1e9

    while true
        current_scene_hash = hash_scene_state()
        prepare_for_raytracing()

        # Render a mini-frame.
        calculate_rendered_frame(controller.mini_render_settings,
                                 controller.mini_render_rays,
                                 controller.mini_render_output)
        if !submit_rendered_frame(controller.mini_render_output)
            break
        end
        @threaded_log "RENDER: tick mini: " current_elapsed_seconds()

        # Wait for a bit and if the scene hasn't changed at all, queue up a full render.
        do_full_render::Bool = (current_scene_hash == hash_scene_state())
        start_time = time_ns()
        while do_full_render
            # If time is up, do the full render!
            total_wait_seconds = ((time_ns() - start_time) / 1e9)
            if total_wait_seconds >= controller.full_render_delay_seconds
                @threaded_log "RENDER: Time's up, do the full render!"
                break
            end
            sleep(0.1)
            @threaded_log "RENDER: Still waiting; " total_wait_seconds " seconds so far"

            # If the scene changes, start a fresh mini-render.
            if current_scene_hash != hash_scene_state()
                @threaded_log "RENDER: The scene changed! Restarting a mini-render..."
                do_full_render = false
                break
            end
        end

        # Finally do the full render.
        if do_full_render
            @atomic controller.doing_full_render = true
            #TODO: Perform successive AA passes rather than one big one
            calculate_rendered_frame(controller.full_render_settings,
                                     controller.full_render_rays,
                                     controller.full_render_output)
            @atomic controller.doing_full_render = false
            if !submit_rendered_frame(controller.full_render_output)
                break
            end
        end

        # Wait for the world to change again.
        while current_scene_hash == hash_scene_state()
            sleep(0.1)
        end
    end
end

"
Runs the game thread's logic:

If the render thread has produced something, executes the given lambda with the image data passed in.
You should consider the image data temporary; do not hold onto it.
"
function update_renderer_game_task(to_do, controller::RenderTask)
    if isready(controller.image_submitter)
        to_do(take!(controller.image_submitter))
        notify(controller.image_acknowledger)
    end
end