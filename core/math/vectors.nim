import macros, strutils, typetraits, tables

#var types {.compileTime.} = newTable[NimNode, NimSym]()

type
  Wide*[T] = object
    elements*: array[4, T]

  SuperScalar* = concept v, type V
    type T = V.scalarType
    const width: int = V.laneCount
    v.getLane(int) is T
    v.setLane(int, T)

template scalarType*[T](t: typedesc[Wide[T]]): typedesc = T
template laneCount*[T](t: typedesc[Wide[T]]): int = 4
func getLane*(wide: Wide; laneIndex: int): Wide.T {.inline.} = wide.elements[laneIndex]
func setLane*(wide: var Wide; laneIndex: int; value: Wide.T) {.inline.} = wide.elements[laneIndex] = value

func gather*(wide: var SuperScalar; args: varargs[SuperScalar.T]) =
  for laneIndex, value in pairs(args):
    wide.setLane(laneIndex, value)

func scatter*(wide: SuperScalar; args: var openarray[SuperScalar.T]) =
  # var varargs is not supported
  for laneIndex, value in mpairs(args):
    value = wide.getLane(laneIndex)

# iterator lanes*(wide: SuperScalar): SuperScalar.T =
#   for laneIndex in SuperScalar.width:
#     yield getLane(laneIndex)

type VectorizedType = tuple[scalar, wide: NimNode]
var vectorizedTypes {.compileTime.} = newSeq[VectorizedType]()

proc makeWideTypeRecursive(T: NimNode; generatedTypes: var seq[NimNode]): NimNode {.compileTime.} =
  
  case T.typeKind:
    of ntyTypeDesc:
      return makeWideTypeRecursive(T.getTypeInst[1], generatedTypes)
      
    of ntyArray:
      # Array types are a bracket expression of 'array', a range, and the element type
      var wideType = T.getTypeInst.copyNimTree()     
      var elementType = wideType[2]
      wideType[2] = makeWideTypeRecursive(elementType, generatedTypes)
      return wideType

    of ntyObject:
      case T.kind:
        of nnkSym:
          for vectorizedType in vectorizedTypes:
            if T.sameType(vectorizedType.scalar):
            #if T == vectorizedType.scalar:
              return vectorizedType.wide

          let scalarTypeDefinition = T.symbol.getImpl()

          var recList = nnkRecList.newNimNode()
          recList.add(newEmptyNode())
          recList.add(newEmptyNode())

          for fieldDefs in scalarTypeDefinition[2][2]:
            fieldDefs.expectKind(nnkIdentDefs)
            fieldDefs.expectMinLen(2)

            # Copy over all identifiers, including visibility and pragmas
            var newFieldDefs = nnkIdentDefs.newNimNode()
            for i in 0 ..< fieldDefs.len - 2:
              let fieldDef = fieldDefs[i]
              fieldDef.expectKind({nnkIdent, nnkPragmaExpr, nnkPostfix})
              newFieldDefs.add(fieldDef.copyNimTree())

            # Vectorize the field type
            let fieldType = fieldDefs[^2]
            let newFieldType = makeWideTypeRecursive(fieldType, generatedTypes)
            newFieldDefs.add(newFieldType)

            newFieldDefs.add(newEmptyNode())

            # Add to the record
            recList.add(newFieldDefs)

          # Create a new symbol for the type
          var symbol = genSym(nskType)

          var wideTypeDefinition = nnkTypeDef.newTree(
            symbol,
            newEmptyNode(),
            nnkObjectTy.newTree(
              newEmptyNode(),
              newEmptyNode(),
              recList
            )
          )
          generatedTypes.add(wideTypeDefinition)
          
          vectorizedTypes.add((T, symbol))
          return symbol

        else: discard
   
    else:
      let name = ident($T)
      return quote do:
        Wide[`name`]
        #Wide[`T`]
        #array[4, `T`]

proc makeWideTypeImpl(T: NimNode): NimNode {.compileTime.} =
  var generatedTypes = newSeq[NimNode]()
  let rootType = makeWideTypeRecursive(T, generatedTypes)

  return newStmtList(
    nnkTypeSection.newTree(
      generatedTypes
    ),
    rootType
  )

# macro makeWideType(T: typed): untyped =
#   result = makeWideTypeImpl2(T)
#   #echo astGenRepr(result)
  
macro wide*(T: typedesc): untyped =
  T.getType().makeWideTypeImpl()

static:
  var f1, f2, f3: float
  var fa: array[Wide[float].laneCount, float]
  f1 = 1.0
  var w: Wide[float]
  w.gather(f3, f2, f1)
  w.scatter(fa)
  echo fa[2]
  #for x in w.lanes: discard

  type
    Bar = object
      value*: uint64

    Foo {.importc.} = object
      value*, value2: int
      fValue* : float
      #tValue*: Time
      #sValue*: string
      rValue*: Bar

  echo (wide float).name
  echo (wide array[4, float]).name
  type WideBar = wide Bar
  type WideFoo = wide Foo
  echo type(WideFoo.fvalue).name

  var x: WideFoo
  var y: WideBar
  x.rValue = y
