# Note that file data loaded into 'const' globals will become part of the compiled package.
# This means that, if fyou were to package this code into an executable,
#    the files would become part of the executable!

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
        |(
            Assimp.aiProcess_FixInfacingNormals
        ),
        "obj"
    )
    #TODO: Make a Bplus.GL.Mesh
    Assimp.aiReleaseImport(scene)
end

#TODO :Test with it: using BpExamples, BpExamples.LSystem; using Assimp, Assimp.LibAssimp; scene = Assimp.aiImportFile(BpExamples.LSystem._ASSET_PATH_MESH_BRANCH, |(aiProcess_FixInfacingNormals, 0x0)); aiReleaseImport(scene)