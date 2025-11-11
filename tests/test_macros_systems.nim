import std/unittest
import naecs

suite "System Macro Tests":
  setup:
    type
      Position = object
        x, y: float
      Velocity = object
        dx, dy: float
      Health = object
        current, max: int
      Damage = object
        value: int

    var world = initWorld()

  test "System with single component works":
    proc increaseHealth(world: var World, health: Health) {.system.} =
      health.current += 10

    # Создаём сущности
    let entity1 = world.addEntity()
    world.addComponent(entity1, Health(current: 50, max: 100))

    let entity2 = world.addEntity()
    world.addComponent(entity2, Health(current: 80, max: 100))

    # Запускаем систему
    world.increaseHealth()

    # Проверяем результаты
    let h1 = world.getComponent(entity1, Health)
    let h2 = world.getComponent(entity2, Health)

    check(h1.current == 60)
    check(h2.current == 90)

  test "System with two components works":
    proc movement(world: var World, pos: Position, vel: Velocity) {.system.} =
      pos.x += vel.dx
      pos.y += vel.dy

    let entity = world.addEntity()
    world.addComponent(entity, Position(x: 100.0, y: 200.0))
    world.addComponent(entity, Velocity(dx: 5.0, dy: -3.0))

    # Запускаем систему несколько раз
    world.movement()
    world.movement()
    world.movement()

    let pos = world.getComponent(entity, Position)
    check(pos.x == 115.0)
    check(pos.y == 191.0)

  test "System with three components works":
    proc applyDamage(world: var World, health: Health, damage: Damage, pos: Position) {.system.} =
      health.current -= damage.value
      # Можем использовать и другие компоненты
      if pos.x > 100:
        health.current -= 5  # Дополнительный урон

    let entity = world.addEntity()
    world.addComponent(entity, Health(current: 100, max: 100))
    world.addComponent(entity, Damage(value: 10))
    world.addComponent(entity, Position(x: 150.0, y: 0.0))

    world.applyDamage()

    let health = world.getComponent(entity, Health)
    check(health.current == 85)  # 100 - 10 - 5

  test "System only processes entities with ALL required components":
    proc processMovement(world: var World, pos: Position, vel: Velocity) {.system.} =
      pos.x += vel.dx

    let entity1 = world.addEntity()  # Есть оба компонента
    world.addComponent(entity1, Position(x: 0.0, y: 0.0))
    world.addComponent(entity1, Velocity(dx: 10.0, dy: 0.0))

    let entity2 = world.addEntity()  # Только Position
    world.addComponent(entity2, Position(x: 0.0, y: 0.0))

    let entity3 = world.addEntity()  # Только Velocity
    world.addComponent(entity3, Velocity(dx: 10.0, dy: 0.0))

    world.processMovement()

    # Только entity1 должна быть обработана
    let pos1 = world.getComponent(entity1, Position)
    let pos2 = world.getComponent(entity2, Position)

    check(pos1.x == 10.0)
    check(pos2.x == 0.0)  # Не изменилась

  test "System can be called multiple times":
    proc increment(world: var World, health: Health) {.system.} =
      health.current += 1

    let entity = world.addEntity()
    world.addComponent(entity, Health(current: 0, max: 100))

    for i in 1..10:
      world.increment()

    let health = world.getComponent(entity, Health)
    check(health.current == 10)

  test "Multiple systems can work together":
    proc moveEntities(world: var World, pos: Position, vel: Velocity) {.system.} =
      pos.x += vel.dx
      pos.y += vel.dy

    proc applyGravity(world: var World, vel: Velocity) {.system.} =
      vel.dy += 0.5

    let entity = world.addEntity()
    world.addComponent(entity, Position(x: 0.0, y: 0.0))
    world.addComponent(entity, Velocity(dx: 5.0, dy: 0.0))

    # Симулируем несколько кадров
    for frame in 1..3:
      world.applyGravity()
      world.moveEntities()

    let pos = world.getComponent(entity, Position)
    let vel = world.getComponent(entity, Velocity)

    check(pos.x == 15.0)  # 3 * 5
    check(vel.dy == 1.5)  # 3 * 0.5
    check(pos.y == 3.0)   # 0.5 + 1.0 + 1.5
