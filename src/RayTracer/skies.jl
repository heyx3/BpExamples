##   Interface   ##

"Gets the color of the given sky in the given direction"
get_sky_color(s::AbstractSky, world::World, ray::RT_Ray)::vRGBf = error("Not implemented: ", typeof(s))


##  Bulk operations  ##

# Optimized in the same way as hitables. Refer to *hitables.jl* for more info.

function get_sky_color(s::AbstractSky, world::World, buffer::RayBuffer)
    Threads.@threads for i::Int in 1:buffer.count
        if isnothing(buffer.hits[i])
            buffer.color_left[i] *= get_sky_color(s, world, buffer.rays[i])
        end
    end
    return nothing # Prevent the last expression from leaking as a return value.
end


##  Implementations  ##

struct S_Plain <: AbstractSky
    horizon_color::vRGBf
    zenith_color::vRGBf
    horizon_dropoff::Float32
end
function get_sky_color(ps::S_Plain, world::World, ray::RT_Ray)::vRGBf
    zenith_strength = max(0, ray.dir.z)
    zenith_strength = zenith_strength ^ ps.horizon_dropoff
    return lerp(ps.horizon_color, ps.zenith_color, zenith_strength)
end

"Displays the coordinate system in the sky, to help with orientation"
struct S_Test <: AbstractSky end
function get_sky_color(ts::S_Test, world::World, ray::RT_Ray)::vRGBf
    return abs(ray.dir)
end

#TODO: Load a cubemap