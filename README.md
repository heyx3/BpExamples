# BpExamples

Illustrative examples of interactive apps [made with B+](https://github.com/heyx3/B-plus/). Run by executing `julia path/to/BpExamples/run.jl`.

To be as clear as possible about where functions and types come from, this code endeavors to name all B+ stuff explicitly. For example, `Texture` is written as `BplusApp.GL.Texture`. You don't have to do this in your own code!

## Pong

The simplest example, showing a plain game loop, rendering quads with the `SimpleGraphics` service, and doing basic collision detection

## RayTracer

Runs a CPU ray-tracer in one thread, and interfaces with it from a "game" thread with live camera controls.
Showcases the use of various collision shapes, and techniques to use Julia for high-performance graphics.
Also shows how to do multithreading in Julia.

## TextureGen

Allows you to generate textures using the Fields module, which provides a mini-language for procedural fields.

Also shows how to use the GUI module to make Dear ImGUI interfaces.

## L-System

Uses an L-system to generate a hierarchical tree-like structure.
Showcases basic loading of assets from files, some interesting GUI stuff, and (WIP) how to make/use cubemaps.

The L-system calculations use Julia's array-processing features to greatly simplify syntax while maximizing performance.

# TODO: Project that simulates genetic algorithm on a system dropping pheromones, picking up resources, and avoiding hazards