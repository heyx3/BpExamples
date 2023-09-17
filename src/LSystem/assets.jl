# File data is loaded into globals, making it part of the compiled package.

# This means that, if you were to package this code into an executable,
#    the files would become embedded in the executable.

# This also unfortunately means that the project gets recompiled
#    if you change one of these asset files.
# In a larger project, this could be avoided by putting the assets into a separate Julia project.

function read_whole_bytes(lsystem_relative_path::String)::Vector{UInt8}
    return read(joinpath(@__DIR__, lsystem_relative_path))
end
function read_whole_text(lsystem_relative_path::String)::String
    return read(joinpath(@__DIR__, lsystem_relative_path))
end

# Branch mesh
const _ASSET_PATH_MESH_BRANCH = joinpath(@__DIR__, "branch.obj")
const ASSET_BYTES_MESH_BRANCH = read_whole_bytes(_ASSET_PATH_MESH_BRANCH)
include_dependency(_ASSET_PATH_MESH_BRANCH)
function load_mesh_branch()::Tuple{Bplus.GL.Mesh, AbstractVector{Bplus.GL.Buffer}}
    scene = Assimp.aiImportFileFromMemory(
        ASSET_BYTES_MESH_BRANCH,
        length(ASSET_BYTES_MESH_BRANCH),
        |( # Combine the below flags together:
            Assimp.aiProcess_FixInfacingNormals,
            Assimp.aiProcess_Triangulate
        ),
        "obj"
    )
    mesh::Assimp.aiMesh = unsafe_load(unsafe_load(unsafe_load(scene).mMeshes))

    indices = preallocated_vector(UInt32, mesh.mNumFaces * 3)
    for face_idx in 1:mesh.mNumFaces
        face::Assimp.aiFace = unsafe_load(mesh.mFaces, face_idx)
        @bp_check(face.mNumIndices == 3,
                  "Un-triangulated face: #", face_idx, " has ",
                      face.mNumIndices, " indices instead of 3")
        push!(indices, unsafe_load(face.mIndices, 1))
        push!(indices, unsafe_load(face.mIndices, 2))
        push!(indices, unsafe_load(face.mIndices, 3))
    end

    positions = unsafe_wrap(Array, Ptr{v3f}(mesh.mVertices), mesh.mNumVertices)
    uvs = unsafe_wrap(Array, Ptr{v3f}(mesh.mTextureCoords[1]), mesh.mNumVertices)
    normals = unsafe_wrap(Array, Ptr{v3f}(mesh.mNormals), mesh.mNumVertices)

    gpu_indices = Buffer(false, indices)
    gpu_positions = Buffer(false, positions)
    gpu_uvs = Buffer(false, (v3 -> v3.xy).(uvs))
    gpu_normals = Buffer(false, normals)
    gpu_mesh = Mesh(
        PrimitiveTypes.triangle,
        [
            VertexDataSource(gpu_positions, sizeof(v3f)),
            VertexDataSource(gpu_uvs, sizeof(v2f)),
            VertexDataSource(gpu_normals, sizeof(v3f))
        ],
        [
            VertexAttribute(1, 0, VSInput(v3f)),
            VertexAttribute(2, 0, VSInput(v2f)),
            VertexAttribute(3, 0, VSInput(v3f))
        ],
        MeshIndexData(gpu_indices, UInt32)
    )

    Assimp.aiReleaseImport(scene)
    return (gpu_mesh, [ gpu_indices, gpu_positions, gpu_uvs, gpu_normals ])
end