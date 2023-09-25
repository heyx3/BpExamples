"The type of ray used for our ray-tracer (3D, 32-bit float)"
const RT_Ray = Bplus.Math.Ray{3, Float32}

"Something that a ray can hit"
abstract type AbstractHitable end


"A surface's response to a ray hitting it"
abstract type AbstractMaterial end

"The backdrop to a ray-traced scene"
abstract type AbstractSky end


"Parameters for a ray-tracing pass"
Base.@kwdef struct RayParams
    min_t::Float32 = 0
    max_t::Float32 = +Inf
    atol::Float32 = 0 # Julia's abbreviation for "Absolute Tolerance",
                      #   a.k.a. a constant epsilon value
end
"Formats the parameters for passing as named arguments into `Bplus.Math.intersections()`"
unpack(p::RayParams) = (min_t=p.min_t, max_t=p.max_t, atol=p.atol)

"All information about a ray hit"
struct RayHit
    ray_t::Float32
    pos::v3f # Computable from the ray, but useful to cache
    normal::v3f
    material::AbstractMaterial
end

"A buffer used for ray-tracing passes"
struct RayBuffer
    size::v2i
    count::Int

    rays::Matrix{Optional{RT_Ray}}
    hits::Matrix{Optional{RayHit}}
    color_left::Matrix{vRGBf}

    material_buckets::Dict{AbstractMaterial, Vector{UInt32}}
    material_bucket_pool::Vector{Vector{UInt32}}

    RayBuffer(size::v2i) = new(size, prod(size),
                               Matrix{Optional{RT_Ray}}(undef, size...),
                               Matrix{Optional{RayHit}}(undef, size...),
                               Matrix{vRGBf}(undef, size...),
                               Dict{AbstractMaterial, Vector{UInt32}}(),
                               Vector{Vector{UInt32}}())
end


"A ray-traceable scene"
mutable struct World
    objects::Vector{Pair{AbstractHitable, AbstractMaterial}}
    sky::AbstractSky

    rng_seed::Int
    current_frame::Int
end

"A view into a `World`"
mutable struct Viewport
    cam::Cam3D{Float32}
    cam_settings::Cam3D_Settings{Float32}
end