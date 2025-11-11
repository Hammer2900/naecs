import std/times
import std/strformat
import ../src/tecs # Убедитесь, что путь до вашего `tecs.nim` правильный

# --- Конфигурация бенчмарка ---
const
  EntityCount = 100_000 # Количество сущностей для теста
  FrameCount = 100      # Сколько "кадров" симулируем для теста итерации

echo &"--- TECS Benchmark (Archetype Version) ---"
echo &"Configuration: {EntityCount} entities, {FrameCount} frames."
echo "------------------------"

# --- Компоненты и Теги для теста ---
type
  Position = object
    x, y: float32

  Velocity = object
    dx, dy: float32

  Renderable = object
    spriteId: int

  AIState = object # Дополнительный компонент для редкого случая
    state: int

  PlayerTag = object
  EnemyTag = object
  BossTag = object # Дополнительный тег для редкого случая

# --- 1. Тест на скорость создания сущностей ---

proc benchmarkPopulation(): World =
  echo "Running Population Benchmark..."
  var world = initWorld(initAlloc = EntityCount + 1000) # Предаллоцируем память

  let start = cpuTime()

  for i in 0..<EntityCount:
    let entity = world.addEntity

    # Создаем разные "архетипы" сущностей, чтобы симулировать реальный мир
    case i mod 1000 # Используем большое число для создания редкого случая
    of 0: # Движущийся объект (игрок)
      world.addComponent(entity, Position(x: 0, y: 0))
      world.addComponent(entity, Velocity(dx: 1, dy: 1))
      world.addTag(entity, PlayerTag)
    of 1: # Движущийся и видимый объект (враг)
      world.addComponent(entity, Position(x: 0, y: 0))
      world.addComponent(entity, Velocity(dx: -1, dy: 0.5))
      world.addComponent(entity, Renderable(spriteId: i))
      world.addTag(entity, EnemyTag)
    of 2: # Статичный видимый объект (дерево)
      world.addComponent(entity, Position(x: 0, y: 0))
      world.addComponent(entity, Renderable(spriteId: i))
    of 999: # Очень редкий босс (1 на 1000)
      world.addComponent(entity, Position(x: 0, y: 0))
      world.addComponent(entity, Velocity(dx: 5, dy: 5))
      world.addComponent(entity, Renderable(spriteId: i))
      world.addComponent(entity, AIState(state: 1))
      world.addTag(entity, EnemyTag)
      world.addTag(entity, BossTag)
    else: # Невидимый логический объект (триггер)
      world.addComponent(entity, Position(x: 0, y: 0))

  let elapsed = cpuTime() - start
  echo &"  -> Populating {EntityCount} entities took: {elapsed:.4f} seconds"

  return world


# --- 2. Тест на скорость итерации (симуляция систем) ---

# Создадим специальный итератор для редкого случая, чтобы тест был честным
iterator withRareCombo*(world: var World): uint64 =
  let posMask = 1'u64 shl world.getComponentID(Position)
  let velMask = 1'u64 shl world.getComponentID(Velocity)
  let renderMask = 1'u64 shl world.getComponentID(Renderable)
  let aiMask = 1'u64 shl world.getComponentID(AIState)
  let combinedCompMask = posMask or velMask or renderMask or aiMask

  let enemyMask = 1'u64 shl world.getTagID(EnemyTag)
  let bossMask = 1'u64 shl world.getTagID(BossTag)
  let combinedTagMask = enemyMask or bossMask

  for archetype in world.archetypes:
    if (archetype.componentMask and combinedCompMask) == combinedCompMask and
       (archetype.tagMask and combinedTagMask) == combinedTagMask:
      for entityId in archetype.entities:
        if world.entities[entityId].version > 0:
          yield entityId.uint64 shl 32 + world.entities[entityId].version.uint64


proc benchmarkIteration(world: var World) =
  echo "\nRunning Iteration Benchmark (using iterators)..."

  # --- Система Движения ---
  block movementSystem:
    var totalTime: float = 0
    for frame in 1..FrameCount:
      let start = cpuTime()
      for entity in world.withComponents(Position, Velocity):
        let pos = world.getComponent(entity, Position)
        let vel = world.getComponent(entity, Velocity)
        pos.x += vel.dx
        pos.y += vel.dy
      totalTime += cpuTime() - start
    echo &"  -> Movement System (Pos+Vel) average frame time: {(totalTime / FrameCount.float) * 1000:.6f} ms"

  # --- Система Рендеринга ---
  block renderSystem:
    var totalTime: float = 0
    for frame in 1..FrameCount:
      let start = cpuTime()
      var renderCount = 0
      for entity in world.withComponents(Position, Renderable):
        renderCount += 1
      totalTime += cpuTime() - start
    echo &"  -> Render System (Pos+Render) average frame time:   {(totalTime / FrameCount.float) * 1000:.6f} ms"

  # --- Система AI врагов ---
  block enemyAiSystem:
    var totalTime: float = 0
    for frame in 1..FrameCount:
      let start = cpuTime()
      for entity in world.withComponentTag(Velocity, EnemyTag):
        let vel = world.getComponent(entity, Velocity)
        vel.dx *= -1.0
      totalTime += cpuTime() - start
    echo &"  -> Enemy AI System (Vel+EnemyTag) average frame time: {(totalTime / FrameCount.float) * 1000:.6f} ms"

  # --- СИСТЕМА ДЛЯ РЕДКИХ СУЩНОСТЕЙ (ЗДЕСЬ БУДЕТ МАГИЯ) ---
  block rareSystem:
    var totalTime: float = 0
    for frame in 1..FrameCount:
      let start = cpuTime()
      var count = 0
      for entity in world.withRareCombo():
        let ai = world.getComponent(entity, AIState)
        # Симулируем какую-то работу
        if ai.state == 1:
          count += 1
      totalTime += cpuTime() - start
    echo &"  -> Rare Boss System (6 filters) average frame time: {(totalTime / FrameCount.float) * 1000:.8f} ms"


proc benchmarkIterationSeq(world: var World) =
  echo "\nRunning Iteration Benchmark (using Seq)..."

  # --- Система Движения (с Seq) ---
  block movementSystem:
    var totalTime: float = 0
    for frame in 1..FrameCount:
      let start = cpuTime()
      let filter = world.withComponentSeq(Position).withComponentSeq(world, Velocity)
      for entity in filter:
        let pos = world.getComponent(entity, Position)
        let vel = world.getComponent(entity, Velocity)
        pos.x += vel.dx
        pos.y += vel.dy
      totalTime += cpuTime() - start
    echo &"  -> Movement System (Pos+Vel) average frame time: {(totalTime / FrameCount.float) * 1000:.6f} ms"

  # --- Система Рендеринга (с Seq) ---
  block renderSystem:
    var totalTime: float = 0
    for frame in 1..FrameCount:
      let start = cpuTime()
      let filter = world.withComponentSeq(Position).withComponentSeq(world, Renderable)
      var renderCount = 0
      for entity in filter:
        renderCount += 1
      totalTime += cpuTime() - start
    echo &"  -> Render System (Pos+Render) average frame time:   {(totalTime / FrameCount.float) * 1000:.6f} ms"

  # --- Система AI врагов (с Seq) ---
  block enemyAiSystem:
    var totalTime: float = 0
    for frame in 1..FrameCount:
      let start = cpuTime()
      let filter = world.withComponentSeq(Velocity).withTagSeq(world, EnemyTag)
      for entity in filter:
        let vel = world.getComponent(entity, Velocity)
        vel.dx *= -1.0
      totalTime += cpuTime() - start
    echo &"  -> Enemy AI System (Vel+EnemyTag) average frame time: {(totalTime / FrameCount.float) * 1000:.6f} ms"


# --- Запуск всех тестов ---
var world = benchmarkPopulation()
benchmarkIteration(world)
benchmarkIterationSeq(world)
echo "\n------------------------"
echo "Benchmark finished."