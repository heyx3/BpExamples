# This is a top-level script that runs BpExamples, no matter where you call it from.
# You can pass command-line arguments to pick specific programs:
#   *  --rt for RayTracer
#   *  --po for Pong
#   *  --ts for ToySynth

# Activate this project.
using Pkg
Pkg.activate(@__DIR__)

# Compile and import this project.
using BpExamples

# Run this project.
if "--rt" in ARGS
    BpExamples.RayTracer.main()
elseif "--po" in ARGS
    BpExamples.Pong.main()
elseif "--ts" in ARGS
    BpExamples.ToySynth.main()
else
    BpExamples.main()
end