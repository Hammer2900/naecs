import std/unittest
import std/times
import std/tables
import naecs

test "Init world":
    var world = initWorld()
    check(world.maxEntityId.int == 1000)

suite "Full test":
  setup:
    type 
      PositionComponent = object
        entity: uint64
        x: int
        y: int
      MovableTag = object
    
    var world = initWorld()
  
  # teardown:
  #   discard
  
  test "Add entity":
    var entityId = world.addEntity

    check(getEntityId(entityId) == 1)
    check(getEntityVersion(entityId) == 1)

  test "Add component as object should be findable by filter":
    var entityId = world.addEntity
    world.addComponent(entityId, PositionComponent(x: 10))

    var filter = world.withComponentSeq(PositionComponent)
    check(filter.len == 1)
    check(filter[0] == entityId)

  test "Free entity ID should be reused with incremented version":
    var entityId1 = world.addEntity # ID: 1, Version: 1
    world.addComponent(entityId1, PositionComponent)

    world.freeEntity(entityId1)

    var entityId2 = world.addEntity # Должен переиспользовать ID 1

    # Проверяем, что ID тот же, а версия новая
    check(getEntityId(entityId2) == getEntityId(entityId1))
    check(getEntityId(entityId2) == 1)
    check(getEntityVersion(entityId2) == 2) # Версия увеличилась

    # Убедимся, что старый "хэндл" на сущность невалиден
    # (хотя в текущей реализации нет функции isValid(entity),
    # проверка версии - это косвенный способ)
    check(entityId2 != entityId1)

    # Также проверим, что у новой сущности нет старых компонентов
    var filter = world.withComponentSeq(PositionComponent)
    check(filter.len == 0)

  test "Removing a non-existent component should not crash":
    var entityId = world.addEntity
    world.removeComponent(entityId, PositionComponent) # Не должно быть ошибки
    # Можно добавить check(true), чтобы тест формально что-то проверял
    check(true)

  test "World should increase size when entities exceed initial capacity":
    # Создаем мир с маленьким начальным размером
    var smallWorld = initWorld(initAlloc = 10, allocSize = 10)

    # Создаем 11 сущностей, чтобы вызвать realloc
    for i in 1..11:
      discard smallWorld.addEntity

    # Проверяем, что мир расширился
    check(smallWorld.maxEntityId == 20)

    # Проверяем, что последняя добавленная сущность валидна
    var entity11 = 11'u64 shl 32 or 1'u64
    smallWorld.addComponent(entity11, PositionComponent(x: 99))
    var component = smallWorld.getComponent(entity11, PositionComponent)
    check(component.x == 99)

  test "Chained filters should work correctly":
      var entityId = world.addEntity # Только Position
      world.addComponent(entityId, PositionComponent(x: 10))

      var entityId2 = world.addEntity # Только Movable
      world.addTag(entityId2, MovableTag)

      var entityId3 = world.addEntity # И Position, и Movable
      world.addComponent(entityId3, PositionComponent(x: 20))
      world.addTag(entityId3, MovableTag)

      # Исправленная строка: добавлен 'world' в вызов withComponentSeq
      var filter = world.withTagSeq(MovableTag).withComponentSeq(world, PositionComponent)

      check(filter.len == 1)      # Должна быть найдена только одна сущность
      check(filter[0] == entityId3) # И это должна быть третья сущность
  
  test "Add component as typedesc":
    var entityId = world.addEntity
    var c = world.addComponent(entityId, PositionComponent)
  
  test "Get component":
    block:
      var entityId = world.addEntity
      world.addComponent(entityId, PositionComponent(x: 10))
      var component = world.getComponent(entityId, PositionComponent)

      check(component.x == 10)
      check(component.y == 0)
    block:
      var entityId = world.addEntity
      var c = world.addComponent(entityId, PositionComponent)
      var component = world.getComponent(entityId, PositionComponent)

      check(component.x == 0)
      check(component.y == 0)

  test "Add tag":
    var entityId = world.addEntity
    world.addTag(entityId, MovableTag)
  
  test "Filter with component":
    var entityId = world.addEntity
    var entityId2 = world.addEntity
    world.addTag(entityId2, MovableTag)
    world.addComponent(entityId, PositionComponent(x: 10))
    var filter = world.withComponentSeq(PositionComponent)

    check(filter.len == 1)
    check(filter[0] == entityId)
  
  test "Filter with tag":
    var entityId = world.addEntity
    var entityId2 = world.addEntity
    world.addTag(entityId2, MovableTag)
    world.addComponent(entityId, PositionComponent(x: 10))
    var filter = world.withTagSeq(MovableTag)

    check(filter.len == 1)
    check(filter[0] == entityId2)
  
  test "Remove component":
    var entityId = world.addEntity
    var entityId2 = world.addEntity
    world.addComponent(entityId, PositionComponent(x: 10))
    world.addComponent(entityId2, PositionComponent)
    var filter = world.withComponentSeq(PositionComponent)

    check(filter.len == 2)

    world.removeComponent(entityId, PositionComponent)
    filter = world.withComponentSeq(PositionComponent)

    check(filter.len == 1)
    check(filter[0] == entityId2)
  
  test "Remove tag":
    var entityId = world.addEntity
    var entityId2 = world.addEntity
    world.addTag(entityId, MovableTag)
    world.addTag(entityId2, MovableTag)
    var filter = world.withTagSeq(MovableTag)

    check(filter.len == 2)

    world.removeTag(entityId, MovableTag)
    filter = world.withTagSeq(MovableTag)

    check(filter.len == 1)
    check(filter[0] == entityId2)

  test "Free entity":
    var entityId = world.addEntity
    var entityId2 = world.addEntity
    world.addTag(entityId, MovableTag)
    world.addTag(entityId2, MovableTag)
    var filter = world.withTagSeq(MovableTag)

    check(filter.len == 2)

    world.freeEntity(entityId)
    filter = world.withTagSeq(MovableTag)

    check(filter.len == 1)
    check(filter[0] == entityId2)

  test "Iterator withComponent works":
    var entityId = world.addEntity
    world.addComponent(entityId, PositionComponent(x: 10))

    var entityId2 = world.addEntity
    world.addComponent(entityId2, PositionComponent(x: 20))

    var count = 0
    var foundIds: seq[uint64]

    # Используем итератор напрямую
    for entity in world.withComponent(PositionComponent):
      count += 1
      foundIds.add(entity)

    check(count == 2)
    check(entityId in foundIds)
    check(entityId2 in foundIds)

  test "Iterator withTag works":
    var entityId = world.addEntity
    world.addTag(entityId, MovableTag)

    var entityId2 = world.addEntity
    world.addTag(entityId2, MovableTag)

    var count = 0
    for entity in world.withTag(MovableTag):
      count += 1

    check(count == 2)

  test "Iterator can modify components in loop":
    var entityId = world.addEntity
    world.addComponent(entityId, PositionComponent(x: 10, y: 5))

    var entityId2 = world.addEntity
    world.addComponent(entityId2, PositionComponent(x: 20, y: 15))

    # Модифицируем через итератор
    for entity in world.withComponent(PositionComponent):
      var pos = world.getComponent(entity, PositionComponent)
      pos.x += 100

    # Проверяем что изменения применились
    var pos1 = world.getComponent(entityId, PositionComponent)
    var pos2 = world.getComponent(entityId2, PositionComponent)

    check(pos1.x == 110)
    check(pos2.x == 120)

  test "Iterator doesn't find removed entities":
    var entityId = world.addEntity
    world.addComponent(entityId, PositionComponent(x: 10))

    var entityId2 = world.addEntity
    world.addComponent(entityId2, PositionComponent(x: 20))

    world.freeEntity(entityId)

    var count = 0
    var foundId: uint64
    for entity in world.withComponent(PositionComponent):
      count += 1
      foundId = entity

    check(count == 1)
    check(foundId == entityId2)

  test "Iterator works with empty world":
    var count = 0
    for entity in world.withComponent(PositionComponent):
      count += 1

    check(count == 0)

  test "Iterator produces same results as Seq version":
    # Создаем несколько сущностей
    var entity1 = world.addEntity
    world.addComponent(entity1, PositionComponent(x: 1))

    var entity2 = world.addEntity
    world.addComponent(entity2, PositionComponent(x: 2))
    world.addTag(entity2, MovableTag)

    var entity3 = world.addEntity
    world.addTag(entity3, MovableTag)

    # Собираем результаты итератора
    var iterResults: seq[uint64]
    for entity in world.withComponent(PositionComponent):
      iterResults.add(entity)

    # Получаем результаты Seq версии
    var seqResults = world.withComponentSeq(PositionComponent)

    # Сравниваем
    check(iterResults.len == seqResults.len)
    check(iterResults == seqResults)

  test "Iterator is faster than Seq version (benchmark)":
    # Создаем много сущностей
    for i in 0..<1000:
      var entity = world.addEntity
      world.addComponent(entity, PositionComponent(x: i))

    # Тест Seq версии
    let startSeq = cpuTime()
    for i in 0..<100:
      var filter = world.withComponentSeq(PositionComponent)
      for entity in filter:
        var pos = world.getComponent(entity, PositionComponent)
        pos.x += 1
    let timeSeq = cpuTime() - startSeq

    # Тест итератора
    let startIter = cpuTime()
    for i in 0..<100:
      for entity in world.withComponent(PositionComponent):
        var pos = world.getComponent(entity, PositionComponent)
        pos.x += 1
    let timeIter = cpuTime() - startIter

    echo "Seq version: ", timeSeq, " seconds"
    echo "Iterator version: ", timeIter, " seconds"
    echo "Speedup: ", timeSeq / timeIter, "x"

    # Итератор должен быть быстрее
    check(timeIter < timeSeq)

  test "Iterator chains work with manual filtering":
    var entity1 = world.addEntity
    world.addComponent(entity1, PositionComponent(x: 10))

    var entity2 = world.addEntity
    world.addTag(entity2, MovableTag)

    var entity3 = world.addEntity
    world.addComponent(entity3, PositionComponent(x: 20))
    world.addTag(entity3, MovableTag)

    var count = 0
    var foundId: uint64

    # Фильтруем по тегу через итератор, потом проверяем компонент
    for entity in world.withTag(MovableTag):
      if world.hasComponent(entity, PositionComponent):
        count += 1
        foundId = entity

    check(count == 1)
    check(foundId == entity3)

  test "hasComponent and hasTag work correctly":
    var entity = world.addEntity

    # Изначально нет ни компонента, ни тега
    check(not world.hasComponent(entity, PositionComponent))
    check(not world.hasTag(entity, MovableTag))

    # Добавляем компонент
    world.addComponent(entity, PositionComponent(x: 10))
    check(world.hasComponent(entity, PositionComponent))
    check(not world.hasTag(entity, MovableTag))

    # Добавляем тег
    world.addTag(entity, MovableTag)
    check(world.hasComponent(entity, PositionComponent))
    check(world.hasTag(entity, MovableTag))

    # Удаляем компонент
    world.removeComponent(entity, PositionComponent)
    check(not world.hasComponent(entity, PositionComponent))
    check(world.hasTag(entity, MovableTag))

# Добавьте этот код в ваш файл с тестами (например, tests/test1.nim)
# Убедитесь, что tecs импортируется

suite "Event System Tests":
  setup:
    # Определяем типы событий, которые будем использовать в тестах
    type
      TestEventA = object
        value: int
      TestEventB = object
        message: string
        entityId: uint64
      UnlistenedEvent = object # Событие, у которого нет подписчиков
        data: float

    # Переменные для хранения результатов работы слушателей
    var receivedValueA = 0
    var receivedMessageB = ""
    var receivedEntityB: uint64 = 0
    var listenerACalls = 0
    var listenerBCalls = 0
    var anotherListenerACalls = 0

    # Создаем мир для каждого теста
    var world = initWorld()

    # Определяем процедуры-слушатели
    proc listenerForEventA(w: var World, e: ptr TestEventA) =
      listenerACalls += 1
      receivedValueA = e.value

    proc anotherListenerForEventA(w: var World, e: ptr TestEventA) =
      anotherListenerACalls += 1
      # Этот слушатель просто считает вызовы

    proc listenerForEventB(w: var World, e: ptr TestEventB) =
      listenerBCalls += 1
      receivedMessageB = e.message
      receivedEntityB = e.entityId

  # Сбрасываем состояние перед каждым тестом
  teardown:
    receivedValueA = 0
    receivedMessageB = ""
    receivedEntityB = 0
    listenerACalls = 0
    listenerBCalls = 0
    anotherListenerACalls = 0

  test "Registering a listener":
      world.registerListener(listenerForEventA)
      # Проверяем, что в таблице слушателей появилась запись для нашего типа события
      check(world.eventListeners.hasKey("TestEventA"))
      check(world.eventListeners["TestEventA"].len == 1)

  test "Sending a single event is processed by a single listener":
    # 1. Подписываемся на событие
    world.registerListener(listenerForEventA)

    # 2. Отправляем событие
    world.sendEvent(TestEventA(value: 123))

    # 3. До вызова dispatchEventQueue ничего не должно произойти
    check(listenerACalls == 0)
    check(receivedValueA == 0)
    check("TestEventA" in world.eventQueues)
    check(world.eventQueues["TestEventA"].len == 1)

    # 4. Обрабатываем очередь
    world.dispatchEventQueue()

    # 5. Проверяем, что слушатель был вызван и получил правильные данные
    check(listenerACalls == 1)
    check(receivedValueA == 123)

  test "A single event is processed by multiple listeners":
    # 1. Подписываемся на одно и то же событие двумя разными слушателями
    world.registerListener(listenerForEventA)
    world.registerListener(anotherListenerForEventA)

    # 2. Отправляем событие
    world.sendEvent(TestEventA(value: 456))

    # 3. Обрабатываем очередь
    world.dispatchEventQueue()

    # 4. Проверяем, что оба слушателя были вызваны
    check(listenerACalls == 1)
    check(anotherListenerACalls == 1)
    check(receivedValueA == 456)

  test "Multiple events of the same type are processed correctly":
    world.registerListener(listenerForEventA)

    # Отправляем три события одного типа
    world.sendEvent(TestEventA(value: 1))
    world.sendEvent(TestEventA(value: 2))
    world.sendEvent(TestEventA(value: 3))

    check(world.eventQueues["TestEventA"].len == 3)

    world.dispatchEventQueue()

    # Слушатель должен быть вызван три раза
    check(listenerACalls == 3)
    # И последнее полученное значение должно быть от последнего события
    check(receivedValueA == 3)

  test "Events of different types are processed independently":
    let entity = world.addEntity()
    world.registerListener(listenerForEventA)
    world.registerListener(listenerForEventB)

    # Отправляем два разных события
    world.sendEvent(TestEventA(value: 777))
    world.sendEvent(TestEventB(message: "hello", entityId: entity))

    check(world.eventQueues["TestEventA"].len == 1)
    check(world.eventQueues["TestEventB"].len == 1)

    world.dispatchEventQueue()

    # Проверяем, что каждый слушатель был вызван один раз со своими данными
    check(listenerACalls == 1)
    check(receivedValueA == 777)
    check(listenerBCalls == 1)
    check(receivedMessageB == "hello")
    check(receivedEntityB == entity)

  test "Event queue is cleared after dispatch":
    world.registerListener(listenerForEventA)
    world.sendEvent(TestEventA(value: 1))

    # Убедимся, что очередь не пуста
    check(world.eventQueues["TestEventA"].len > 0)

    # Диспетчер должен очистить очередь
    world.dispatchEventQueue()
    check(world.eventQueues["TestEventA"].len == 0)

    # Второй вызов dispatchEventQueue не должен ничего делать
    receivedValueA = 0
    listenerACalls = 0
    world.dispatchEventQueue()
    check(listenerACalls == 0)
    check(receivedValueA == 0)

  test "Sending an event with no listeners does not crash":
    # Отправляем событие, на которое никто не подписан
    world.sendEvent(UnlistenedEvent(data: 3.14))

    # Обработка не должна вызвать ошибок
    world.dispatchEventQueue()

    # Проверяем, что другие слушатели не были вызваны
    check(listenerACalls == 0)
    check(listenerBCalls == 0)

    # Убедимся, что очередь для этого события тоже очистилась
    check(world.eventQueues["UnlistenedEvent"].len == 0)