##  Interface  ##

# Materials should be hashable/equatable, so we can batch duplicate materials together.
# By default, they're hashed and compared based on their type and fields.
# Julia's @generated macro allows us to procedurally generate hashing and equality code
#    for each particular type of material.
@generated function Base.hash(m::T, u::UInt) where {T<:AbstractMaterial}
    # Initialize the hash (and hash the material type).
    code::Expr = quote
        u ⊻= 0xabababababababab
        u = hash(T, u)
    end

    # Hash each field in this type of material.
    for f in fieldnames(T)
        f = QuoteNode(f) # Makes it a Symbol rather than a token, in generated code
        push!(code.args, :( # Add another code statement to the 'quote' block
            u = hash(getfield(m, $f), u)
        ))
    end

    # Add a return statement to the end of the 'quote' block.
    push!(code.args, :( return u ))

    return code
end
function Base.:(==)(a::AbstractMaterial, b::AbstractMaterial)
    @bp_check(typeof(a) != typeof(b), "Got the wrong overload")
    return false
end
@generated function Base.:(==)(a::T, b::T) where {T<:AbstractMaterial}
    expr = true
    for f in fieldnames(T)
        f = QuoteNode(f) # Makes it a Symbol rather than a token, in generated code
        expr = :( $expr && (getfield(a, $f) == getfield(b, $f)) )
    end
    return :( return $expr )
end


"
Responds to the given ray hitting this material's surface.
Outputs the surface color, plus an optional secondary ray.
"
function apply_material(m::AbstractMaterial,
                        r::RT_Ray, hit::RayHit,
                        world::World,
                        rng::ConstPRNG
                       )::Tuple{v3f, Optional{RT_Ray}}
    error("Unimplemented: ", typeof(m))
end


##  Bulk operations  ##

# Optimized with similar logic to 'get_first_hit()'.
# See the comment for that function.

function apply_material(m::AbstractMaterial, world::World,
                        buffer::RayBuffer, indices::Vector{UInt32})
    Threads.@threads for i in indices
        rng = ConstPRNG(world.rng_seed,
                        world.current_frame,
                        buffer.hits[i].pos...)
        (color, next_ray) = apply_material(m, buffer.rays[i], buffer.hits[i], world, rng)
        buffer.color_left[i] *= color
        buffer.rays[i] = next_ray
    end

    return nothing # Prevent the last expression from leaking as a return value.
end


##  Helper Functions  ##

"Prevents a ray from intersecting with the surface it just came from"
sanitize_ray(r::RT_Ray) = RT_Ray(r.start + (r.dir * 0.001), r.dir)

"Schlick's Fresnel approximation"
function schlick_fresnel(cosine::Float32, ior::Float32)
    ONE = Float32(1)
    FIVE = Float32(5)
    r0 = square((ONE - ior) / (ONE + ior))
    return r0 + ((ONE - r0) * ((ONE - cosine) ^ FIVE))
end


##  Implementations  ##

"A perfect diffuse surface (no reflection or refraction)"
struct M_Lambertian <: AbstractMaterial
    color::vRGBf
end
function apply_material(m::M_Lambertian,
                        r::RT_Ray, hit::RayHit,
                        world::World,
                        rng::ConstPRNG
                       )::Tuple{v3f, Optional{RT_Ray}}
    # Imagine a sphere tangent to the surface,
    #    and on the same side of the surface as the ray origin.
    # Cast a bounce ray in a uniform-random direction within this sphere.
    signed_normal = if vdot(r.start - hit.pos, hit.normal) < 0
                        -hit.normal
                    else
                        hit.normal
                    end
    (random_dir, rng) = rand_in_sphere(rng, Float32)
    lambertian_target = hit.pos + signed_normal +
                        (isapprox(random_dir, zero(v3f); atol=0.0001) ?
                            signed_normal :
                            vnorm(random_dir))
    ray_dir = vnorm(lambertian_target - hit.pos)
    bounce_ray = RT_Ray(hit.pos, ray_dir)

    return (m.color, sanitize_ray(bounce_ray))
end

"A conducting, reflective surface"
struct M_Metal <: AbstractMaterial
    albedo::vRGBf
    roughness::Float32 # From 0 to 1
end
function apply_material(m::M_Metal,
                        r::RT_Ray, hit::RayHit,
                        world::World,
                        rng::ConstPRNG
                       )::Tuple{v3f, Optional{RT_Ray}}
    reflected_ray = RT_Ray(hit.pos, vreflect(r.dir, hit.normal))
    # Apply roughness:
    (fuzz, rng) = rand_in_sphere(rng, Float32)
    @set! reflected_ray.dir = vnorm(reflected_ray.dir + (m.roughness * fuzz))

    return (m.albedo, sanitize_ray(reflected_ray))
end

"A material that refracts some rays and reflects others"
struct M_Dielectric <: AbstractMaterial
    albedo::vRGBf
    index_of_refraction::Float32
end
function apply_material(m::M_Dielectric,
                        r::RT_Ray, hit::RayHit,
                        world::World,
                        rng::ConstPRNG
                       )::Tuple{v3f, Optional{RT_Ray}}
    cos_theta::Float32 = min(@f32(1), vdot(-r.dir, hit.normal)) # Explicitly capped at 1 because
                                                                #   float error putting it above 1 would screw up math below
                                                                
    # If we're inside the surface peeking out, flip the IoR.
    ior::Float32 = (cos_theta < 0) ?
                       (@f32(1) / m.index_of_refraction) :
                       m.index_of_refraction

    # In certain cases refraction is impossible.
    # Otherwise, refraction chance is based on incident angle
    sin_theta::Float32 = sqrt(@f32(1) - (cos_theta * cos_theta))
    can_refract::Bool = (ior * sin_theta) <= @f32(1)
    (reflect_chance::Float32, rng) = rand(rng, Float32)
    should_refract::Bool = can_refract &&
                           (schlick_fresnel(cos_theta, ior) <= reflect_chance)

    # Generate the reflected or refracted ray.
    new_ray = RT_Ray(hit.pos,
                     if should_refract
                        vrefract(r.dir, hit.normal, ior)
                     else
                        vreflect(r.dir, hit.normal)
                     end)

    return (m.albedo, sanitize_ray(new_ray))
end