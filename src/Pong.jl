module Pong

# Built-in Julia dependencies:
using Random  # For RNG stuf

# External dependencies:
using GLFW, # The underlying window/input library used by B+
      Setfield # Helper macros ('@set!') to "modify" immutable data by copying it

# B+:
using Bplus
using Bplus.Utilities,
      Bplus.Math, Bplus.GL,
      Bplus.Input, Bplus.Helpers


# Set the size of the level and objects, in pixels.
#  'v2i' means 'vector of 2 ints'; short-hand for 'Bplus.Math.Vec{2, Int32}'.
const LEVEL_SIZE_PIXELS = v2i(1600, 900)
const BAT_SIZE = v2i(25, 200)
const BALL_RADIUS = Float32(22)

# Set gameplay constants:
const BAT_SPEED_PIXELS_PER_SECOND = 900
const BALL_INITIAL_SPEED_PIXELS_PER_SECOND = 500
const BALL_SPEEDUP_PER_HIT = Float32(1.2) # Can also write "1.2f0" for Float32
                                          # B+ offers another short-hand: "@f32(1.2)"

# Set render/window settings:
const FPS_CAP = 1/240 # A dumb but simple way to prevent the game from burning CPU cycles
const VSYNC = VsyncModes.adaptive # B+ will fall back to VsyncModes.on
                                  #    if the monitor doesn't have adaptive vsync


# Run the game logic using a standard B+ game loop.
# The game loop lives within an OpenGL/GLFW context and window.
function main()
    @game_loop begin
        # Context constructor parameters:
        INIT(
            LEVEL_SIZE_PIXELS, "Pong",
            vsync=VSYNC,
            glfw_hints=Dict(
                GLFW.DEPTH_BITS => GLFW.DONT_CARE,
                GLFW.STENCIL_BITS => GLFW.DONT_CARE,
                GLFW.RESIZABLE => false
            )
        )

        # Turn off Dear ImGUI, otherwise a little GUI window will appear over the screen.
        USE_GUI = false

        # Game logic:
        SETUP = begin
            # Define the ball and bat shaders.
            # Both are rendered with the standard quad from the "BasicGraphics" service.
            shader_bat::Bplus.GL.Program = bp_glsl"""
                #START_VERTEX
                //Vertex shader:
                uniform vec2 u_boundsMin, u_boundsMax;
                in vec2 vIn_pos;
                void main() {
                    vec2 uv = (vIn_pos * 0.5) + 0.5;
                    gl_Position = vec4(mix(u_boundsMin, u_boundsMax, uv),
                                    0.5, 1.0);
                }

                #START_FRAGMENT
                //Fragment shader:
                uniform vec4 u_color;
                out vec4 fOut_color;
                void main() {
                    fOut_color = u_color;
                }
            """
            shader_ball::Bplus.GL.Program = bp_glsl"""
                #START_VERTEX
                //Vertex shader:
                uniform vec2 u_boundsMin, u_boundsMax;
                in vec2 vIn_pos;
                out vec2 vOut_uv;
                void main() {
                    vOut_uv = (vIn_pos * 0.5) + 0.5;
                    gl_Position = vec4(mix(u_boundsMin, u_boundsMax, vOut_uv),
                                    0.5, 1.0);
                }

                #START_FRAGMENT
                //Fragment shader:
                in vec2 vOut_uv;
                uniform vec4 u_color;
                out vec4 fOut_color;
                void main() {
                    fOut_color = u_color;

                    //The ball is a circle, inscribing the quad mesh that renders it.
                    //Therefore its radius is 0.5 in UV space.
                    //Discard pixels outside this circle.
                    if (distance(vOut_uv, (0.5).xx) > 0.5)
                        discard;
                }
            """

            # Set up player 1's input using the input service.
            create_button("p1 up", ButtonInput(GLFW.KEY_W))
            create_button("p1 down", ButtonInput(GLFW.KEY_S))
            sample_p1_input()::Float32 = (get_button("p1 up") ? 1 : 0) +
                                            (get_button("p1 down") ? -1 : 0)

            # Set up player 2's input using the input service.
            # To illustrate more about the input system,
            #    it will be implemented as an axis instead of 2 separate buttons.
            # The axis will be +1 when pressing 'up', and -1 when pressing 'down'.
            create_axis("p2 vertical", AxisInput([ ButtonAsAxis(GLFW.KEY_UP),
                                                ButtonAsAxis_Negative(GLFW.KEY_DOWN) ]))
            sample_p2_input()::Float32 = get_axis("p2 vertical")

            # Set up other inputs.
            create_button("quit", ButtonInput(GLFW.KEY_ESCAPE))

            # Set up game state.
            BAT_BORDER::Float32 = 10
            p1_pos::v2f = v2f((BAT_SIZE.x / 2) + BAT_BORDER,
                            LEVEL_SIZE_PIXELS.y / 2)
            p2_pos::v2f = v2f(LEVEL_SIZE_PIXELS.x - p1_pos.x,
                            p1_pos.y)
            ball_pos::v2f = zero(v2f)
            ball_velocity::v2f = zero(v2f)
            winner_display::Float32 = 0 # Negative values mean p1 won; positive mean p2 won.
                                        # Controls visual effects, and animates towards 0.

            # Helper function for the loop.
            function respawn_ball()::Tuple{v2f, v2f}
                return (
                    LEVEL_SIZE_PIXELS / 2,
                    BALL_INITIAL_SPEED_PIXELS_PER_SECOND *
                    # Generate a direction vector from a random angle:
                    let angle = deg2rad(rand(0:359))
                        v2f(cos(angle), sin(angle))
                    end
                )
            end
        end

        LOOP = begin
            if GLFW.WindowShouldClose(LOOP.context.window) || get_button("quit")
                break # Cleanly ends the game loop.
            end

            # Continuously fade out the display for the last winner.
            winner_display = lerp(winner_display, 0, 0.1)

            # Process player inputs.
            p1_pos += BAT_SPEED_PIXELS_PER_SECOND * LOOP.delta_seconds *
                        v2f(0, sample_p1_input())
            p2_pos += BAT_SPEED_PIXELS_PER_SECOND * LOOP.delta_seconds *
                        v2f(0, sample_p2_input())

            # Stop the bats from leaving the level:
            HALF_BAT_HEIGHT = BAT_SIZE.y / @f32(2)
            @set! p1_pos.y = clamp(p1_pos.y, HALF_BAT_HEIGHT,
                                            LEVEL_SIZE_PIXELS.y - HALF_BAT_HEIGHT)
            @set! p2_pos.y = clamp(p2_pos.y, HALF_BAT_HEIGHT,
                                            LEVEL_SIZE_PIXELS.y - HALF_BAT_HEIGHT)

            # Process ball movement.
            # The Setfield package's '@set!' macro helps us make copies of immutable data.
            ball_pos += ball_velocity * LOOP.delta_seconds
            if ball_pos.x < BALL_RADIUS # Hit the left edge?
                winner_display = 1
                (ball_pos, ball_velocity) = respawn_ball()
            end
            if ball_pos.x > LEVEL_SIZE_PIXELS.x - BALL_RADIUS # Hit the right edge?
                winner_display = -1
                (ball_pos, ball_velocity) = respawn_ball()
            end
            if ball_pos.y < BALL_RADIUS # Hit the top edge?
                @set! ball_pos.y = BALL_RADIUS
                @set! ball_velocity.y = abs(ball_velocity.y)
            end
            if ball_pos.y > LEVEL_SIZE_PIXELS.y - BALL_RADIUS # Hit the bottom edge?
                @set! ball_pos.y = LEVEL_SIZE_PIXELS.y - BALL_RADIUS
                @set! ball_velocity.y = -abs(ball_velocity.y)
            end

            # Check for collisions between the ball and bats.
            p1_box = Box((center=p1_pos, size=BAT_SIZE))
            p2_box = Box((center=p2_pos, size=BAT_SIZE))
            ball_sphere = Sphere2D{Float32}(ball_pos, BALL_RADIUS)
            if collides(p1_box, ball_sphere)
                @set! ball_pos.x = max_inclusive(p1_box).x + (BALL_RADIUS / @f32(2))
                @set! ball_velocity.x = abs(ball_velocity.x)
                ball_velocity *= BALL_SPEEDUP_PER_HIT
            end
            if collides(p2_box, ball_sphere)
                @set! ball_pos.x = min_inclusive(p2_box).x - (BALL_RADIUS / @f32(2))
                @set! ball_velocity.x = -abs(ball_velocity.x)
                ball_velocity *= BALL_SPEEDUP_PER_HIT
            end

            # Render.
            GL.render_clear(LOOP.context, GL.Ptr_Target(), vRGBAf(0, 0, 0, 0))
            GL.render_clear(LOOP.context, GL.Ptr_Target(), @f32(1)) # Clears the depth buffer
            # There are three objects to draw: P1, P2, and the ball.
            render_tasks::Tuple = (
                # Each task is a tuple of (position, size, color, shader).
                (
                    p1_pos,
                    BAT_SIZE,
                    # Color is computed based on whether a player recently scored.
                    if winner_display < 0 # This player just scored
                        lerp(vRGBAf(1, 1, 1, 1), vRGBAf(0, 1, 0, 1),
                            clamp(-winner_display, 0, 1))
                    elseif winner_display > 0 # This player just got scored on
                        lerp(vRGBAf(1, 1, 1, 1), vRGBAf(1, 0, 0, 1),
                            clamp(winner_display, 0, 1))
                    else
                        vRGBAf(1, 1, 1, 1)
                    end,
                    shader_bat
                ),
                (
                    p2_pos,
                    BAT_SIZE,
                    # Color is computed based on whether a player recently scored.
                    if winner_display < 0 # This player just got scored on
                        lerp(vRGBAf(1, 1, 1, 1), vRGBAf(1, 0, 0, 1),
                            clamp(-winner_display, 0, 1))
                    elseif winner_display > 0 # This player just scored
                        lerp(vRGBAf(1, 1, 1, 1), vRGBAf(0, 1, 0, 1),
                            clamp(winner_display, 0, 1))
                    else
                        vRGBAf(1, 1, 1, 1)
                    end,
                    shader_bat
                ),
                (
                    ball_pos,
                    v2f(BALL_RADIUS, BALL_RADIUS),
                    vRGBAf(1, 1, 1, 1),
                    shader_ball
                )
            )
            for (pos, size, color, shader) in render_tasks
                min_pos::v2f = (pos - (size / 2))
                max_pos::v2f = (pos + (size / 2))
                # Convert positions from pixel space to NDC space (-1 to +1).
                min_pos_screen::v2f = lerp(-1, 1,
                                        inv_lerp(zero(v2f), convert(v2f, LEVEL_SIZE_PIXELS),
                                                    min_pos))
                max_pos_screen::v2f = lerp(-1, 1,
                                        inv_lerp(zero(v2f), convert(v2f, LEVEL_SIZE_PIXELS),
                                                    max_pos))
                # Configure and dispatch the shader.
                set_uniform(shader, "u_boundsMin", min_pos_screen)
                set_uniform(shader, "u_boundsMax", max_pos_screen)
                set_uniform(shader, "u_color", color)
                GL.render_mesh(LOOP.service_basic_graphics.quad, shader)
            end
        end

        TEARDOWN = begin
            # Cleanup code goes here.
            # No manual cleanup is needed for Pong;
            #    the two shaders will be destroyed when the Context is.
        end
    end
end

end # module