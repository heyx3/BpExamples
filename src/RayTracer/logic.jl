#TODO: Try to rewrite the batched functions using broadcasting rather than manual for-loops. Can it still be threaded?


function configure_world_inputs()
    create_axis("cam forward", AxisInput([
        ButtonAsAxis(GLFW.KEY_W),
        ButtonAsAxis_Negative(GLFW.KEY_S)
    ]))
    create_axis("cam rightward", AxisInput([
        ButtonAsAxis(GLFW.KEY_D),
        ButtonAsAxis_Negative(GLFW.KEY_A)
    ]))
    create_axis("cam upward", AxisInput([
        ButtonAsAxis(GLFW.KEY_E),
        ButtonAsAxis_Negative(GLFW.KEY_Q)
    ]))

    create_axis("cam yaw", AxisInput(MouseAxes.x, AxisModes.delta))
    create_axis("cam pitch", AxisInput(MouseAxes.y, AxisModes.delta, value_scale=-1))
end

function update_camera(viewport::Viewport, delta_seconds::Float32)
    input = Cam3D_Input{Float32}(
        true,
        get_axis("cam yaw"),
        get_axis("cam pitch"),
        false,
        get_axis("cam forward"),
        get_axis("cam rightward"),
        get_axis("cam upward"),
        0
    )
    (viewport.cam, viewport.cam_settings) = cam_update(
        viewport.cam,
        viewport.cam_settings,
        input,
        delta_seconds
    )
    return nothing # prevents the last expression from leaking out as a return value
end


"Generates the first group of rays coming from the camera"
function generate_main_rays(viewport::Viewport, buffer::RayBuffer, pixel_jitter::v2f)
    # The output image is a window into the scene,
    #    and the camera sits behind that window casting one ray through each pixel.
    # The distance between the camera and window is what controls the FOV.
    pixel_basis = cam_basis(viewport.cam)
    pixel_rightward::v3f = pixel_basis.right * viewport.cam.projection.aspect_width_over_height
    pixel_upward::v3f = pixel_basis.up
    pixel_forward::v3f = pixel_basis.forward * deg2rad(viewport.cam.projection.vertical_fov_degrees) # Not mathematically precise, but works fine

    for pixel::v2i in 1:buffer.size
        uv::v2f = (pixel + pixel_jitter) / convert(v2f, buffer.size)
        signed_uv::v2f = lerp(-1, 1, uv)
        pixel_world_pos::v3f = viewport.cam.pos + pixel_forward +
                                   (pixel_rightward * signed_uv.x) +
                                   (pixel_upward * signed_uv.y)

        pixel_world_dir::v3f = vnorm(pixel_world_pos - viewport.cam.pos)

        buffer.rays[pixel] = RT_Ray(pixel_world_pos, pixel_world_dir)
        buffer.color_left[pixel] = vRGBf(1, 1, 1)
        buffer.hits[pixel] = nothing
    end

    return nothing # prevents the last expression from leaking out as a return value
end

"Gets or creates a bucket for storing pixels that need to be rendered by the given material"
function get_material_bucket(buffer::RayBuffer, m::AbstractMaterial)::Vector{UInt32}
    @nospecialize m # Boxing 'm' is better than dynamically recompiling for each possible type.

    if haskey(buffer.material_buckets, m)
        return buffer.material_buckets[m]
    elseif !isempty(buffer.material_bucket_pool)
        bucket = pop!(buffer.material_bucket_pool)
        buffer.material_buckets[m] = bucket
        return bucket
    else
        bucket = Vector{UInt32}(undef, buffer.count)
        empty!(bucket)
        buffer.material_buckets[m] = bucket
        return bucket
    end
end
function gather_material_buckets(buffer::RayBuffer, materials_type_stable::Tuple{Vararg{AbstractMaterial}})
    function process_material(material)
        bucket = get_material_bucket(buffer, material)
        for i in UInt32(1) : UInt32(buffer.count)
            if exists(buffer.hits[i]) && (buffer.hits[i].material == material)
                push!(bucket, i)
            end
        end
    end
    process_material.(materials_type_stable)
    return nothing
end
"Releases all buckets back into the memory pool"
function release_material_buckets(buffer::RayBuffer)
    for bucket in values(buffer.material_buckets)
        empty!(bucket)
        push!(buffer.material_bucket_pool, bucket)
    end
    empty!(buffer.material_buckets)
    return nothing
end

"Handles any rays which will not be processed due to hitting the limit on bounces"
function kill_rays(buffer::RayBuffer)
    for i::Int in 1:buffer.count
        escaped_to_sky::Bool = isnothing(buffer.hits[i])
        fully_absorbed::Bool = isnothing(buffer.rays[i])
        if !fully_absorbed && !escaped_to_sky
            buffer.color_left[i] = zero(vRGBf)
        end
    end
end

"Processes one ray-tracing pass, applying the calculated color of each ray"
function render_pass(world::World, viewport::Viewport,
                     buffer::RayBuffer,
                     hitables_precomputed::Vector,
                     params::RayParams, n_bounces::Int, pixel_jitter::v2f,
                     acknowledge_progress_t::Base.Callable = (f::Float32 -> nothing))
    all_materials::Vector{AbstractMaterial} = unique(kvp[2] for kvp in world.objects)
    # For type-stability, gather the unique material list into a tuple.
    # Then we have to enter a lambda which Julia can compile for our specific set of materials.
    # To reduce the number of compiled variants, sort the materials first.
    sort!(all_materials, by=hash)
    _materials_type_stable = Tuple(all_materials)
    return ((materials_type_stable) -> begin # Everything below has type-stable materials now!

    # Compute progress rates.
    prog_main_rays_generate = @f32(0.05)
    prog_single_bounce = (@f32(1) - prog_main_rays_generate) / n_bounces
    prog_bounce_hits = prog_single_bounce * @f32(0.7)
    prog_bounce_batched = prog_single_bounce * @f32(0.1)
    prog_bounce_rendered = prog_single_bounce * @f32(0.2)
    prog_bounce_rendered_single_mat = prog_bounce_rendered / @f32(length(materials_type_stable))

    prog_current = @f32(0.0)
    acknowledge_progress_t(prog_current)
    function advance_progress(by::Float32)
        prog_current += by
        acknowledge_progress_t(clamp(prog_current, zero(Float32), one(Float32)))
    end

    fill!(buffer.color_left, one(vRGBf)) # Initially un-tinted; all light can be received.
                                         # As the rays bounce off surfaces, they get tinted.
    generate_main_rays(viewport, buffer, pixel_jitter)
    advance_progress(prog_main_rays_generate)

    for bounce_i::Int in 1:n_bounces
        # Find the first object hit for each ray/pixel.
        fill!(buffer.hits, nothing)
        for ((hitable, material), precomputation) in zip(world.objects, hitables_precomputed)
            get_first_hit(hitable, material, precomputation, buffer, params)
        end
        advance_progress(prog_bounce_hits)

        # Collect pixels into buckets by their material.
        release_material_buckets(buffer)
        gather_material_buckets(buffer, materials_type_stable)
        advance_progress(prog_bounce_batched)

        # Render pixels that hit materials.
        for (material, bucket) in buffer.material_buckets
            apply_material(material, world, buffer, bucket)
            advance_progress(prog_bounce_rendered_single_mat)
        end

        # If there are no rays left to simulate, exit early.
        if count(exists, buffer.rays) < 1
            @info "All rays have been absorbed by bounce #$bounce_i"
            break
        end
    end
    # Rays that never got to bounce further should output color 0.
    #TODO: Report the percentage of rays left un-bounced, to get an idea of how many more bounces we could have tried.
    kill_rays(buffer)

    # Apply the sky color to pixels that escaped the scene.
    get_sky_color(world.sky, world, buffer)

    return nothing # prevents the last expression from leaking out as a return value

    end)(_materials_type_stable) # Close and invoke the lambda that introduces type-stability
end