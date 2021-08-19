import strutils, macros, sequtils, parseutils, os
import nwtTokenizer
import tables

type Path = string
type
  NwtNodeKind = enum
    NStr, NIf, NElif, NElse, NWhile, NFor,
    NVariable, NEval, NImport, NBlock, NExtends
  NwtNode = object
    case kind: NwtNodeKind
    of NStr:
      strBody: string
    of NIf:
      ifStmt: string
      nnThen: seq[NwtNode]
      nnElif: seq[NwtNode]
      nnElse: seq[NwtNode]
    of NElif:
      elifStmt: string
      elifBody: seq[NwtNode]
    of NWhile:
      whileStmt: string
      whileBody: seq[NwtNode]
    of NFor:
      forStmt: string
      forBody: seq[NwtNode]
    of NVariable:
      variableBody: string
    of NEval:
      evalBody: string
    of NImport:
      importBody: string
    of NBlock:
      blockName: string
      blockBody: seq[NwtNode]
    of NExtends:
      extendsPath: string
    else: discard

type IfState {.pure.} = enum
  InThen, InElif, InElse

# First step nodes
type
  FsNodeKind = enum
    FsIf, FsStr, FsEval, FsElse, FsElif, FsEndif, FsFor,
    FsEndfor, FsVariable, FsWhile, FsEndWhile, FsImport, FsBlock, FsEndBlock, FsExtends
  FSNode = object
    kind: FsNodeKind
    value: string

var cacheNwtNode {.compileTime.}: Table[string, seq[NwtNode]] ## a cache for rendered NwtNodes
var cacheNwtNodeFile {.compileTime.}: Table[Path, string] ## a cache for content of a path
var nwtIter {.compileTime.} = false

when defined(dumpNwtAstPretty):
  import json
  proc pretty*(nwtNodes: seq[NwtNode]): string {.compileTime.} =
    (%* nwtNodes).pretty()

template getScriptDir*(): string =
  ## Helper for staticRead.
  ##
  ## returns the absolute path to your project, on compile time.
  getProjectPath()

# Forward decleration
proc parseSecondStep(fsTokens: seq[FSNode], pos: var int): seq[NwtNode]
proc parseSecondStepOne(fsTokens: seq[FSNode], pos: var int): seq[NwtNode]
proc astAst(tokens: seq[NwtNode]): seq[NimNode]


func splitStmt(str: string): tuple[pref: string, suf: string] {.inline.} =
  ## the prefix is normalized (transformed to lowercase)
  var pref = ""
  var pos = parseIdent(str, pref, 0)
  pos += str.skipWhitespace(pos)
  result.pref = toLowerAscii(pref)
  result.suf = str[pos..^1]

proc parseFirstStep(tokens: seq[Token]): seq[FSNode] =
  result = @[]
  for token in tokens:
    case token.tokenType
    of NwtEval:
      let (pref, suf) = splitStmt(token.value)
      case pref
      of "if": result.add FSNode(kind: FsIf, value: suf)
      of "elif": result.add FSNode(kind: FsElif, value: suf)
      of "else": result.add FSNode(kind: FsElse, value: suf)
      of "endif": result.add FSNode(kind: FsEndif, value: suf)
      of "for": result.add FSNode(kind: FsFor, value: suf)
      of "endfor": result.add FSNode(kind: FsEndfor, value: suf)
      of "while": result.add FSNode(kind: FsWhile, value: suf)
      of "endwhile": result.add FSNode(kind: FsEndWhile, value: suf)
      of "importnwt": result.add FSNode(kind: FsImport, value: suf)
      of "block": result.add FSNode(kind: FsBlock, value: suf)
      of "endblock": result.add FSNode(kind: FsEndBlock, value: suf)
      of "extends": result.add FSNode(kind: FsExtends, value: suf)
      else:
        result.add FSNode(kind: FsEval, value: token.value)
    of NwtString: result.add FSNode(kind: FsStr, value: token.value)
    of NwtVariable: result.add FSNode(kind: FsVariable, value: token.value)
    of NwtComment: discard # ignore comments
    else: echo "[FS] Not catched:", token


proc parseSsIf(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos] # first is the if that we got called about
  result = NwtNode(kind: NwtNodeKind.NIf)
  result.ifStmt = elem.value
  pos.inc # skip the if
  var ifstate = IfState.InThen
  while pos < fsTokens.len:
    elem = fsTokens[pos]
    case elem.kind
    of FsIf:
      case ifState
      of IfState.InThen:
        result.nnThen.add parseSecondStep(fsTokens, pos)
      of IfState.InElse:
        result.nnElse.add parseSecondStep(fsTokens, pos)
      of IfState.InElif:
        result.nnElif[^1].elifBody.add parseSecondStep(fsTokens, pos)
    of FsElif:
      ifstate = IfState.InElif
      result.nnElif.add NwtNode(kind: NElif, elifStmt: elem.value)
    of FsElse:
      ifstate = IfState.InElse
    of FsEndif:
      break
    else:
      case ifState
      of IfState.InThen:
        result.nnThen &= parseSecondStepOne(fsTokens, pos)
      of IfState.InElse:
        result.nnElse &= parseSecondStepOne(fsTokens, pos)
      of IfState.InElif:
        result.nnElif[^1].elifBody &= parseSecondStepOne(fsTokens, pos)
    pos.inc


proc parseSsWhile(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos] # first is the while that we got called about
  result = NwtNode(kind: NwtNodeKind.NWhile)
  result.whileStmt = elem.value
  while pos < fsTokens.len:
    pos.inc # skip the while
    elem = fsTokens[pos]
    if elem.kind == FsEndWhile:
      break
    else:
      result.whileBody &= parseSecondStepOne(fsTokens, pos)

proc parseSsFor(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos] # first is the for that we got called about
  result = NwtNode(kind: NwtNodeKind.NFor)
  result.forStmt = elem.value
  while pos < fsTokens.len:
    pos.inc # skip the for
    elem = fsTokens[pos]
    if elem.kind == FsEndFor:
      break
    else:
      result.forBody &= parseSecondStepOne(fsTokens, pos)

proc parseSsBlock(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos]
  let blockName = elem.value
  result = NwtNode(kind: NwtNodeKind.NBlock, blockName: blockName)
  while pos < fsTokens.len:
    pos.inc # skip the block
    elem = fsTokens[pos]
    if elem.kind == FsEndBlock:
      break
    else:
      result.blockBody &= parseSecondStepOne(fsTokens, pos)

proc parseSsExtends(fsTokens: seq[FsNode], pos: var int): NwtNode =
  var elem: FsNode = fsTokens[pos]
  let extendsPath = elem.value.strip(true, true, {'"'})
  return NwtNode(kind: NExtends, extendsPath: extendsPath)

converter singleNwtNodeToSeq(nwtNode: NwtNode): seq[NwtNode] =
  return @[nwtNode]

proc includeNwt(nodes: var seq[NwtNode], path: string) {.compileTime.} =
  const basePath = getProjectPath()
  var str = staticRead( basePath  / path.strip(true, true, {'"'}) )
  var lexerTokens = toSeq(nwtTokenize(str))
  var firstStepTokens = parseFirstStep(lexerTokens)
  var pos = 0
  var secondsStepTokens = parseSecondStep(firstStepTokens, pos)
  for secondStepToken in secondsStepTokens:
    nodes.add secondStepToken

proc parseSecondStepOne(fsTokens: seq[FSNode], pos: var int): seq[NwtNode] =
    let fsToken = fsTokens[pos]

    case fsToken.kind
    # Complex Types
    of FSif: return parseSsIf(fsTokens, pos)
    of FsWhile: return parseSsWhile(fsTokens, pos)
    of FsFor: return parseSsFor(fsTokens, pos)
    of FsBlock: return parseSsBlock(fsTokens, pos)

    # Simple Types
    of FsStr: return NwtNode(kind: NStr, strBody: fsToken.value)
    of FsVariable: return NwtNode(kind: NVariable, variableBody: fsToken.value)
    of FsEval: return NwtNode(kind: NEval, evalBody: fsToken.value)
    of FsExtends: return parseSsExtends(fsTokens, pos)
    of FsImport: includeNwt(result, fsToken.value)
    else: echo "[SS] NOT IMPL: ", fsToken

proc parseSecondStep(fsTokens: seq[FSNode], pos: var int): seq[NwtNode] =
  while pos < fsTokens.len:
    result &= parseSecondStepOne(fsTokens, pos)
    pos.inc # skip the current elem

func astVariable(token: NwtNode): NimNode =
  return nnkStmtList.newTree(
    nnkInfix.newTree(
      newIdentNode("&="),
      newIdentNode("result"),
      newCall(
        "$",
        parseStmt(token.variableBody)
      )
    )
  )

func astStr(token: NwtNode): NimNode =
  return nnkStmtList.newTree(
    nnkInfix.newTree(
      newIdentNode("&="),
      newIdentNode("result"),
      newStrLitNode(token.strBody)
    )
  )

func astVariableIter(token: NwtNode): NimNode =
  return nnkStmtList.newTree(
    nnkYieldStmt.newTree(
      newCall(
        "$",
        parseStmt(token.variableBody)
      )
    )
  )

func astStrIter(token: NwtNode): NimNode =
  return nnkStmtList.newTree(
    nnkYieldStmt.newTree(
      newStrLitNode(token.strBody)
    )
  )


func astEval(token: NwtNode): NimNode =
  return parseStmt(token.evalBody)

proc astFor(token: NwtNode): NimNode =
  let easyFor = "for " & token.forStmt & ": discard" # `discard` to make a parsable construct
  result = parseStmt(easyFor)
  result[0][2] = newStmtList(astAst(token.forBody)) # overwrite discard with real `for` body

proc astWhile(token: NwtNode): NimNode =
  nnkStmtList.newTree(
    nnkWhileStmt.newTree(
      parseStmt(token.whileStmt),
      nnkStmtList.newTree(
        astAst(token.whileBody)
      )
    )
  )


proc astIf(token: NwtNode): NimNode =
  result = nnkIfStmt.newTree()

  # Add the then node
  result.add:
    nnkElifBranch.newTree(
      parseStmt(token.ifStmt),
      nnkStmtList.newTree(
        astAst(token.nnThen)
      )
    )

  ## Add the elif nodes
  for elifToken in token.nnElif:
    result.add:
      nnkElifBranch.newTree(
        parseStmt(elifToken.elifStmt),
        nnkStmtList.newTree(
          astAst(elifToken.elifBody)
        )
      )

  # Add the else node
  if token.nnElse.len > 0:
    result.add:
      nnkElse.newTree(
        nnkStmtList.newTree(
          astAst(token.nnElse)
        )
      )


proc astAstOne(token: NwtNode): NimNode =
  case token.kind
  of NVariable:
    if nwtIter: return astVariableIter(token)
    else: return astVariable(token)
  of NStr:
    if nwtIter: return astStrIter(token)
    else: return astStr(token)
  of NEval: return astEval(token)
  of NIf: return astIf(token)
  of NFor: return astFor(token)
  of NWhile: return astWhile(token)
  of NExtends: return parseStmt("discard")
  of NBlock: return parseStmt("discard")
  else: raise newException(ValueError, "cannot convert to ast:" & $token.kind)

proc astAst(tokens: seq[NwtNode]): seq[NimNode] =
  for token in tokens:
    result.add astAstOne(token)

proc validExtend(secondsStepTokens: seq[NwtNode]): int =
  ## Scans if invalid tokens come before extend.
  ## If no extend was found `-1` is returned, else the position.
  ## Only Strings and comments are allowed to come before extend
  result = -1
  var validBeforeExtend = true
  for idx, secondStepToken in secondsStepTokens.pairs:
    case secondStepToken.kind
    of NStr: discard
    of NExtends:
      result = idx
      break
    else:
      validBeforeExtend = false

  if (result > -1) and (not validBeforeExtend):
    raise newException(ValueError,
      "Invalid token(s) before {%extend%}: " & $ secondsStepTokens[0 .. result]
    )

func condenseStrings(nodes: seq[FsNode]): seq[FsNode] =
  when defined(noCondenseStrings):
    return nodes
  else:
    var curStr = ""
    for node in nodes:
      case node.kind
      of FsStr:
        curStr &= node.value
      else:
        result.add FsNode(kind: FsStr, value: curStr)
        curStr = ""
        result.add node
    if curStr.len != 0:
      result.add FsNode(kind: FsStr, value: curStr)

proc loadCache(str: string): seq[NwtNode] =
  ## For faster compilation
  ## ```-d:nwtCacheOff``` to disable caching
  ## Creates NwtNodes only the first time for a given string,
  ## the second time is returned from the cache
  when defined(nwtCacheOff):
    var lexerTokens = toSeq(nwtTokenize(str))
    var firstStepTokens = condenseStrings(parseFirstStep(lexerTokens))
    var pos = 0
    return parseSecondStep(firstStepTokens, pos)
  else:
    if cacheNwtNode.contains(str):
      # echo "cache hit str"
      return cacheNwtNode[str]
    else:
      var lexerTokens = toSeq(nwtTokenize(str))
      var firstStepTokens = condenseStrings(parseFirstStep(lexerTokens))
      var pos = 0
      cacheNwtNode[str] = parseSecondStep(firstStepTokens, pos)
      return cacheNwtNode[str]

proc loadCacheFile(path: Path): string =
  ## For faster compilation
  ## ```-d:nwtCacheOff``` to disable caching
  ## Statically reads a file, and caches it.
  ## The second time the same file should be read
  ## it is returned from the cache
  when defined(nwtCacheOff):
    return staticRead(path)
  else:
    if cacheNwtNodeFile.contains(path):
      # echo "cache hit file"
      return cacheNwtNodeFile[path]
    else:
      cacheNwtNodeFile[path] = staticRead(path)
      return cacheNwtNodeFile[path]

proc compile(str: string): seq[NwtNode] =
  ## Transforms a template string into a seq of NwtNodes
  # TODO make to ITERATOR
  var secondsStepTokens = loadCache(str)
  when defined(dumpNwtAst): echo secondsStepTokens
  let foundExtendAt = validExtend(secondsStepTokens)
  if foundExtendAt > -1:
    # echo "===== THIS TEMPLATE EXTENDS ====="
    # Load master template
    let masterStr = loadCacheFile( getScriptDir() / secondsStepTokens[foundExtendAt].extendsPath )
    var masterSecondsStepTokens = loadCache(masterStr)
    # Load THIS template (above)
    var toRender: seq[NwtNode] = @[]
    for masterSecondsStepToken in masterSecondsStepTokens:
      if masterSecondsStepToken.kind == NBlock:
        ## search the other template and put the stuff in toRender
        var found = false
        for secondsStepToken in secondsStepTokens[foundExtendAt+1 .. ^1]: # skip everything before the extend
          if secondsStepToken.kind == NExtends: raise newException(ValueError, "only one extend is allowed!")
          if secondsStepToken.kind == NBlock and secondsStepToken.blockName == masterSecondsStepToken.blockName:
            found = true
            for blockToken in secondsStepToken.blockBody:
              toRender.add blockToken
        if found == false:
          # not overwritten; render the block
          for blockToken in masterSecondsStepToken.blockBody:
            toRender.add blockToken
      else:
        toRender.add masterSecondsStepToken
    return toRender
  else:
    var toRender: seq[NwtNode] = @[]
    for token in secondsStepTokens:
      if token.kind == NBlock:
        for blockToken in token.blockBody:
          toRender.add blockToken
      else:
        toRender.add token
    return toRender # TODO make to ITERATOR


macro compileTemplateStr*(str: typed, iter: static bool = false): untyped =
  ## Compiles a nimja template from a string.
  ##
  ## .. code-block:: Nim
  ##  proc yourFunc(yourParams: bool): string =
  ##    compileTemplateString("{%if yourParams%}TRUE{%endif%}")
  ##
  ##  echo yourFunc(true)
  ##
  ## If `iter = true` then the macro can be used in an interator body
  ## this could be used for streaming templates, or to save memory when a big template
  ## is rendered and the http server can send data in chunks.
  ##
  ## .. code-block:: nim
  ##  iterator yourIter(yourParams: bool): string =
  ##    compileTemplateString("{%for idx in 0 .. 100%}{{idx}}{%endfor%}", iter = true)
  ##
  ##  for elem in yourIter(true):
  ##    echo elem
  ##
  nwtIter = iter
  let nwtNodes = compile(str.strVal)
  when defined(dumpNwtAst): echo nwtNodes
  when defined(dumpNwtAstPretty): echo nwtNodes.pretty
  result = newStmtList()
  for nwtNode in nwtNodes:
    result.add astAstOne(nwtNode)
  when defined(dumpNwtMacro): echo toStrLit(result)

macro compileTemplateFile*(path: static string, iter: static bool = false): untyped =
  ## Compiles a nimja template from a file.
  ##
  ## .. code-block:: nim
  ##  proc yourFunc(yourParams: bool): string =
  ##    compileTemplateFile(getScriptDir() / "relative/path.nwt")
  ##
  ##  echo yourFunc(true)
  ##
  ## If `iter = true` then the macro can be used in an interator body
  ## this could be used for streaming templates, or to save memory when a big template
  ## is rendered and the http server can send data in chunks.
  ##
  ## .. code-block:: nim
  ##  iterator yourIter(yourParams: bool): string =
  ##    compileTemplateFile(getScriptDir() / "relative/path.nwt", iter = true)
  ##
  ##  for elem in yourIter(true):
  ##    echo elem
  ##
  nwtIter = iter
  let str = loadCacheFile(path)
  let nwtNodes = compile(str)
  when defined(dumpNwtAst): echo nwtNodes
  when defined(dumpNwtAstPretty): echo nwtNodes.pretty
  result = newStmtList()
  for nwtNode in nwtNodes:
    result.add astAstOne(nwtNode)
  when defined(dumpNwtMacro): echo toStrLit(result)