//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftSourceKit
import SwiftSyntax
import SwiftSyntaxParser
import Common
import Foundation

let SOURCEKIT_REQUEST_TIMEOUT = 300 // seconds

class SourceKitDocument {
  let swiftc: String
  let args: CompilerArgs
  /// Extra code completion options to pass to sourcekitd for each code completion request in the `key.codecomplete.options` dictionary.
  /// `key.codecomplete.` will automatically be prepended to these options.
  /// If the value is convertible to an integer, it will be passed to sourcekitd as an integer.
  let extraCodeCompleteOptions: [String: String]
  let tempDir: URL
  let connection: SourceKitdService
  let containsErrors: Bool

  private var sourceState: SourceState? = nil
  private var tree: SourceFileSyntax? = nil
  private var converter: SourceLocationConverter? = nil

  private var tempModulePath: URL {
    tempDir.appendingPathComponent("TestModForStressTester.swiftmodule")
  }

  private var documentInfo: DocumentInfo {
    var modification: DocumentModification? = nil
    if let state = sourceState, state.wasModified {
      modification = DocumentModification(mode: state.mode, content: state.source)
    }
    return DocumentInfo(path: args.forFile.path, modification: modification)
  }

  init(swiftc: String, args: CompilerArgs,
       tempDir: URL, connection: SourceKitdService,
       extraCodeCompleteOptions: [String: String],
       containsErrors: Bool = false) {
    self.swiftc = swiftc
    self.args = args
    self.extraCodeCompleteOptions = extraCodeCompleteOptions
    self.tempDir = tempDir
    self.connection = connection
    self.containsErrors = containsErrors
  }

  func open(rewriteMode: RewriteMode) throws -> (SourceFileSyntax, SourceKitdResponse) {
    let source = try! String(contentsOf: args.forFile, encoding: .utf8)
    sourceState = SourceState(rewriteMode: rewriteMode, content: source)
    return try openOrUpdate(path: args.forFile.path)
  }

  func update(updateSource: (inout SourceState) -> Void) throws -> (SourceFileSyntax, SourceKitdResponse) {
    var sourceState = self.sourceState!
    try close()
    updateSource(&sourceState)
    self.sourceState = sourceState
    return try openOrUpdate(source: sourceState.source)
  }

  private func openOrUpdate(path: String? = nil, source: String? = nil)
  throws -> (SourceFileSyntax, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_EditorOpen)
    if let path = path {
      request.addParameter(.key_SourceFile, value: path)
    } else if let source = source {
      request.addParameter(.key_SourceText, value: source)
    }
    request.addParameter(.key_Name, value: args.forFile.path)
    request.addParameter(.key_EnableSyntaxMap, value: 0)
    request.addParameter(.key_EnableStructure, value: 0)
    request.addParameter(.key_SyntacticOnly, value: 1)
    request.addCompilerArgs(args.sourcekitdArgs)

    let info = RequestInfo.editorOpen(document: documentInfo)
    let response = try sendWithTimeout(request, info: info)

    try updateSyntaxTree(request: info)

    return (tree!, response)
  }

  @discardableResult
  func close() throws -> SourceKitdResponse {
    sourceState = nil

    let request = SourceKitdRequest(uid: .request_EditorClose)
    request.addParameter(.key_SourceFile, value: args.forFile.path)
    request.addParameter(.key_Name, value: args.forFile.path)

    let info = RequestInfo.editorClose(document: documentInfo)
    let response = try sendWithTimeout(request, info: info)
    return response
  }

  func rangeInfo(offset: Int, length: Int) throws -> (RequestInfo, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_RangeInfo)

    request.addParameter(.key_SourceFile, value: args.forFile.path)
    request.addParameter(.key_Offset, value: offset)
    request.addParameter(.key_Length, value: length)
    request.addParameter(.key_RetrieveRefactorActions, value: 1)
    request.addCompilerArgs(args.sourcekitdArgs)

    let info = RequestInfo.rangeInfo(document: documentInfo, offset: offset,
                                     length: length, args: args.sourcekitdArgs)
    let response = try sendWithTimeout(request, info: info)

    if let actions = response.value.getOptional(.key_RefactorActions)?.getArray() {
      for i in 0 ..< actions.count {
        let action = actions.getDictionary(i)
        guard action.getOptional(.key_ActionUnavailableReason) == nil else { continue }
        let actionName = action.getString(.key_ActionName)
        let kind = action.getUID(.key_ActionUID)
        _ = try semanticRefactoring(actionKind: kind, actionName: actionName,
                                    offset: offset)
      }
    }

    return (info, response)
  }

  func cursorInfo(offset: Int) throws -> (RequestInfo, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_CursorInfo)

    request.addParameter(.key_SourceFile, value: args.forFile.path)
    request.addParameter(.key_Offset, value: offset)
    request.addParameter(.key_RetrieveRefactorActions, value: 1)
    request.addParameter(.key_RetrieveSymbolGraph, value: 1)
    request.addCompilerArgs(args.sourcekitdArgs)

    let info = RequestInfo.cursorInfo(document: documentInfo, offset: offset,
                                      args: args.sourcekitdArgs)
    let response = try sendWithTimeout(request, info: info) { response in
      if !containsErrors {
        if let typeName = response.value.getOptional(.key_TypeName)?.getString(), typeName.contains("<<error type>>") {
          throw SourceKitError.failed(.errorTypeInResponse, request: info, response: response.value.description)
        }
      }
    }

    let symbolName = response.value.getOptional(.key_Name)?.getString()
    if let actions = response.value.getOptional(.key_RefactorActions)?.getArray() {
      for i in 0 ..< actions.count {
        let action = actions.getDictionary(i)
        guard action.getOptional(.key_ActionUnavailableReason) == nil else { continue }
        let actionName = action.getString(.key_ActionName)
        guard actionName != "Global Rename" else { continue }
        let kind = action.getUID(.key_ActionUID)
        _ = try semanticRefactoring(actionKind: kind, actionName: actionName,
                                    offset: offset, newName: symbolName)
      }
    }

    return (info, response)
  }

  func format(offset: Int) throws -> (RequestInfo, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_EditorFormatText)
    guard let converter = self.converter else { fatalError("didn't call open?") }

    request.addParameter(.key_SourceFile, value: args.forFile.path)
    request.addParameter(.key_Name, value: args.forFile.path)
    request.addParameter(.key_SourceText, value: "")

    let options = request.addDictionaryParameter(.key_FormatOptions)
    options.add(.key_IndentSwitchCase, value: 0)
    options.add(.key_IndentWidth, value: 2)
    options.add(.key_TabWidth, value: 2)
    options.add(.key_UseTabs, value: 0)

    let location = converter.location(for: AbsolutePosition(utf8Offset: offset))
    request.addParameter(.key_Line, value: location.line!)
    request.addParameter(.key_Length, value: 1)

    let info = RequestInfo.format(document: documentInfo, offset: offset)
    let response = try sendWithTimeout(request, info: info)

    return (info, response)
  }

  func semanticRefactoring(actionKind: SourceKitdUID, actionName: String,
                           offset: Int, newName: String? = nil) throws -> (RequestInfo, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_SemanticRefactoring)
    guard let converter = self.converter else { fatalError("didn't call open?") }

    request.addParameter(.key_ActionUID, value: actionKind)
    request.addParameter(.key_SourceFile, value: args.forFile.path)
    let location = converter.location(for: AbsolutePosition(utf8Offset: offset))
    request.addParameter(.key_Line, value: location.line!)
    request.addParameter(.key_Column, value: location.column!)
    if let newName = newName, actionName == "Local Rename" {
      request.addParameter(.key_Name, value: newName)
    }
    request.addCompilerArgs(args.sourcekitdArgs)

    let info = RequestInfo.semanticRefactoring(document: documentInfo,
                                               offset: offset,
                                               kind: actionName,
                                               args: args.sourcekitdArgs)
    let response = try sendWithTimeout(request, info: info)

    return (info, response)
  }

  /// Retrieves the number of instructions the SourceKit process has executed
  /// since it was launched. Returns 0 if the number of executed instructions
  /// could not be determined.
  private func getSourceKitInstructionCount() throws -> Int {
    let request = SourceKitdRequest(uid: .request_Statistics)
    let response = try sendWithTimeout(request, info: .statistics)
    let results = response.value.getArray(.key_Results)
    for i in 0..<results.count {
      let stat = results.getDictionary(i)
      if stat.getUID(.key_Kind) == .kind_StatInstructionCount {
        return stat.getInt(.key_Value)
      }
    }
    return 0
  }

  /// Build the codecomplete.open or codecomplete.close request.
  /// The two requests share the exact same options except for the request name.
  private func buildCompletionRequest(request: SourceKitdUID, offset: Int, extraOptions: [String: String]) -> SourceKitdRequest {
    let location = converter!.location(for: AbsolutePosition(utf8Offset: offset))

    let request = SourceKitdRequest(uid: request)
    request.addParameter(.key_SourceFile, value: args.forFile.path)
    request.addParameter(.key_Name, value: args.forFile.path)
    if let sourceState = sourceState {
      request.addParameter(.key_SourceText, value: sourceState.source)
    }
    request.addParameter(.key_Offset, value: offset)
    request.addParameter(.key_Line, value: location.line!)
    request.addParameter(.key_Column, value: location.column!)
    request.addCompilerArgs(args.sourcekitdArgs)

    let completionOptions = request.addDictionaryParameter(.key_CodeCompleteOptions)
    // Don't hide any results because otherwise checking if the expected result is contained will fail
    completionOptions.add(.key_HideLowPriority, value: 0)
    completionOptions.add(.key_HideByName, value: 0)
    completionOptions.add(.key_HideUnderscores, value: 0)
    // Disable inner results because they might cause a second completion to occur in SourceKit, slowing down the measurements.
    completionOptions.add(.key_AddInnerResults, value: 0)
    completionOptions.add(.key_AddInnerOperators, value: 0)

    // Set expected results to 200 to avoid inflating the time measurements by serialization time.
    // To make sure that the expected result is in the results, filter by its base name.
    completionOptions.add(.key_RequestLimit, value: 200)

    for (option, value) in extraOptions {
      if let intValue = Int(value) {
        completionOptions.add(SourceKitdUID(string: "key.codecomplete.\(option)"), value: intValue)
      } else {
        completionOptions.add(SourceKitdUID(string: "key.codecomplete.\(option)"), value: value)
      }
    }
    return request
  }

  func codeComplete(offset: Int, expectedResult: ExpectedResult?) throws -> (request: RequestInfo, response: SourceKitdResponse, instructions: Int, reusingASTContext: Bool) {
    var responseToReport: SourceKitdResponse
    let openRequest = buildCompletionRequest(request: .request_CodeCompleteOpen, offset: offset, extraOptions: extraCodeCompleteOptions)
    let openInfo = RequestInfo.codeCompleteOpen(document: documentInfo, offset: offset,
                                                args: args.sourcekitdArgs)
    let (openResponse, openInstructions) = try sendWithTimeoutMeasuringInstructions(openRequest, info: openInfo)

    let reusingASTContext = openResponse.value.getBool(.key_ReusingASTContext)

    if let expectedResult = expectedResult {
      var updateOptions = extraCodeCompleteOptions

      updateOptions["filtertext"] = expectedResult.name.base

      let updateRequest = buildCompletionRequest(request: .request_CodeCompleteUpdate, offset: offset, extraOptions: updateOptions)
      let updateInfo = RequestInfo.codeCompleteOpen(document: documentInfo, offset: offset, args: args.sourcekitdArgs)
      let updateResponse = try sendWithTimeout(updateRequest, info: updateInfo) { response in
        try checkExpectedCompletionResult(expectedResult, in: response, info: openInfo)
      }
      responseToReport = updateResponse
    } else {
      responseToReport = openResponse
    }

    let closeRequest = buildCompletionRequest(request: .request_CodeCompleteClose, offset: offset, extraOptions: extraCodeCompleteOptions)
    let closeInfo = RequestInfo.codeCompleteClose(document: documentInfo, offset: offset)
    _ = try sendWithTimeout(closeRequest, info: closeInfo)

    return (openInfo, responseToReport, openInstructions, reusingASTContext)
  }

  func typeContextInfo(offset: Int) throws -> (RequestInfo, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_TypeContextInfo)

    request.addParameter(.key_SourceFile, value: args.forFile.path)
    if let sourceState = sourceState {
      request.addParameter(.key_SourceText, value: sourceState.source)
    }
    request.addParameter(.key_Offset, value: offset)
    request.addCompilerArgs(args.sourcekitdArgs)

    let info = RequestInfo.typeContextInfo(document: documentInfo,
                                           offset: offset,
                                           args: args.sourcekitdArgs)
    let response = try sendWithTimeout(request, info: info)

    return (info, response)
  }

  func conformingMethodList(offset: Int, typeList: [String]) throws -> (RequestInfo, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_ConformingMethodList)

    request.addParameter(.key_SourceFile, value: args.forFile.path)
    if let sourceState = sourceState {
      request.addParameter(.key_SourceText, value: sourceState.source)
    }
    request.addParameter(.key_Offset, value: offset)

    let expressionTypeList = request.addArrayParameter(.key_ExpressionTypeList)
    for type in typeList { expressionTypeList.add(type) }

    request.addCompilerArgs(args.sourcekitdArgs)

    let info = RequestInfo.conformingMethodList(document: documentInfo,
                                                offset: offset,
                                                typeList: typeList,
                                                args: args.sourcekitdArgs)
    let response = try sendWithTimeout(request, info: info)

    return (info, response)
  }

  func collectExpressionType() throws -> (RequestInfo, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_CollectExpressionType)

    request.addParameter(.key_SourceFile, value: args.forFile.path)
    request.addCompilerArgs(args.sourcekitdArgs)

    let info = RequestInfo.collectExpressionType(document: documentInfo,
                                                 args: args.sourcekitdArgs)
    let response = try sendWithTimeout(request, info: info)

    return (info, response)
  }

  private func emitModule() throws {
    guard let sourceState = sourceState else { return }

    let moduleName = tempModulePath.deletingPathExtension().lastPathComponent
    let compilerArgs = self.args.processArgs + [
      // Merge modules ends up about the same speed as WMO when skipping
      // function bodies
      "-whole-module-optimization",
      "-Xfrontend", "-experimental-allow-module-with-compiler-errors",
      "-Xfrontend", "-experimental-skip-all-function-bodies",
      "-emit-module", "-module-name", moduleName, "-emit-module-path",
      tempModulePath.path,
      "-"
    ]

    let swiftcResult = ProcessRunner(launchPath: swiftc,
                                     arguments: compilerArgs)
      .run(input: sourceState.source)
    if swiftcResult.status != EXIT_SUCCESS {
      throw SourceKitError.failed(
        .errorWritingModule,
        request: .writeModule(document: documentInfo, args: compilerArgs),
        response: swiftcResult.stderrStr ?? "<could not decode stderr>")
    }
  }

  func moduleInterfaceGen() throws -> (RequestInfo, SourceKitdResponse) {
    try emitModule()

    let moduleDir = tempModulePath.deletingLastPathComponent()
    let moduleName = tempModulePath.deletingPathExtension().lastPathComponent
    let interfaceFile = moduleDir.appendingPathComponent("<interface-gen>")
    let compilerArgs = self.args.sourcekitdArgs + [
      "-I\(moduleDir.path)",
       "-Xfrontend", "-experimental-allow-module-with-compiler-errors"
    ]

    let request = SourceKitdRequest(uid: .request_EditorOpenInterface)
    request.addParameter(.key_SourceFile, value: args.forFile.path)
    request.addParameter(.key_Name, value: interfaceFile.path)
    request.addParameter(.key_ModuleName, value: moduleName)
    request.addCompilerArgs(compilerArgs)

    let info = RequestInfo.interfaceGen(document: documentInfo,
                                        moduleName: moduleName,
                                        args: compilerArgs)
    let response = try sendWithTimeout(request, info: info)
    return (info, response)
  }

  func replaceText(offset: Int, length: Int, text: String) throws -> (SourceFileSyntax, SourceKitdResponse) {
    let request = SourceKitdRequest(uid: .request_EditorReplaceText)
    request.addParameter(.key_Name, value: args.forFile.path)
    request.addParameter(.key_Offset, value: offset)
    request.addParameter(.key_Length, value: length)
    request.addParameter(.key_SourceText, value: text)

    request.addParameter(.key_EnableSyntaxMap, value: 0)
    request.addParameter(.key_EnableStructure, value: 0)
    request.addParameter(.key_SyntacticOnly, value: 1)

    let info = RequestInfo.editorReplaceText(document: documentInfo, offset: offset, length: length, text: text)
    let response = try sendWithTimeout(request, info: info)

    // update expected source content and syntax tree
    sourceState?.replace(offset: offset, length: length, with: text)
    try updateSyntaxTree(request: info)

    return (tree!, response)
  }

  private func checkExpectedCompletionResult(_ expected: ExpectedResult, in response: SourceKitdResponse, info: RequestInfo) throws {
    /// Struct that defines a code completion result to determine if there are duplicate results.
    struct CodeCompletionResultSpec: Hashable {
      let description: String
      let type: String
      let usr: String

      init(_ result: SourceKitdResponse.Dictionary) {
        self.description = result.getString(.key_Description)
        self.type = result.getString(.key_TypeName)
        self.usr = result.getString(.key_AssociatedUSRs)
      }
    }
    let matcher = CompletionMatcher(for: expected)
    var found = false
    var foundDuplicate: CodeCompletionResultSpec? = nil
    var seenResults = Set<CodeCompletionResultSpec>()
    response.value.getArray(.key_Results).enumerate { (_, item) -> Bool in
      let result = item.getDictionary()
      found = matcher.match(result.getString(.key_Name), ignoreArgLabels: shouldIgnoreArgs(of: expected, for: result))
      let resultSpec = CodeCompletionResultSpec(result)
      if foundDuplicate == nil, !seenResults.insert(resultSpec).inserted {
        foundDuplicate = resultSpec
      }
      return !found
    }
    lazy var truncatedResponseText = {
      // FIXME: code completion responses can be huge, truncate them for now.
      let maxSize = 25_000
      var responseText = response.description
      if responseText.count > maxSize {
        responseText = responseText.prefix(maxSize) + "[truncated]"
      }
      return responseText
    }()
    if !found {
      throw SourceKitError.failed(.missingExpectedResult, request: info, response: truncatedResponseText.trimmingCharacters(in: .newlines))
    }
    if let foundDuplicate = foundDuplicate {
      throw SourceKitError.failed(.duplicateResult(name: foundDuplicate.description), request: info, response: truncatedResponseText.trimmingCharacters(in: .newlines))
    }
  }

  private func shouldIgnoreArgs(of expected: ExpectedResult, for result: SourceKitdResponse.Dictionary) -> Bool {
    switch result.getUID(.key_Kind) {
    case .kind_DeclStruct, .kind_DeclClass, .kind_DeclEnum, .kind_DeclTypeAlias, .kind_DeclGenericTypeParam:
      // Initializer calls look like function calls syntactically, but the
      // completion results only include the type name. Allow for that by
      // matching on the base name only.
      return expected.kind == .call
    case .kind_DeclVarGlobal, .kind_DeclVarStatic, .kind_DeclVarClass, .kind_DeclVarInstance, .kind_DeclVarParam, .kind_DeclVarLocal:
      // Any variable/property of function type can be called, and looks the
      // same as a function call as far as the expected result is concerned,
      // but it's name won't have any argument labels.
      // If the expected result is a call that only has empty argument labels
      // (if any), it *may* be in this category, so match on the base name only.
      return expected.kind == .call && expected.name.argLabels.allSatisfy{ $0.isEmpty }
    default:
      return false
    }
  }

  /// Same as `sendWithTimeout` but also report the number of instructions
  /// executed by SourceKit to fulfill the request.
  /// The number of instructions is 0 if SourceKit crashed during the request.
  private func sendWithTimeoutMeasuringInstructions(_ request: SourceKitdRequest, info: RequestInfo, validateResponse: (SourceKitdResponse) throws -> Void = { _ in }) throws -> (response: SourceKitdResponse, instructions: Int) {
    let startInstructions = try getSourceKitInstructionCount()

    func getInstructionCount() throws -> Int {
      let endInstructions = try getSourceKitInstructionCount()
      if endInstructions < startInstructions {
        // sourcekitd crashed and was restarted for the request, which resets its instruction counter.
        // Report 0 to indicate that we were unable to measure the instructions.
        return 0
      } else {
        return endInstructions - startInstructions
      }
    }

    do {
      let response = try sendWithTimeout(request, info: info, validateResponse: validateResponse)
      return (response, try getInstructionCount())
    } catch SourceKitError.softTimeout(request: let request, duration: let duration, instructions: _) {
      throw SourceKitError.softTimeout(request: request, duration: duration, instructions: try getInstructionCount())
    } catch {
      throw error
    }
  }

  /// Send the `request` synchronously, timing out after
  /// `SOURCEKIT_REQUEST_TIMEOUT`.
  /// An error is thrown if either the response is invalid (see `throwIfInvalid`)
  /// or `validateResponse` throws. If the request took longer than half the
  /// time allowed but no other error is thrown, a `SourceKitError.softTimeout`
  /// will be thrown.
  private func sendWithTimeout(_ request: SourceKitdRequest, info: RequestInfo, validateResponse: (SourceKitdResponse) throws -> Void = { _ in }, reopenDocumentIfNeeded: Bool = true) throws -> SourceKitdResponse {
    var response: SourceKitdResponse? = nil
    let completed = DispatchSemaphore(value: 0)
    let startDate = Date()
    connection.send(request: request) {
      response = $0
      completed.signal()
    }
    switch completed.wait(timeout: .now() + DispatchTimeInterval.seconds(SOURCEKIT_REQUEST_TIMEOUT)) {
    case .success:
      guard let response = response else {
        fatalError("nil response without timout being hit?")
      }
      let requestDuration = Date().timeIntervalSince(startDate)
      if response.isError, response.description.contains("No associated Editor Document"), reopenDocumentIfNeeded {
        _ = try self.openOrUpdate(source: sourceState?.source)
        return try sendWithTimeout(request, info: info, validateResponse: validateResponse, reopenDocumentIfNeeded: false)
      } else {
        // Check if there was an error in the response
        try throwIfInvalid(response, request: info)
        try validateResponse(response)

        if requestDuration > TimeInterval(SOURCEKIT_REQUEST_TIMEOUT) / 5 {
          // There was no error in the response, but the request took too long
          // throw a soft timeout.
          throw SourceKitError.softTimeout(request: info, duration: requestDuration, instructions: nil)
        } else {
          return response
        }
      }
    case .timedOut:
      /// We timed out waiting for the response. Any following requests would
      /// not be executed by SourceKit until this one finishes. To avoid this,
      /// and since we don't have cancellation support in SourceKit, crash the
      /// current SourceKitService so we get a new instance that isn't
      /// processing any requests.
      connection.crash()
      throw SourceKitError.timedOut(request: info)
    }
  }

  private func isErrorAllowed(_ errorDescription: String, request: RequestInfo) -> Bool {
    let asyncErrorsToBlock: [String] = [
      "cannot refactor as callback closure argument missing",
      "cannot refactor as callback arguments do not match declaration"
    ]

    // The "Convert Call to Async Alternative" refactoring produces some error
    // responses that are expected and intended to be communicated to users
    // even though CursorInfo reports the refactoring as being applicable. These
    // aren't considered errors in the implementation so ignore them.
    if case .semanticRefactoring(_, _, "Convert Call to Async Alternative", _) = request {
      return !asyncErrorsToBlock.contains { errorDescription.contains($0) }
    }

    // FIXME: We don't supply a valid new name for initializer calls for local
    // rename requests. Ignore these errors for now.
    return errorDescription.contains("does not match the arity of the old name")
  }

  private func throwIfInvalid(_ response: SourceKitdResponse, request: RequestInfo) throws {
    if response.isError && !isErrorAllowed(response.description, request: request) {
      throw SourceKitError.failed(.errorResponse, request: request,
                                  response: response.description.trimmingCharacters(in: .newlines))
    }

    if response.isConnectionInterruptionError || response.isCompilerCrash {
      throw SourceKitError.crashed(request: request)
    }
  }

  private func parseSyntax(request: RequestInfo) throws -> SourceFileSyntax {
    let reparseTransition: IncrementalParseTransition?
    switch request {
    case .editorReplaceText(_, let offset, let length, let text):
      let edit = SourceEdit(range: ByteSourceRange(offset: offset, length: length), replacementLength: text.utf8.count)
      reparseTransition = IncrementalParseTransition(previousTree: self.tree!, edits: ConcurrentEdits(edit))
    default:
      reparseTransition = nil
    }

    let diagHandler = { (diag: Diagnostic) in
      // An empty diagnostic handler to practice the diagnostic APIs associated
      // with SwiftSyntax parser.
    }

    let tree: SourceFileSyntax
    if let state = sourceState {
      tree = try SyntaxParser.parse(source: state.source,
                                    parseTransition: reparseTransition,
                                    diagnosticHandler: diagHandler)
    } else {
      tree = try SyntaxParser.parse(args.forFile, diagnosticHandler: diagHandler)
    }
    return tree
  }

  @discardableResult
  private func updateSyntaxTree(request: RequestInfo) throws -> SourceFileSyntax {
    let tree: SourceFileSyntax
    do {
      tree = try parseSyntax(request: request)
    } catch let error {
      throw SourceKitError.failed(.errorDeserializingSyntaxTree, request: request, response: error.localizedDescription)
    }
    self.tree = tree
    self.converter = SourceLocationConverter(file: "", tree: tree)

    /// When we should be able to fully parse the file, we verify the syntax tree
    if !containsErrors {
      do {
        try SyntaxVerifier.verify(Syntax(tree))
      } catch let error as SyntaxVerifierError {
        throw SourceKitError.failed(.errorDeserializingSyntaxTree, request: request, response: error.description)
      }
    }

    if let state = sourceState, state.source != tree.description {
      // FIXME: add state and tree descriptions in their own field
      let comparison = """
        --source-state------
        \(state.source)
        --tree-description--
        \(tree.description)
        --end---------------
        """
      throw SourceKitError.failed(.sourceAndSyntaxTreeMismatch, request: request, response: comparison)
    }

    return tree
  }
}

/// Tracks the current state of a source file
public struct SourceState {
  public let mode: RewriteMode
  public var source: String
  public var wasModified: Bool

  public init(rewriteMode: RewriteMode, content source: String, wasModified: Bool = false) {
    self.mode = rewriteMode
    self.source = source
    self.wasModified = wasModified
  }

  /// - returns: true if source state changed
  @discardableResult
  public mutating func replace(offset: Int, length: Int, with text: String) -> Bool {
    let bytes = source.utf8
    let prefix = bytes.prefix(upTo: bytes.index(bytes.startIndex, offsetBy: offset))
    let suffix = bytes.suffix(from: bytes.index(bytes.startIndex, offsetBy: offset + length))
    source = String(prefix)! + text + String(suffix)!
    let changed = length > 0 || !text.isEmpty
    wasModified = wasModified || changed
    return changed
  }
}

public struct CompletionMatcher {
  private let expected: ExpectedResult

  public init(for expected: ExpectedResult) {
    self.expected = expected
  }

  /// - returns: true if a match was found
  public func match(_ result: String, ignoreArgLabels: Bool) -> Bool {
    if ignoreArgLabels {
      let name = SwiftName(result)!
      return name.base == expected.name.base
    }
    // Check if the base name and/or argument labels match based on the expected
    // result kind.
    return matches(name: result)
  }

  private func matches(name: String) -> Bool {
    let resultName = SwiftName(name)!
    guard resultName.base == expected.name.base else { return false }
    switch expected.kind {
    case .call:
      return name.last == ")" && matchesCall(paramLabels: resultName.argLabels)
    case .reference:
      return expected.name.argLabels.isEmpty || expected.name.argLabels == resultName.argLabels
    case .pattern:
      // If the expected result didn't match on the associated value: it matches
      if expected.name.argLabels.isEmpty {
        return true
      }

      // Result names for enum cases work differently to functions in that
      // unlabelled items in the associated values aren't represented, e.g.:
      //   case foo              // name: foo
      //   case foo(Int, Int)    // name: foo()
      //   case foo(x: Int, Int) // name: foo(x:)
      //   case foo(Int, y: Int) // name: foo(y:)

      // If the result name doesn't have an associated value, but the expected
      // name does: it doesn't match
      if name.last != ")" && !expected.name.argLabels.isEmpty {
        return false
      }

      // If the expected result bound the entire associated value to a single
      // unlabelled variable, we're done
      if expected.name.argLabels == [""] {
        return true
      }

      // Otherwise the expected argument labels must either match the
      // corresponding result arg labels or be "" since they don't have to be
      // specified when pattern matching.
      var unmatched = resultName.argLabels[...]
      return expected.name.argLabels.allSatisfy{ label in
        if label.isEmpty { return true }
        if let labelIndex = unmatched.firstIndex(of: label) {
          unmatched = unmatched.dropFirst(labelIndex - unmatched.startIndex + 1)
          return true
        }
        return false
      }
    }
  }

  private func matchesCall(paramLabels: [String]) -> Bool {
    var remainingArgLabels = expected.name.argLabels[...]

    guard !paramLabels.isEmpty else {
      return remainingArgLabels.allSatisfy { $0.isEmpty }
    }
    for nextParamLabel in paramLabels {
      if nextParamLabel.isEmpty {
        // No label
        if let first = remainingArgLabels.first, first.isEmpty {
          // Matched - consume the argument
          _ = remainingArgLabels.removeFirst()
        } else {
          // Assume this was defaulted and skip over it
          continue
        }
      } else {
        // Has param label
        if remainingArgLabels.count < expected.name.argLabels.count {
          // A previous param was matched, so assume it was variadic and consume
          // any leading unlabelled args so the next arg is labelled
          remainingArgLabels = remainingArgLabels.drop{ $0.isEmpty }
        }
        guard let nextArgLabel = remainingArgLabels.first else {
          // Assume any unprocessed parameters are defaulted
          return true
        }
        if nextArgLabel == nextParamLabel {
          // Matched - consume the argument
          _ = remainingArgLabels.removeFirst()
          continue
        }
        // Else assume this param was defaulted and skip it.
      }
    }
    // If at least one arglabel was matched, allow for it being variadic
    let hadMatch = remainingArgLabels.count < expected.name.argLabels.count
    return  remainingArgLabels.isEmpty || hadMatch &&
      remainingArgLabels.allSatisfy { $0.isEmpty }
  }
}
