"Based on the amazing Github repo: [https://github.com/mxgmn/MarkovJunior](mxgmn/MarkovJunior)"
module MarkovJunior

using Random

using Bplus; @using_bplus


Bplus.@make_toggleable_asserts markovjunior_

include("cells.jl")
include("logic.jl")
include("sequences.jl")
include("renderer.jl")


function main()::Int
    return 0
end

end