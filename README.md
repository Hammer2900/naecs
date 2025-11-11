# Not Another ECS (NAECS)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Nim Version](https://img.shields.io/badge/nim-2.0%2B-orange.svg)](https://nim-lang.org/)
[![Documentation](https://img.shields.io/badge/docs-gh--pages-blue)](https://hammer2900.github.io/naecs/)

**NAECS** (Not Another ECS) is yet another Entity Component System implementation in Nim. Yes, we know, there are many. But this one was built from the ground up for one purpose: to fuse the raw power of a modern **archetype architecture** with an API so clean you'll forget you're not just writing game logic.

## ✨ Core Architecture & Features

*   🚀 **True Archetype Performance:** At its core, NAECS is a high-performance, archetype-based ECS. Entities with the exact same set of components are grouped together in tightly packed, contiguous memory blocks. When a system runs, it doesn't scan all entities—it jumps directly to the specific memory chunks it needs, resulting in massive, cache-friendly speedups.

*   🧠 **Pragmatic Hybrid Tag Model:** This is where NAECS stands out. While components define an entity's archetype, **tags are stored directly on the entity**. This makes adding and removing tags an extremely fast, constant-time operation. It's the perfect solution for dynamic states like `IsSelected`, `IsOnFire`, or `IsStunned` without causing costly data shuffling between archetypes.

*   ✍️ **Elegant `system` Macro:** Say goodbye to boilerplate. The `system` macro lets you define systems declaratively. Just specify the components you need, and NAECS generates the highly optimized query and component access code for you.

*   🗑️ **GC-Free Critical Path:** The library uses manual memory management for all component and entity storage, ensuring your game runs smoothly without unexpected garbage collector pauses.

*   🛡️ **Robust Entity Versioning:** Built-in versioning prevents bugs related to reusing the IDs of "dead" entities, a common and hard-to-debug issue in other systems.

*   📦 **Zero Dependencies:** NAECS relies only on the Nim standard library.

## ⚙️ Installation

You can easily install NAECS via Nimble:

```bash
nimble install naecs
```
*(Note: This command will work once the package is published. For now, you can use a local path.)*

```bash
nimble install https://github.com/Hammer2900/naecs
```

Or add it to your project's `.nimble` file:
```nim
# myproject.nimble
requires "naecs >= 0.1.0"
```

## 🚀 Quick Start

Getting started with NAECS is incredibly simple.

```nim
import naecs

# 1. Define your components and tags
type
  Position = object
    x, y: float
  Velocity = object
    dx, dy: float
  PlayerTag = object

# 2. Create a world
var world = initWorld()

# 3. Create an entity and add components to it
let player = world.addEntity()
world.addComponent(player, Position(x: 10, y: 20))
world.addComponent(player, Velocity(dx: 1, dy: 0))
world.addTag(player, PlayerTag)

# 4. Write a system using the convenient macro
system world, movementSystem:
  pos: Position:
    vel: Velocity:
      # The macro automatically provides `pos` and `vel` variables
      # for every entity that has both components.
      pos.x += vel.dx
      pos.y += vel.dy

# 5. Run the system in your game loop
proc gameLoop() =
  movementSystem(world)
  # ... your rendering logic, etc.

gameLoop()
```

<hr>

## 📦 Prefabs: Rapid Prototyping Blueprints

Manually adding components to every entity can be tedious. **Prefabs** solve this by acting as reusable templates or "blueprints" for your entities. You define a prefab once—with a name, a set of components, and their default values—and then you can `spawn` new entities from it with a single command.

This is perfect for creating standard game objects like players, enemies, bullets, or items.

### Defining a Prefab

Use the powerful `prefab` macro to declare your blueprints. This is typically done once when your application starts.

```nim
# --- Define your prefabs ---
prefab "player":
  Position(x: 100, y: 100)
  Velocity(dx: 0, dy: 0)
  Renderable(sprite: "player.png")
  PlayerTag() # You can include tags too!

prefab "homing_missile":
  Position(x: 0, y: 0)
  Velocity(dx: 250, dy: 0)
  Renderable(sprite: "missile.png")

# --- Register them with the world ---
# The macro creates registration functions for you.
register_prefab_player(world)
register_prefab_homing_missile(world)
```

### Spawning from a Prefab

Once registered, use the `spawn` command to create an entity from a prefab. The real power comes from being able to **override** any of the default component values at spawn time.

```nim
# Spawn a player with all default values
let player1 = world.spawn("player")

# Spawn a missile at the player's location with a different velocity
let playerPos = world.getComponent(player1, Position)
let missile = world.spawn(
  "homing_missile",
  Position(x: playerPos.x, y: playerPos.y), # Override position
  Velocity(dx: 0, dy: -300)                  # Override velocity
)
```
This system dramatically speeds up development and keeps your entity creation logic clean and centralized.

<hr>

## 📖 API

### World
*   `initWorld(): World` — Creates and initializes a new world.
*   `addEntity(world): uint64` — Creates a new entity and returns its unique identifier.
*   `freeEntity(world, entity)` — "Kills" an entity, making its ID available for reuse.

### Components
*   `addComponent(world, entity, component)` — Adds a component to an entity. This may cause the entity to move to a new archetype.
*   `getComponent(world, entity, ComponentType): ptr T` — Returns a pointer to an entity's component.
*   `removeComponent(world, entity, ComponentType)` — Removes a component from an entity.
*   `hasComponent(world, entity, ComponentType): bool` — Checks if an entity has a specific component.

### Tags
*   `addTag(world, entity, TagType)` — Instantly adds a tag to an entity (a cheap operation).
*   `removeTag(world, entity, TagType)` — Instantly removes a tag.
*   `hasTag(world, entity, TagType): bool` — Checks if an entity has a specific tag.

### Systems and Queries

#### The `system` Macro (Recommended)
The cleanest and simplest way to write systems.

```nim
system world, renderSystem:
  pos: Position:
    sprite: Renderable:
      # Your logic here
      drawSprite(sprite.id, pos.x, pos.y)
```

<hr>

## 📢 The Event System: Decoupled Game Logic

As your game grows, systems need to talk to each other. A health system needs to tell the UI system to show a "Game Over" screen, or a physics system needs to tell a sound system to play a collision sound. Direct calls between systems create tangled, hard-to-maintain "spaghetti code."

NAECS provides a powerful, high-performance event system to solve this. It acts as a central message board where systems can post **events** without knowing or caring who is listening. This keeps your systems clean, modular, and completely decoupled.

The entire system is built on a simple, deterministic principle: **event queuing**.
1.  Systems **send** events during the main update phase. This is an extremely fast operation that just adds the event to a queue.
2.  At the end of the frame, you **dispatch** the queue, and all registered **listeners** are notified.

### 1. Define an Event
An event is just a simple Nim object that holds data.

```nim
type
  PlayerDiedEvent = object
    reason: string
  CollisionEvent = object
    entityA: uint64
    entityB: uint64
    impactForce: float
```

### 2. Send an Event
From any system (or anywhere you have access to the `world`), use `sendEvent`.

```nim
system world, healthSystem:
  health: HealthComponent:
    if health.current <= 0 and not world.hasTag(entity, IsDead):
      # Fire and forget! The health system doesn't know about UI, sound, or cleanup.
      world.sendEvent(PlayerDiedEvent(reason: "Ran out of health"))
      world.addTag(entity, IsDead) # Prevent sending the event every frame
```

### 3. Listen for an Event
A listener is a procedure that takes the `world` and a pointer to the event data. You can register as many listeners for an event as you need.

```nim
# A listener in your audio module
proc onPlayerDied_playSound(world: var World, e: ptr PlayerDiedEvent) =
  playSound("sad_trombone.wav")

# A listener in your UI module
proc onPlayerDied_showUI(world: var World, e: ptr PlayerDiedEvent) =
  showGameOverScreen("You died: " & e.reason)

# A listener in your cleanup module
proc onPlayerDied_cleanup(world: var World, e: ptr PlayerDiedEvent) =
  let deadPlayer = findEntityWithTag(PlayerTag) # Example
  world.freeEntity(deadPlayer)

# Register all listeners during initialization
world.registerListener(onPlayerDied_playSound)
world.registerListener(onPlayerDied_showUI)
world.registerListener(onPlayerDied_cleanup)
```

### Integrating into Your Game Loop
The rule is simple: dispatch events **once per frame**, *after* all your main systems have run. This creates a predictable, deterministic flow where all systems react to the state of the world *from the same frame*.

```nim
proc gameLoop() =
  # 1. Run all your normal systems
  inputSystem(world)
  movementSystem(world)
  healthSystem(world)
  # ... etc.

  # 2. Process all events that were queued up during this frame
  world.dispatchEventQueue()

  # 3. Render the final state
  renderSystem(world)
```
This elegant pattern ensures your game logic remains clean, scalable, and easy to debug.

<hr>

#### Iterators (For Advanced Cases)
For more complex queries, you can use the underlying iterators directly.

```nim
# Iterate over entities with Position
for entity in world.withComponent(Position):
  # ...

# Iterate over entities with both Position and Velocity
for entity in world.withComponents(Position, Velocity):
  # ...

# Iterate over entities with a component and a tag
for entity in world.withComponentTag(Position, PlayerTag):
  # ...
```

## 🛠️ Development and Testing

If you want to contribute to NAECS, here’s how to run the tests and benchmarks.

### Running Tests

The unit tests verify the correctness of all core logic.

```bash
nimble test
```
Or, to run a specific test file:
```bash
nim c -r tests/test1.nim
```

### Running the Benchmark

The benchmark measures the performance of key operations on a large number of entities. **Always run it in `release` mode!**

```bash
nim compile -d:release --run tests/bench.nim
```
Or the shorter version:
```bash
nim c -d:release -r tests/bench.nim
```

### Nimble Tasks (Makefile-like Commands)

This project uses Nimble tasks to automate common development actions.

*   **Generate Documentation:**
    ```bash
    nimble docs
    ```
    This command generates all HTML documentation and places it in the `docs/` directory.

*   **Run Unit Tests:**
    ```bash
    nimble test
    ```
    *(or `nimble run_tests`)*

*   **Run the Benchmark:**
    ```bash
    nimble run_bench
    ```
    This compiles and runs the benchmark in release mode for accurate measurements.

*   **Clean the Project:**
    ```bash
    nimble clean
    ```
    This removes all generated artifacts, including `nimcache`, documentation, and test binaries.

## Benchmark

These results are a direct consequence of the archetype architecture. Here is a sample of the performance on standard hardware (Intel Core i7) when simulating a world with **100,000 entities**:

```
--- TECS Benchmark (Archetype Version) ---
Configuration: 100000 entities, 100 frames.
------------------------
Running Population Benchmark...
  -> Populating 100000 entities took: 0.0112 seconds

Running Iteration Benchmark (using iterators)...
  -> Movement System (Pos+Vel) average frame time: 0.010964 ms
  -> Render System (Pos+Render) average frame time:   0.000579 ms
  -> Enemy AI System (Vel+EnemyTag) average frame time: 0.004215 ms
  -> Rare Boss System (6 filters) average frame time: 0.00042930 ms

Running Iteration Benchmark (using Seq)...
  -> Movement System (Pos+Vel) average frame time: 1.744379 ms
  -> Render System (Pos+Render) average frame time:   1.760250 ms
  -> Enemy AI System (Vel+EnemyTag) average frame time: 0.009740 ms

```
As you can see, even complex systems execute in thousandths of a millisecond, leaving you almost the entire frame budget (16.6 ms for 60 FPS) for your actual game logic.

## 📜 License

NAECS is distributed under the MIT License. See the `LICENSE` file for more information.