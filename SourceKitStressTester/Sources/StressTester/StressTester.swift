//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftSourceKit
import SwiftSyntax
import Common

public struct StressTester {
  let options: StressTesterOptions
  let connection: SourceKitdService

  public init(options: StressTesterOptions) {
    self.options = options
    self.connection = SourceKitdService()
  }

  var generator: ActionGenerator {
    switch options.rewriteMode {
    case .none:
      return RequestActionGenerator()
    case .typoed:
      return TypoActionGenerator()
    case .basic:
      return BasicRewriteActionGenerator()
    case .insideOut:
      return InsideOutRewriteActionGenerator()
    case .concurrent:
      return ConcurrentRewriteActionGenerator()
    }
  }

  public func run(swiftc: String, compilerArgs: CompilerArgs) throws {
    var document = SourceKitDocument(swiftc: swiftc,
                                     args: compilerArgs,
                                     tempDir: options.tempDir,
                                     connection: connection,
                                     containsErrors: true)

    // compute the actions for the entire tree
    let (tree, _) = try document.open(rewriteMode: options.rewriteMode)
    let (actions, priorActions) = computeActions(from: tree)

    if let dryRunAction = options.dryRun {
      try dryRunAction(actions)
      return
    }

    if !priorActions.isEmpty {
      // Update initial state
      _ = try document.update() { sourceState in
        for case .replaceText(let offset, let length, let text) in priorActions {
          sourceState.replace(offset: offset, length: length, with: text)
        }
      }
    }

    for action in actions {
      switch action {
      case .cursorInfo(let offset):
        try report(document.cursorInfo(offset: offset))
      case .codeComplete(let offset, let expectedResult):
        try report(document.codeComplete(offset: offset, expectedResult: expectedResult))
      case .rangeInfo(let offset, let length):
        try report(document.rangeInfo(offset: offset, length: length))
      case .replaceText(let offset, let length, let text):
        _ = try document.replaceText(offset: offset, length: length, text: text)
      case .format(let offset):
        try report(document.format(offset: offset))
      case .typeContextInfo(let offset):
        try report(document.typeContextInfo(offset: offset))
      case .conformingMethodList(let offset):
        try report(document.conformingMethodList(offset: offset, typeList: options.conformingMethodsTypeList))
      case .collectExpressionType:
        try report(document.collectExpressionType())
      case .testModule:
        try report(document.moduleInterfaceGen())
      }
    }

    try document.close()
  }

  private func computeActions(from tree: SourceFileSyntax) -> (page: [Action], priorActions: [Action]) {
    let limit = options.astBuildLimit ?? Int.max
    var astRebuilds = 0
    var locationsInvalidated = false

    let pages = generator
      .generate(for: tree)
      .filter { action in
        guard !locationsInvalidated else { return false }
        switch action {
        case .cursorInfo:
          return options.requests.contains(.cursorInfo)
        case .rangeInfo:
          return options.requests.contains(.rangeInfo)
        case .format:
          return options.requests.contains(.format)
        case .codeComplete:
          guard options.requests.contains(.codeComplete), astRebuilds <= limit else { return false }
          astRebuilds += 1
          return true
        case .typeContextInfo:
          guard options.requests.contains(.typeContextInfo), astRebuilds <= limit else { return false}
          astRebuilds += 1
          return true
        case .conformingMethodList:
          guard options.requests.contains(.conformingMethodList), astRebuilds <= limit else { return false }
          astRebuilds += 1
          return true
        case .collectExpressionType:
          return options.requests.contains(.collectExpressionType)
        case .replaceText:
          guard astRebuilds <= limit else {
            locationsInvalidated = true
            return false
          }
          astRebuilds += 1
          return true
        case .testModule:
          return options.requests.contains(.testModule)
        }
      }
      .divide(into: options.page.count)

    return (
      page: Array(pages[options.page.index]),
      priorActions: Array(pages[..<options.page.index].joined())
    )
  }

  private func report(_ result: (RequestInfo, SourceKitdResponse)) throws {
    guard let handler = options.responseHandler else { return }

    let (request, response) = result
    switch request {
    case .codeComplete: fallthrough
    case .conformingMethodList: fallthrough
    case .typeContextInfo:
      let results = getCompletionResults(from: response.value.getArray(.key_Results))
      try handler(SourceKitResponseData(results, for: request))
    default:
      try handler(SourceKitResponseData([response.value.description], for: request))
    }
  }

  private func getCompletionResults(from results: SourceKitdResponse.Array) -> [String] {
    var global = [String]()
    var module = [String]()
    var local = [String]()
    results.enumerate { _, result -> Bool in
      let value = result.getDictionary()
      let name = value.getString(.key_Name)
      switch value.getUID(.key_Context) {
      case .kind_CompletionContextOtherModule:
        global.append(name)
      case .kind_CompletionContextThisModule:
        module.append(name)
      default:
        local.append(name)
      }
      return true
    }

    return [("global", global), ("module", module), ("local", local)].map { label, results in
      "\(label): \(results.isEmpty ? "<empty>" : results.sorted().joined(separator: ", "))"
    }
  }
}

private extension SourceKitdUID {
  static let kind_CompletionContextOtherModule = SourceKitdUID(string: "source.codecompletion.context.othermodule")
  static let kind_CompletionContextThisModule = SourceKitdUID(string: "source.codecompletion.context.thismodule")
}

public struct StressTesterOptions {
  public var requests: Set<RequestKind>
  public var rewriteMode: RewriteMode
  public var conformingMethodsTypeList: [String]
  public var page: Page
  public var tempDir: URL
  public var astBuildLimit: Int?
  public var responseHandler: ((SourceKitResponseData) throws -> Void)?
  public var dryRun: (([Action]) throws -> Void)?

  public init(requests: Set<RequestKind>, rewriteMode: RewriteMode,
              conformingMethodsTypeList: [String], page: Page,
              tempDir: URL, astBuildLimit: Int? = nil,
              responseHandler: ((SourceKitResponseData) throws -> Void)? = nil,
              dryRun: (([Action]) throws -> Void)? = nil) {
    self.requests = requests
    self.rewriteMode = rewriteMode
    self.conformingMethodsTypeList = conformingMethodsTypeList
    self.page = page
    self.tempDir = tempDir
    self.astBuildLimit = astBuildLimit
    self.responseHandler = responseHandler
    self.dryRun = dryRun
  }
}
