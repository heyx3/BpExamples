# BpExamples

Simple examples of games made with B+.

To be as clear as possible about where functions and types come from, this code endeavors to name all B+ stuff explicitly. For example, `Bplus.GL.Texture` instead of `Texture`. You don't need to be this verbose in your own code.

## Pong

Showcases a simple game-loop, rendering with `SimpleGraphicsService`, and basic collision detection

## RayTracer

Showcases the use of various collision shapes, and techniques to use Julia for high-performance graphics.

## TextureGen

Showcases the use of Fields and GUI (our Dear ImGUI service module).

## L-System

Uses an L-system to generate a hierarchical tree-like structure.
Showcases basic loading of assets from files, some interesting GUI stuff, and how to make/use cubemaps.

Also shows how to use Julia's array-processing features, originally intended for scientific computing,
    to hugely simplify syntax without sacrificing performance.
Here it's used to iterate L-systems, in a way that's both efficient and friendly to parallelization.

# TODO: Project that simulates genetic algorithm on a system dropping pheromones, picking up resources, and avoiding hazards