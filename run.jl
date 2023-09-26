# This is a top-level script that runs BpExamples, no matter where you call it from.

# Activate this project.
using Pkg
Pkg.activate(@__DIR__)

# Compile and import this project.
using BpExamples

# Run this project.
BpExamples.main()