##  Interface  ##

"
Gets ready to compute a bunch of ray intersections.
The output of this function is passed into `get_first_hit()`.
By default, outputs `nothing`.
"
precompute(h::AbstractHitable, world::World)::Any = nothing

"
Finds the first intersection of the ray with this hitable.
Returns `nothing` if there's no intersection,
    or else a tuple of the `t` value along the ray and the surface normal at the point of contact.
"
function get_first_hit(h::AbstractHitable, ray::RT_Ray,
                       precomputation::Any,
                       ray_params::RayParams,
                      )::Optional{Tuple{Float32, v3f}}
    error("Unimplemented: ", typeof(h))
end


##  Bulk operations  ##

# The cost of dynamic dispatch (i.e. checking the specific type of Hitabale
#    and JIT-compiling the corresponding implementation of 'get_first_hit()')
#    would be huge if we had to do it for each call to 'get_first_hit()'.
# So here, we define a bulk operation which only needs to pay the dynamic dispatch cost once
#    for a huge list of rays.

function get_first_hit(h::AbstractHitable,
                       my_material::AbstractMaterial,
                       precomputation::Any,
                       buffer::RayBuffer,
                       params::RayParams)
    # Don't recompile for each material; it gets boxed inside RayHit anyway
    @nospecialize my_material

    Threads.@threads for i::Int in 1:buffer.count
        if exists(buffer.rays[i])
            hit_data::Optional = get_first_hit(h, buffer.rays[i], precomputation, params)
            if exists(hit_data)
                (hit_t::Float32, hit_normal::v3f) = hit_data
                # Only acknowledge it if it's closer than the existing hit.
                if isnothing(buffer.hits[i]) || (buffer.hits[i].ray_t > hit_t)
                    buffer.hits[i] = RayHit(hit_t, ray_at(buffer.rays[i], hit_t),
                                            hit_normal, my_material)
                end
            end
        end
    end

    return nothing # Prevent the last expression from leaking as a return value.
end


##  Implementations  ##

struct H_Box <: AbstractHitable
    center::v3f
    local_size::v3f
    rotation::fquat
end
function precompute(b::H_Box, world::World)
    # Calculate the inverse rotation, which we will use 
    return -b.rotation
end
function get_first_hit(b::H_Box, r::RT_Ray, inv_rotation::fquat, params::RayParams)::Optional{Tuple{Float32, v3f}}
    r = RT_Ray(q_apply(inv_rotation, r.start),
               q_apply(inv_rotation, r.dir))
    (hits, normal) = intersections(
        Box((center=b.center, size=b.local_size)),
        r,
        Val(true)
        ; unpack(params)...
    )
    return isempty(hits) ? nothing : (hits[1], q_apply(b.rotation, normal))
end

struct H_Sphere <: AbstractHitable
    center::v3f
    radius::Float32
end
function get_first_hit(s::H_Sphere, r::RT_Ray, ::Nothing, params::RayParams)::Optional{Tuple{Float32, v3f}}
    (hits, normal) = intersections(
        Sphere(s.center, s.radius),
        r,
        Val(true)
        ; unpack(params)...
    )
    return isempty(hits) ? nothing : (hits[1], normal)
end

struct H_Plane <: AbstractHitable
    origin::v3f
    normal::v3f
end
function get_first_hit(p::H_Plane, r::RT_Ray, ::Nothing, params::RayParams)::Optional{Tuple{Float32, v3f}}
    (hits, normal) = intersections(
        Plane(p.origin, p.normal),
        r,
        Val(true)
        ; unpack(params)...
    )
    return isempty(hits) ? nothing : (hits[1], normal)
end