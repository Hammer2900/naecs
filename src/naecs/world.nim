import std/tables
import std/hashes
import strutils
import macros

#------------------------------------------------------------------------------
# Type Definitions
#------------------------------------------------------------------------------

type
  ## (Internal) A procedure that initializes a component on an entity for a prefab.
  ComponentInitializer = proc(world: var World, entity: uint64, overrides: pointer)

  ## (Internal) Represents a prefab (entity template) with a name and a list of initializers.
  Prefab = object
    name*: string
    initializers*: seq[ComponentInitializer]

  Entity* = object
      ## Represents a unique entity in the world, combining an ID and a version.
      version*: uint32
      archetypeIndex: int      # Index of the archetype this entity belongs to.
      indexInArchetype: int    # Index of the entity's data within its archetype.
      tagBitmask*: uint64     # Bitmask for up to 64 unique tags, stored per-entity.

  ## (Internal) Storage for a single component type within an archetype.
  ComponentStorage = object
    data: pointer
    componentSize: int
    count: int
    capacity: int

  ## (Internal) An archetype represents a unique combination of component types.
  Archetype = object
    componentMask*: uint64
    tagMask*: uint64
    entities*: seq[uint32]  # IDs of entities in this archetype.
    componentStorages: seq[ComponentStorage]  # Component data arrays.
    componentIds: seq[uint32]  # The component IDs this archetype contains.

  World* = object
    ## The main container for all ECS data, including entities, components, and systems.
    entities*: seq[Entity]
    freeEntities: seq[uint32]
    currentEntityId*: uint32
    maxEntityId*: uint32
    allocSize*: uint32

    archetypes*: seq[Archetype]
    archetypeMap: Table[uint64, int]  # Maps a componentMask to an archetype index.

    componentTypeMap: Table[string, uint32]
    tagTypeMap: Table[string, uint32]
    nextComponentId: uint32
    nextTagId: uint32
    prefabs*: Table[string, Prefab]
    eventListeners*: Table[string, seq[EventListener]]
    eventQueues*: Table[string, seq[pointer]]

  EventListener = proc(w: var World, data: pointer) {.closure.}
  ## A type alias for a procedure that can act as an event listener.
  ## It supports closures, allowing it to be defined within other scopes.

#------------------------------------------------------------------------------
# Internal Procs & Memory Management
#------------------------------------------------------------------------------

proc hash(x: uint64): Hash =
  result = hash(cast[int](x))

proc `=destroy`(storage: var ComponentStorage) =
  if storage.data != nil:
    deallocShared(storage.data)

proc `=destroy`(archetype: var Archetype) =
  for storage in archetype.componentStorages.mitems:
    `=destroy`(storage)

proc `=destroy`(world: var World) =
  for archetype in world.archetypes.mitems:
    `=destroy`(archetype)
  # Clean up any remaining events in the queues to prevent memory leaks
  for _, queue in world.eventQueues:
    for eventPtr in queue:
      deallocShared(eventPtr)

proc initWorld*(initAlloc: uint32 = 1000, allocSize: uint32 = 1000): World =
  ## Initializes a new `World` object.
  ## `initAlloc`: The initial number of entities to pre-allocate memory for.
  ## `allocSize`: The number of new entity slots to add when the world's capacity is exceeded.
  result = World()
  result.entities.setLen(initAlloc)
  result.maxEntityId = initAlloc
  result.allocSize = allocSize
  result.componentTypeMap = initTable[string, uint32]()
  result.tagTypeMap = initTable[string, uint32]()
  result.archetypeMap = initTable[uint64, int]()
  result.nextComponentId = 0
  result.nextTagId = 0
  result.prefabs = initTable[string, Prefab]()
  result.prefabs = initTable[string, Prefab]()
  result.eventListeners = initTable[string, seq[proc(w: var World, data: pointer)]]()
  result.eventQueues = initTable[string, seq[pointer]]()

  # Create an empty archetype for entities with no components.
  result.archetypes.add(Archetype(
    componentMask: 0,
    entities: @[],
    componentStorages: @[],
    componentIds: @[]
  ))
  result.archetypeMap[0] = 0

proc increaseWorld(world: var World) =
  # (Internal) Expands the entity capacity of the world.
  world.maxEntityId += world.allocSize
  world.entities.setLen(world.maxEntityId)

proc getEntityId*(entity: uint64): uint32 {.inline.} =
  ## Extracts the 32-bit ID from a 64-bit entity handle.
  return (entity shr 32).uint32

proc getEntityVersion*(entity: uint64): uint32 {.inline.} =
  ## Extracts the 32-bit version from a 64-bit entity handle.
  return entity.uint32

proc getNewEntityID(world: var World): uint32 {.inline.} =
  # (Internal) Gets the next available entity ID.
  inc world.currentEntityId
  return world.currentEntityId

proc registerComponent(world: var World, componentType: typedesc) {.inline.} =
  # (Internal) Assigns a unique ID to a component type if not already registered.
  let typeName = $componentType
  if typeName notin world.componentTypeMap:
    assert(world.nextComponentId < 64, "Component type limit reached (max 64)")
    world.componentTypeMap[typeName] = world.nextComponentId
    inc world.nextComponentId

proc getComponentID*(world: var World, componentType: typedesc): uint32 {.inline.} =
  ## Gets the unique ID for a component type, registering it if it's the first time.
  let typeName = $componentType
  if typeName notin world.componentTypeMap:
    world.registerComponent(componentType)
  return world.componentTypeMap[typeName]

proc registerTag(world: var World, tagType: typedesc) {.inline.} =
  # (Internal) Assigns a unique ID to a tag type if not already registered.
  let typeName = $tagType
  if typeName notin world.tagTypeMap:
    assert(world.nextTagId < 64, "Tag type limit reached (max 64)")
    world.tagTypeMap[typeName] = world.nextTagId
    inc world.nextTagId

proc getTagID*(world: var World, tagType: typedesc): uint32 {.inline.} =
  ## Gets the unique ID for a tag type, registering it if it's the first time.
  let typeName = $tagType
  if typeName notin world.tagTypeMap:
    world.registerTag(tagType)
  return world.tagTypeMap[typeName]

# (Internal) Archetype and component storage management procs.
proc getOrCreateArchetype(world: var World, componentMask: uint64, componentIds: seq[uint32]): int =
  ## Получает или создаёт архетип с заданной маской компонентов
  if componentMask in world.archetypeMap:
    return world.archetypeMap[componentMask]

  # Создаём новый архетип
  var newArchetype = Archetype(
    componentMask: componentMask,
    entities: @[],
    componentStorages: @[],
    componentIds: componentIds
  )

  world.archetypes.add(newArchetype)
  let archetypeIndex = world.archetypes.len - 1
  world.archetypeMap[componentMask] = archetypeIndex
  return archetypeIndex

proc growStorage(storage: var ComponentStorage) =
  ## Увеличивает размер хранилища компонентов
  let newCapacity = if storage.capacity == 0: 16 else: storage.capacity * 2
  let newSize = storage.componentSize * newCapacity
  let oldSize = storage.componentSize * storage.capacity

  storage.data = reallocShared0(storage.data, oldSize, newSize)
  storage.capacity = newCapacity

proc addEntityToArchetype(world: var World, entityId: uint32, archetypeIndex: int) =
  ## Добавляет сущность в архетип
  var archetype = world.archetypes[archetypeIndex].addr

  # Увеличиваем хранилища если нужно
  for storage in archetype.componentStorages.mitems:
    if storage.count >= storage.capacity:
      growStorage(storage)

  # Добавляем ID сущности
  archetype.entities.add(entityId)
  let indexInArchetype = archetype.entities.len - 1

  # Обновляем информацию о сущности
  world.entities[entityId].archetypeIndex = archetypeIndex
  world.entities[entityId].indexInArchetype = indexInArchetype

  # Увеличиваем счётчики в хранилищах
  for storage in archetype.componentStorages.mitems:
    inc storage.count

proc removeEntityFromArchetype(world: var World, entityId: uint32) =
  ## Удаляет сущность из текущего архетипа
  let archetypeIndex = world.entities[entityId].archetypeIndex
  let indexInArchetype = world.entities[entityId].indexInArchetype

  if archetypeIndex < 0:
    return

  var archetype = world.archetypes[archetypeIndex].addr
  let lastIndex = archetype.entities.len - 1

  if indexInArchetype != lastIndex:
    # Swap with last entity
    let lastEntityId = archetype.entities[lastIndex]
    archetype.entities[indexInArchetype] = lastEntityId
    world.entities[lastEntityId].indexInArchetype = indexInArchetype

    # Копируем данные компонентов
    for i, storage in archetype.componentStorages.mpairs:
      let componentSize = storage.componentSize
      let srcPtr = cast[pointer](cast[int](storage.data) + lastIndex * componentSize)
      let dstPtr = cast[pointer](cast[int](storage.data) + indexInArchetype * componentSize)
      copyMem(dstPtr, srcPtr, componentSize)

  archetype.entities.setLen(lastIndex)
  for storage in archetype.componentStorages.mitems:
    dec storage.count

proc moveEntityToArchetype[T](world: var World, entityId: uint32, newArchetypeIndex: int, component: T) =
  ## Перемещает сущность в новый архетип с добавлением компонента
  let oldArchetypeIndex = world.entities[entityId].archetypeIndex
  let oldIndexInArchetype = world.entities[entityId].indexInArchetype

  # Сохраняем старые данные компонентов
  var oldComponents: seq[(uint32, pointer)]
  if oldArchetypeIndex >= 0:
    let oldArchetype = world.archetypes[oldArchetypeIndex].addr
    for i, compId in oldArchetype.componentIds:
      let storage = oldArchetype.componentStorages[i].addr
      let dataPtr = cast[pointer](cast[int](storage.data) + oldIndexInArchetype * storage.componentSize)
      # Выделяем память и копируем данные
      let tempData = allocShared0(storage.componentSize)
      copyMem(tempData, dataPtr, storage.componentSize)
      oldComponents.add((compId, tempData))

  # Удаляем из старого архетипа
  if oldArchetypeIndex >= 0:
    removeEntityFromArchetype(world, entityId)

  # Добавляем в новый архетип
  addEntityToArchetype(world, entityId, newArchetypeIndex)

  # Восстанавливаем старые компоненты и добавляем новый
  let newArchetype = world.archetypes[newArchetypeIndex].addr
  let newIndexInArchetype = world.entities[entityId].indexInArchetype

  for i, compId in newArchetype.componentIds:
    var storage = newArchetype.componentStorages[i].addr
    let dataPtr = cast[pointer](cast[int](storage.data) + newIndexInArchetype * storage.componentSize)

    # Ищем старые данные этого компонента
    var found = false
    for (oldCompId, oldData) in oldComponents:
      if oldCompId == compId:
        copyMem(dataPtr, oldData, storage.componentSize)
        found = true
        break

    # Если это новый компонент
    if not found and compId == world.getComponentID(T):
      cast[ptr T](dataPtr)[] = component

  # Освобождаем временные данные
  for (_, tempData) in oldComponents:
    deallocShared(tempData)

#------------------------------------------------------------------------------
# Public API: Entity, Component, Tag Management
#------------------------------------------------------------------------------

proc addEntity*(world: var World): uint64 =
  ## Creates a new entity in the world and returns its unique 64-bit handle.
  ## Reuses old entity IDs if available, incrementing the version for safety.
  var id: uint32 = 0
  if world.freeEntities.len > 0:
    id = world.freeEntities.pop
  else:
    id = world.getNewEntityID()
    while id >= world.maxEntityId:
      world.increaseWorld()

  world.entities[id].version += 1
  world.entities[id].archetypeIndex = 0  # Пустой архетип
  world.entities[id].indexInArchetype = -1
  world.entities[id].tagBitmask = 0  # Сбрасываем теги

  addEntityToArchetype(world, id, 0)

  return id.uint64 shl 32 + world.entities[id].version.uint64

proc addComponent*[T](world: var World, entity: uint64, component: T): ptr T {.discardable.} =
  ## Adds a component to an entity. This may cause the entity to move to a new archetype.
  ## Returns a pointer to the newly added component data.
  let entityId = getEntityId(entity)
  let componentId = world.getComponentID(T)
  let componentMask = 1'u64 shl componentId

  let currentArchetypeIndex = world.entities[entityId].archetypeIndex
  let currentMask = world.archetypes[currentArchetypeIndex].componentMask
  let newMask = currentMask or componentMask

  # Собираем список ID компонентов для нового архетипа
  var componentIds: seq[uint32] = @[]
  for i in 0'u32..<64:
    if (newMask and (1'u64 shl i)) != 0:
      componentIds.add(i)

  # Получаем или создаём новый архетип
  let newArchetypeIndex = world.getOrCreateArchetype(newMask, componentIds)

  # Если архетип новый, создаём хранилища компонентов
  if world.archetypes[newArchetypeIndex].componentStorages.len == 0:
    for compId in componentIds:
      # Находим размер компонента
      var compSize = sizeof(T)
      if compId == componentId:
        compSize = sizeof(T)
      else:
        # Для других компонентов берём размер из старого архетипа
        let oldArchetype = world.archetypes[currentArchetypeIndex].addr
        for i, oldCompId in oldArchetype.componentIds:
          if oldCompId == compId:
            compSize = oldArchetype.componentStorages[i].componentSize
            break

      world.archetypes[newArchetypeIndex].componentStorages.add(ComponentStorage(
        data: nil,
        componentSize: compSize,
        count: 0,
        capacity: 0
      ))

  # Перемещаем сущность в новый архетип
  moveEntityToArchetype(world, entityId, newArchetypeIndex, component)

  # Возвращаем указатель на компонент
  let archetype = world.archetypes[newArchetypeIndex].addr
  let indexInArchetype = world.entities[entityId].indexInArchetype

  for i, compId in archetype.componentIds:
    if compId == componentId:
      let storage = archetype.componentStorages[i].addr
      let dataPtr = cast[pointer](cast[int](storage.data) + indexInArchetype * storage.componentSize)
      return cast[ptr T](dataPtr)

  raise newException(AssertionError, "Component was not found in archetype immediately after adding")

proc addComponent*[T](world: var World, entity: uint64, componentType: typedesc[T]): ptr T {.discardable.} =
  ## Adds a component to an entity using its default value.
  return world.addComponent(entity, T())

proc getComponent*[T](world: var World, entity: uint64, componentType: typedesc[T]): ptr T =
  ## Retrieves a pointer to an entity's component.
  ## Returns `nil` if the entity does not have the specified component.
  let entityId = getEntityId(entity)
  let componentId = world.getComponentID(T)

  let archetypeIndex = world.entities[entityId].archetypeIndex
  let indexInArchetype = world.entities[entityId].indexInArchetype
  let archetype = world.archetypes[archetypeIndex].addr

  for i, compId in archetype.componentIds:
    if compId == componentId:
      let storage = archetype.componentStorages[i].addr
      let dataPtr = cast[pointer](cast[int](storage.data) + indexInArchetype * storage.componentSize)
      return cast[ptr T](dataPtr)

  return nil

proc removeComponent*(world: var World, entity: uint64, componentType: typedesc) =
  ## Removes a component from an entity. This may cause the entity to move to a new archetype.
  let entityId = getEntityId(entity)
  let componentId = world.getComponentID(componentType)
  let componentMask = 1'u64 shl componentId

  let currentArchetypeIndex = world.entities[entityId].archetypeIndex
  let currentMask = world.archetypes[currentArchetypeIndex].componentMask

  if (currentMask and componentMask) == 0:
    return

  let newMask = currentMask xor componentMask

  var componentIds: seq[uint32] = @[]
  for i in 0'u32..<64:
    if (newMask and (1'u64 shl i)) != 0:
      componentIds.add(i)

  let newArchetypeIndex = world.getOrCreateArchetype(newMask, componentIds)

  if world.archetypes[newArchetypeIndex].componentStorages.len == 0 and componentIds.len > 0:
    let oldArchetype = world.archetypes[currentArchetypeIndex].addr
    for compId in componentIds:
      for i, oldCompId in oldArchetype.componentIds:
        if oldCompId == compId:
          world.archetypes[newArchetypeIndex].componentStorages.add(ComponentStorage(
            data: nil,
            componentSize: oldArchetype.componentStorages[i].componentSize,
            count: 0,
            capacity: 0
          ))
          break

  type DummyComponent = object
  moveEntityToArchetype(world, entityId, newArchetypeIndex, DummyComponent())

proc addTag*(world: var World, entity: uint64, tagType: typedesc) =
  ## Adds a tag to an entity. This is a very fast, constant-time operation.
  let entityId = getEntityId(entity)
  let tagId = world.getTagID(tagType)
  world.entities[entityId].tagBitmask = world.entities[entityId].tagBitmask or (1'u64 shl tagId)

proc removeTag*(world: var World, entity: uint64, tagType: typedesc) =
  ## Removes a tag from an entity. This is a very fast, constant-time operation.
  let entityId = getEntityId(entity)
  let tagId = world.getTagID(tagType)
  let tagMask = 1'u64 shl tagId

  if (world.entities[entityId].tagBitmask and tagMask) == 0:
    return

  world.entities[entityId].tagBitmask = world.entities[entityId].tagBitmask xor tagMask

proc freeEntity*(world: var World, entity: uint64) =
  ## Removes an entity and all its components from the world.
  ## The entity's ID is added to a free list for later reuse.
  let entityId = getEntityId(entity)
  removeEntityFromArchetype(world, entityId)
  world.entities[entityId].archetypeIndex = -1
  world.entities[entityId].indexInArchetype = -1
  world.entities[entityId].tagBitmask = 0
  world.freeEntities.add(entityId)

proc hasComponent*(world: var World, entity: uint64, componentType: typedesc): bool =
  ## Checks if an entity has a specific component.
  let entityId = getEntityId(entity)
  let componentId = world.getComponentID(componentType)
  let archetypeIndex = world.entities[entityId].archetypeIndex
  if archetypeIndex < 0:
    return false
  let componentMask = 1'u64 shl componentId
  return (world.archetypes[archetypeIndex].componentMask and componentMask) != 0

proc hasTag*(world: var World, entity: uint64, tagType: typedesc): bool =
  ## Checks if an entity has a specific tag.
  let entityId = getEntityId(entity)
  let tagId = world.getTagID(tagType)
  if entityId >= world.entities.len.uint32:
    return false
  let tagMask = 1'u64 shl tagId
  return (world.entities[entityId].tagBitmask and tagMask) != 0

#------------------------------------------------------------------------------
# Iterators for Queries
#------------------------------------------------------------------------------

iterator withComponent*(world: var World, componentType: typedesc): uint64 =
  ## Iterates over all entities that have the specified component
  let componentMask = 1'u64 shl world.getComponentID(componentType)

  for archetype in world.archetypes:
    if (archetype.componentMask and componentMask) == componentMask:
      for entityId in archetype.entities:
        if world.entities[entityId].version > 0:
          yield entityId.uint64 shl 32 + world.entities[entityId].version.uint64

iterator withTag*(world: var World, tagType: typedesc): uint64 =
  ## Iterates over all entities that have the specified tag.
  let tagMask = 1'u64 shl world.getTagID(tagType)

  for i in 0..world.currentEntityId:
    if world.entities[i].version > 0 and (world.entities[i].tagBitmask and tagMask) == tagMask:
      yield i.uint64 shl 32 + world.entities[i].version.uint64

iterator withComponents*(world: var World, T1: typedesc, T2: typedesc): uint64 =
  ## Iterates over all entities that have both of the specified components.
  let mask1 = 1'u64 shl world.getComponentID(T1)
  let mask2 = 1'u64 shl world.getComponentID(T2)
  let combinedMask = mask1 or mask2

  for archetype in world.archetypes:
    if (archetype.componentMask and combinedMask) == combinedMask:
      for entityId in archetype.entities:
        if world.entities[entityId].version > 0:
          yield entityId.uint64 shl 32 + world.entities[entityId].version.uint64

iterator withComponentTag*(world: var World, Comp: typedesc, Tag: typedesc): uint64 =
  ## Iterates over all entities that have the specified component AND tag.
  let compMask = 1'u64 shl world.getComponentID(Comp)
  let tagMask = 1'u64 shl world.getTagID(Tag)

  for archetype in world.archetypes:
    if (archetype.componentMask and compMask) == compMask:
      for entityId in archetype.entities:
        if world.entities[entityId].version > 0 and (world.entities[entityId].tagBitmask and tagMask) == tagMask:
          yield entityId.uint64 shl 32 + world.entities[entityId].version.uint64

# Seq versions for compatibility with tests
proc withComponentSeq*(world: var World, componentType: typedesc): seq[uint64] =
  for entity in world.withComponent(componentType):
    result.add entity

proc withComponentSeq*(entities: seq[uint64], world: var World, componentType: typedesc): seq[uint64] =
  for entity in entities:
    if world.hasComponent(entity, componentType):
      result.add entity

proc withTagSeq*(world: var World, tagType: typedesc): seq[uint64] =
  for entity in world.withTag(tagType):
    result.add entity

proc withTagSeq*(entities: seq[uint64], world: var World, tagType: typedesc): seq[uint64] =
  for entity in entities:
    if world.hasTag(entity, tagType):
      result.add entity

# (Internal) Helper iterators for the `system` macro.
iterator withComponents3*(world: var World, T1: typedesc, T2: typedesc, T3: typedesc): uint64 =
  let mask1 = 1'u64 shl world.getComponentID(T1)
  let mask2 = 1'u64 shl world.getComponentID(T2)
  let mask3 = 1'u64 shl world.getComponentID(T3)
  let combinedMask = mask1 or mask2 or mask3

  for archetype in world.archetypes:
    if (archetype.componentMask and combinedMask) == combinedMask:
      for entityId in archetype.entities:
        if world.entities[entityId].version > 0:
          yield entityId.uint64 shl 32 + world.entities[entityId].version.uint64

iterator withComponents4*(world: var World, T1: typedesc, T2: typedesc, T3: typedesc, T4: typedesc): uint64 =
  let mask1 = 1'u64 shl world.getComponentID(T1)
  let mask2 = 1'u64 shl world.getComponentID(T2)
  let mask3 = 1'u64 shl world.getComponentID(T3)
  let mask4 = 1'u64 shl world.getComponentID(T4)
  let combinedMask = mask1 or mask2 or mask3 or mask4

  for archetype in world.archetypes:
    if (archetype.componentMask and combinedMask) == combinedMask:
      for entityId in archetype.entities:
        if world.entities[entityId].version > 0:
          yield entityId.uint64 shl 32 + world.entities[entityId].version.uint64

#------------------------------------------------------------------------------
# Macros for High-Level API
#------------------------------------------------------------------------------

macro system*(procDef: untyped): untyped =
  ## Макрос для создания системы с чистым синтаксисом.
  ##
  ## Пример использования:
  ## proc movementSystem(world: var World, pos: Position, vel: Velocity) {.system.} =
  ##   pos.x += vel.dx
  ##   pos.y += vel.dy

  expectKind(procDef, nnkProcDef)

  let procName = procDef[0]
  let params = procDef[3]  # FormalParams
  let body = procDef[6]    # Body

  # Извлекаем параметры
  var worldName: NimNode
  var componentNames: seq[NimNode] = @[]
  var componentTypes: seq[NimNode] = @[]

  # Пропускаем первый элемент (возвращаемый тип)
  for i in 1..<params.len:
    let param = params[i]
    expectKind(param, nnkIdentDefs)

    let paramName = param[0]
    let paramType = param[1]

    if i == 1:
      # Первый параметр - world
      if paramType.kind == nnkVarTy and paramType[0].repr == "World":
        worldName = paramName
      else:
        error("First parameter must be 'world: var World'", param)
    else:
      # Остальные - компоненты
      componentNames.add(paramName)
      componentTypes.add(paramType)

  if componentTypes.len == 0:
    error("System must query at least one component", procDef)

  # Определяем, какой итератор использовать
  var iteratorCall: NimNode
  case componentTypes.len
  of 1:
    iteratorCall = newCall(newDotExpr(worldName, ident"withComponent"), componentTypes[0])
  of 2:
    iteratorCall = newCall(newDotExpr(worldName, ident"withComponents"), componentTypes[0], componentTypes[1])
  of 3:
    iteratorCall = newCall(newDotExpr(worldName, ident"withComponents3"), componentTypes[0], componentTypes[1], componentTypes[2])
  of 4:
    iteratorCall = newCall(newDotExpr(worldName, ident"withComponents4"), componentTypes[0], componentTypes[1], componentTypes[2], componentTypes[3])
  else:
    error("System supports maximum 4 components", procDef)

  # Создаем тело цикла
  var loopBody = newStmtList()

  # Добавляем получение компонентов
  for i, compName in componentNames:
    let getCompCall = newCall(
      newDotExpr(worldName, ident"getComponent"),
      ident"entity",
      componentTypes[i]
    )
    loopBody.add(newVarStmt(compName, getCompCall))

  # Добавляем пользовательское тело
  loopBody.add(body)

  # Создаем цикл for
  let forLoop = nnkForStmt.newTree(
    ident"entity",
    iteratorCall,
    loopBody
  )

  # Создаем процедуру
  result = newProc(
    procName,
    [newEmptyNode(), newIdentDefs(worldName, nnkVarTy.newTree(ident"World"))],
    forLoop
  )

macro prefab*(name: string, body: untyped): untyped =
  ## Defines a prefab (entity template) with a set of default components.
  ## This macro generates a `register_prefab_...` procedure that must be called
  ## to make the prefab available to the world.
  ##
  ## Usage:
  ## ```nim
  ## prefab "player":
  ##   Position(x: 100, y: 100)
  ##   Velocity(dx: 0, dy: 0)
  ##
  ## register_prefab_player(world)
  ## ```

  var initializers = newNimNode(nnkStmtList)
  var registerCalls = newNimNode(nnkStmtList)

  for node in body:
    if node.kind != nnkCall:
      error("Prefab body must contain component initializers", node)
    let compType = node[0]
    let compValue = node

    let initializerProc = genSym(nskProc, "initializer")
    let procDef = quote do:
      let `initializerProc` = proc(world: var World, entity: uint64, overridesPtr: pointer) =
        let overrides = cast[ptr Table[string, pointer]](overridesPtr)[]
        let typeName = $`compType`
        if typeName in overrides:
          let overrideValue = cast[ptr `compType`](overrides[typeName])[]
          discard world.addComponent(entity, overrideValue)
        else:
          discard world.addComponent(entity, `compValue`)

    initializers.add(procDef)
    registerCalls.add(quote do:
      prefab.initializers.add(`initializerProc`)
    )

  let registerProcName = newIdentNode("register_prefab_" & name.strVal.replace('-', '_'))
  result = quote do:
    proc `registerProcName`*(world: var World) =
      var prefab = Prefab(name: `name`)
      `initializers`
      `registerCalls`
      world.prefabs[`name`] = prefab

macro spawn*(world: untyped, name: string, overrides: varargs[untyped]): untyped =
  ## Spawns an entity from a registered prefab, with optional component overrides.
  ##
  ## Usage:
  ## ```nim
  ## let player = world.spawn("player")
  ## let enemy = world.spawn("enemy", Position(x: 500, y: 200))
  ## ```
  var initBlock = newStmtList()
  let tableVar = genSym(nskVar, "overrideTable")

  initBlock.add(quote do:
    var `tableVar` = initTable[string, pointer]()
  )

  for item in overrides:
    let typeNameStr = $item[0]
    let tempVar = genSym(nskLet, "overrideValue")

    initBlock.add(quote do:
      let `tempVar` = `item`
      `tableVar`[`typeNameStr`] = `tempVar`.addr
    )

  result = quote do:
    block:
      `initBlock`
      spawnFromPrefab(`world`, `name`, `tableVar`)

proc spawnFromPrefab(world: var World, name: string, overrides: Table[string, pointer]): uint64 =
  # (Internal) The core implementation logic for the `spawn` macro.
  if name notin world.prefabs:
    raise newException(ValueError, "Prefab not found: " & name)

  let entity = world.addEntity()

  let prefab = world.prefabs[name]
  for initializer in prefab.initializers:
    # Передаем указатель на таблицу, а не саму таблицу
    initializer(world, entity, overrides.addr)

  return entity

#------------------------------------------------------------------------------
# Event System
#------------------------------------------------------------------------------

proc registerListener*[T](world: var World, listener: proc(w: var World, e: ptr T) {.closure.}) =
  ## Registers an event listener for a specific event type `T`.
  ## The listener procedure will be called when the event queue is dispatched.
  ## Handles closures safely.
  let typeName = $T
  if not world.eventListeners.hasKey(typeName):
    world.eventListeners[typeName] = @[]

  let wrapper = proc(w: var World, data: pointer) {.closure.} =
    let specificEvent = cast[ptr T](data)

    listener(w, specificEvent)

  world.eventListeners[typeName].add(wrapper)

proc sendEvent*[T](world: var World, event: T) =
  ## Queues an event to be processed at the end of the current frame.
  ## This is a fast operation that copies the event data into a queue.
  let typeName = $T
  if typeName notin world.eventQueues:
    world.eventQueues[typeName] = @[]

  let dataPtr = cast[ptr T](allocShared(sizeof(T)))
  dataPtr[] = event # Копируем данные события
  world.eventQueues[typeName].add(dataPtr)

proc dispatchEventQueue*(world: var World) =
  ## Processes all queued events, calling their registered listeners.
  ## This should be called once per frame, typically after all systems have run.
  for typeName, queue in world.eventQueues.mpairs:
    if queue.len == 0: continue

    if typeName in world.eventListeners:
      let listeners = world.eventListeners[typeName]
      if listeners.len > 0:
        for eventPtr in queue:
          for listener in listeners:
            listener(world, eventPtr)

    for eventPtr in queue:
      deallocShared(eventPtr)
    queue.setLen(0)

when isMainModule:
  type
    PositionComponent = object
      x, y: float
    VelocityComponent = object
      dx, dy: float
    RenderableComponent = object
      sprite: string
      color: int
    HealthComponent = object
      current, max: int
    HomingMissileTag = object

  # --- 1. Определяем префабы ---
  prefab "player":
    PositionComponent(x: 100, y: 100)
    VelocityComponent(dx: 0, dy: 0)
    HealthComponent(current: 100, max: 100)
    RenderableComponent(sprite: "player.png", color: 0xFFFFFF)

  prefab "homing_missile":
    PositionComponent(x: 0, y: 0)
    VelocityComponent(dx: 200, dy: 0)
    RenderableComponent(sprite: "missile.png", color: 0xFF0000)
    HomingMissileTag() # Просто вызов конструктора для тега

  # --- 2. Регистрируем префабы при запуске ---
  var world = initWorld()
  register_prefab_player(world)
  register_prefab_homing_missile(world)

  # --- 3. Спавним сущности ---
  echo "Spawning player with default values:"
  let player1 = world.spawn("player")
  var p1pos = world.getComponent(player1, PositionComponent)
  echo "Player 1 position: ", p1pos.x, ", ", p1pos.y

  echo "\nSpawning another player at a specific location:"
  let player2 = world.spawn("player", PositionComponent(x: 500, y: 300))
  var p2pos = world.getComponent(player2, PositionComponent)
  echo "Player 2 position: ", p2pos.x, ", ", p2pos.y
  var p2health = world.getComponent(player2, HealthComponent)
  echo "Player 2 health (default): ", p2health.current

  echo "\nSpawning a missile with overridden velocity and position:"
  let missile1 = world.spawn("homing_missile",
    PositionComponent(x: p1pos.x, y: p1pos.y),
    VelocityComponent(dx: 0, dy: -300)
  )
  var m1pos = world.getComponent(missile1, PositionComponent)
  var m1vel = world.getComponent(missile1, VelocityComponent)
  echo "Missile position: ", m1pos.x, ", ", m1pos.y
  echo "Missile velocity: ", m1vel.dx, ", ", m1vel.dy
  echo "Missile has HomingMissileTag: ", world.hasTag(missile1, HomingMissileTag)