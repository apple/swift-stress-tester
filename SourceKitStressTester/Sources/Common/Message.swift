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

import Foundation

public protocol Message: Codable, CustomStringConvertible {}

public extension Message {
  init?(from data: Data) {
    guard let message = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
    self = message
  }
}

public enum StressTesterMessage: Message {
  case detected(SourceKitError)
  case produced(SourceKitResponseData)
}

public struct SourceKitResponseData: Codable {
  public let request: RequestInfo
  public let results: [String]

  public init(_ results: [String], for request: RequestInfo) {
    self.results = results
    self.request = request
  }
}

public enum SourceKitError: Error {
  case crashed(request: RequestInfo)
  case timedOut(request: RequestInfo)
  /// Thrown if a request was close to the time out that triggers a timedOut
  /// error.
  /// If it was counted how many instructions SourceKit took to fulfill the
  /// request, `instructions` contains that number. Otherwise it's `nil`.
  case softTimeout(request: RequestInfo, duration: TimeInterval, instructions: Int?)
  case failed(_ reason: SourceKitErrorReason, request: RequestInfo, response: String)

  public var request: RequestInfo {
    switch self {
    case .crashed(let request):
      return request
    case .timedOut(let request):
      return request
    case .softTimeout(let request, _, _):
      return request
    case .failed(_, let request, _):
      return request
    }
  }

  /// Soft errors are allowed to match XFails, but don't fail the stress tester
  /// on their own.
  /// The current use case for soft errors are soft timeouts, where the request
  /// took more than half of the allowed time. If the issue is XFailed, we don't
  /// want to mark it as unexpectedly passed because the faster execution time
  /// might be due to noise. But we haven't surpassed the limit either, so it
  /// shouldn't be a hard error either.
  public var isSoft: Bool {
    switch self {
    case .crashed, .timedOut, .failed:
      return false
    case .softTimeout:
      return true
    }
  }
}

public enum SourceKitErrorReason: String, Codable {
  case errorResponse, errorTypeInResponse,
       sourceAndSyntaxTreeMismatch, missingExpectedResult, errorWritingModule
}

public enum RequestInfo {
  case editorOpen(document: DocumentInfo)
  case editorClose(document: DocumentInfo)
  case editorReplaceText(document: DocumentInfo, offset: Int, length: Int, text: String)
  case format(document: DocumentInfo, offset: Int)
  case cursorInfo(document: DocumentInfo, offset: Int, args: [String])
  case codeCompleteOpen(document: DocumentInfo, offset: Int, args: [String])
  case codeCompleteUpdate(document: DocumentInfo, offset: Int, args: [String])
  case codeCompleteClose(document: DocumentInfo, offset: Int)
  case rangeInfo(document: DocumentInfo, offset: Int, length: Int, args: [String])
  case semanticRefactoring(document: DocumentInfo, offset: Int, kind: String, args: [String])
  case typeContextInfo(document: DocumentInfo, offset: Int, args: [String])
  case conformingMethodList(document: DocumentInfo, offset: Int, typeList: [String], args: [String])
  case collectExpressionType(document: DocumentInfo, args: [String])
  case writeModule(document: DocumentInfo, args: [String])
  case interfaceGen(document: DocumentInfo, moduleName: String, args: [String])
  case statistics
}

public struct DocumentInfo: Codable {
  public let path: String
  public let modification: DocumentModification?
  /// A String with enough information to unique identify the state of a
  /// document in comparison to other modifications produced by the stress
  /// tester.
  public var modificationSummaryCode: String {
    return modification?.summaryCode ?? "unmodified"
  }

  public init(path: String, modification: DocumentModification? = nil) {
    self.path = path
    self.modification = modification
  }
}

public struct DocumentModification: Codable {
  public let mode: RewriteMode
  public let content: String

  public init(mode: RewriteMode, content: String) {
    self.mode = mode
    self.content = content
  }

  /// A String with enough information to unique identify the modified state of
  /// a document in comparison to other modifications produced by the stress
  /// tester.
  public var summaryCode: String {
    return "\(mode)-\(content.count)"
  }
}

public enum RewriteMode: String, Codable, CaseIterable {
  /// Do not rewrite the file (only make non-modifying SourceKit requests)
  case none
  /// Rewrite each identifier to be mispelled
  case typoed
  /// Rewrite the file token by token, top to bottom
  case basic
  /// Rewrite all top level declarations top to bottom, concurrently
  case concurrent
  /// Rewrite the file from the most deeply nested tokens to the least
  case insideOut
}

public struct Page: Codable, Equatable {
  public let number: Int
  public let count: Int
  public var isFirst: Bool {
    return number == 1
  }
  public var index: Int {
    return number - 1
  }

  public init(_ number: Int = 1, of count: Int = 1) {
    assert(number >= 1 && number <= count)
    self.number = number
    self.count = count
  }
}

extension Page: CustomStringConvertible {
  public var description: String {
    if number == 1 && count == 1 {
      return "none"
    }
    return "\(number) of \(count)"
  }
}

extension StressTesterMessage: Codable {
  enum CodingKeys: String, CodingKey {
    case message, error, responseData
  }
  enum BaseMessage: String, Codable {
    case detected, produced
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(BaseMessage.self, forKey: .message) {
    case .detected:
      let error = try container.decode(SourceKitError.self, forKey: .error)
      self = .detected(error)
    case .produced:
      let responseData = try container.decode(SourceKitResponseData.self, forKey: .responseData)
      self = .produced(responseData)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .detected(let error):
      try container.encode(BaseMessage.detected, forKey: .message)
      try container.encode(error, forKey: .error)
    case .produced(let responseData):
      try container.encode(BaseMessage.produced, forKey: .message)
      try container.encode(responseData, forKey: .responseData)
    }
  }
}

extension SourceKitError: Codable {
  enum CodingKeys: String, CodingKey {
    case error, kind, request, response, duration, instructions
  }
  enum BaseError: String, Codable {
    case crashed, failed, timedOut, softTimeout
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(BaseError.self, forKey: .error) {
    case .crashed:
      let request = try container.decode(RequestInfo.self, forKey: .request)
      self = .crashed(request: request)
    case .timedOut:
      let request = try container.decode(RequestInfo.self, forKey: .request)
      self = .timedOut(request: request)
    case .softTimeout:
      let request = try container.decode(RequestInfo.self, forKey: .request)
      let duration = try container.decode(Double.self, forKey: .duration)
      let instructions = try container.decodeIfPresent(Int.self, forKey: .instructions)
      self = .softTimeout(request: request, duration: duration, instructions: instructions)
    case .failed:
      let reason = try container.decode(SourceKitErrorReason.self, forKey: .kind)
      let request = try container.decode(RequestInfo.self, forKey: .request)
      let response = try container.decode(String.self, forKey: .response)
      self = .failed(reason, request: request, response: response)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .crashed(let request):
      try container.encode(BaseError.crashed, forKey: .error)
      try container.encode(request, forKey: .request)
    case .timedOut(let request):
      try container.encode(BaseError.timedOut, forKey: .error)
      try container.encode(request, forKey: .request)
    case .softTimeout(let request, let duration, let instructions):
      try container.encode(BaseError.softTimeout, forKey: .error)
      try container.encode(request, forKey: .request)
      try container.encode(duration, forKey: .duration)
      try container.encodeIfPresent(instructions, forKey: .instructions)
    case .failed(let kind, let request, let response):
      try container.encode(BaseError.failed, forKey: .error)
      try container.encode(kind, forKey: .kind)
      try container.encode(request, forKey: .request)
      try container.encode(response, forKey: .response)
    }
  }
}

extension RequestInfo: Codable {
  enum CodingKeys: String, CodingKey {
    case request, kind, document, offset, length, text, args, typeList,
         moduleName
  }
  enum BaseRequest: String, Codable {
    case editorOpen
    case editorClose
    case replaceText
    case format
    case cursorInfo
    case codeCompleteOpen
    case codeCompleteUpdate
    case codeCompleteClose
    case rangeInfo
    case semanticRefactoring
    case typeContextInfo
    case conformingMethodList
    case collectExpressionType
    case writeModule
    case interfaceGen
    case statistics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(BaseRequest.self, forKey: .request) {
    case .editorOpen:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      self = .editorOpen(document: document)
    case .editorClose:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      self = .editorClose(document: document)
    case .cursorInfo:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let args = try container.decode([String].self, forKey: .args)
      self = .cursorInfo(document: document, offset: offset, args: args)
    case .codeCompleteOpen:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let args = try container.decode([String].self, forKey: .args)
      self = .codeCompleteOpen(document: document, offset: offset, args: args)
    case .codeCompleteUpdate:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let args = try container.decode([String].self, forKey: .args)
      self = .codeCompleteUpdate(document: document, offset: offset, args: args)
    case .codeCompleteClose:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      self = .codeCompleteClose(document: document, offset: offset)
    case .rangeInfo:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let length = try container.decode(Int.self, forKey: .length)
      let args = try container.decode([String].self, forKey: .args)
      self = .rangeInfo(document: document, offset: offset, length: length, args: args)
    case .semanticRefactoring:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let kind = try container.decode(String.self, forKey: .kind)
      let args = try container.decode([String].self, forKey: .args)
      self = .semanticRefactoring(document: document, offset: offset, kind: kind, args: args)
    case .replaceText:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let length = try container.decode(Int.self, forKey: .length)
      let text = try container.decode(String.self, forKey: .text)
      self = .editorReplaceText(document: document, offset: offset, length: length, text: text)
    case .format:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      self = .format(document: document, offset: offset)
    case .typeContextInfo:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let args = try container.decode([String].self, forKey: .args)
      self = .typeContextInfo(document: document, offset: offset, args: args)
    case .conformingMethodList:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let offset = try container.decode(Int.self, forKey: .offset)
      let typeList = try container.decode([String].self, forKey: .typeList)
      let args = try container.decode([String].self, forKey: .args)
      self = .conformingMethodList(document: document, offset: offset, typeList: typeList, args: args)
    case .collectExpressionType:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let args = try container.decode([String].self, forKey: .args)
      self = .collectExpressionType(document: document, args: args)
    case .writeModule:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let args = try container.decode([String].self, forKey: .args)
      self = .writeModule(document: document, args: args)
    case .interfaceGen:
      let document = try container.decode(DocumentInfo.self, forKey: .document)
      let moduleName = try container.decode(String.self, forKey: .moduleName)
      let args = try container.decode([String].self, forKey: .args)
      self = .interfaceGen(document: document, moduleName: moduleName, args: args)
    case .statistics:
      self = .statistics
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .editorOpen(let document):
      try container.encode(BaseRequest.editorOpen, forKey: .request)
      try container.encode(document, forKey: .document)
    case .editorClose(let document):
      try container.encode(BaseRequest.editorClose, forKey: .request)
      try container.encode(document, forKey: .document)
    case .cursorInfo(let document, let offset, let args):
      try container.encode(BaseRequest.cursorInfo, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(args, forKey: .args)
    case .codeCompleteOpen(let document, let offset, let args):
      try container.encode(BaseRequest.codeCompleteOpen, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(args, forKey: .args)
    case .codeCompleteUpdate(let document, let offset, let args):
      try container.encode(BaseRequest.codeCompleteUpdate, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(args, forKey: .args)
    case .codeCompleteClose(let document, let offset):
      try container.encode(BaseRequest.codeCompleteClose, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
    case .rangeInfo(let document, let offset, let length, let args):
      try container.encode(BaseRequest.rangeInfo, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(length, forKey: .length)
      try container.encode(args, forKey: .args)
    case .semanticRefactoring(let document, let offset, let kind, let args):
      try container.encode(BaseRequest.semanticRefactoring, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(kind, forKey: .kind)
      try container.encode(args, forKey: .args)
    case .editorReplaceText(let document, let offset, let length, let text):
      try container.encode(BaseRequest.replaceText, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(length, forKey: .length)
      try container.encode(text, forKey: .text)
    case .format(let document, let offset):
      try container.encode(BaseRequest.format, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
    case .typeContextInfo(let document, let offset, let args):
      try container.encode(BaseRequest.typeContextInfo, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(args, forKey: .args)
    case .conformingMethodList(let document, let offset, let typeList, let args):
      try container.encode(BaseRequest.conformingMethodList, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(offset, forKey: .offset)
      try container.encode(typeList, forKey: .typeList)
      try container.encode(args, forKey: .args)
    case .collectExpressionType(let document, let args):
      try container.encode(BaseRequest.collectExpressionType, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(args, forKey: .args)
    case .writeModule(let document, let args):
      try container.encode(BaseRequest.writeModule, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(args, forKey: .args)
    case .interfaceGen(let document, let moduleName, let args):
      try container.encode(BaseRequest.interfaceGen, forKey: .request)
      try container.encode(document, forKey: .document)
      try container.encode(moduleName, forKey: .moduleName)
      try container.encode(args, forKey: .args)
    case .statistics:
      try container.encode(BaseRequest.statistics, forKey: .request)
    }
  }
}

extension RequestInfo: CustomStringConvertible {
  public var description: String {
    switch self {
    case .editorOpen(let document):
      return "EditorOpen on \(document)"
    case .editorClose(let document):
      return "EditorClose on \(document)"
    case .cursorInfo(let document, let offset, let args):
      return "CursorInfo in \(document) at offset \(offset) with args: \(escapeArgs(args))"
    case .rangeInfo(let document, let offset, let length, let args):
      return "RangeInfo in \(document) at offset \(offset) for length \(length) with args: \(escapeArgs(args))"
    case .codeCompleteOpen(let document, let offset, let args):
      return "CodeCompleteOpen in \(document) at offset \(offset) with args: \(escapeArgs(args))"
    case .codeCompleteUpdate(let document, let offset, let args):
      return "CodeCompleteUpdate in \(document) at offset \(offset) with args: \(escapeArgs(args))"
    case .codeCompleteClose(let document, let offset):
      return "CodeCompleteClose in \(document) at offset \(offset)"
    case .semanticRefactoring(let document, let offset, let kind, let args):
      return "SemanticRefactoring (\(kind)) in \(document) at offset \(offset) with args: \(escapeArgs(args))"
    case .editorReplaceText(let document, let offset, let length, let text):
      return "ReplaceText in \(document) at offset \(offset) for length \(length) with text: \(text)"
    case .format(let document, let offset):
      return "Format in \(document) at offset \(offset)"
    case .typeContextInfo(let document, let offset, let args):
      return "TypeContextInfo in \(document) at offset \(offset) with args: \(escapeArgs(args))"
    case .conformingMethodList(let document, let offset, let typeList, let args):
      return "ConformingMethodList in \(document) at offset \(offset) conforming to \(typeList.joined(separator: ", ")) with args: \(escapeArgs(args))"
    case .collectExpressionType(let document, let args):
      return "CollectExpressionType in \(document) with args: \(escapeArgs(args))"
    case .writeModule(let document, let args):
      return "WriteModule for \(document) with args: \(escapeArgs(args))"
    case .interfaceGen(let document, let moduleName, let args):
      return "InterfaceGen for \(document) compiled as \(moduleName) with args: \(escapeArgs(args))"
    case .statistics:
      return "SourceKit statistics"
    }
  }
}

extension DocumentInfo: CustomStringConvertible {
  public var description: String {
    guard let modification = modification else {
      return path
    }
    return "\(path) (modified: \(modification.mode.rawValue))"
  }
}

extension SourceKitErrorReason: CustomStringConvertible {
  public var description: String {
    switch self {
    case .errorResponse:
      return "SourceKit returned an error response"
    case .errorTypeInResponse:
      return "SourceKit returned a response containing <<error type>>"
    case .sourceAndSyntaxTreeMismatch:
      return "SourceKit returned a syntax tree that doesn't match the expected source"
    case .missingExpectedResult:
      return "SourceKit returned a response that didn't contain the expected result"
    case .errorWritingModule:
      return "Error while writing out module"
    }
  }
}

extension SourceKitResponseData: CustomStringConvertible {
  public var description: String {
    let response = results.isEmpty ? "<empty>" : results.joined(separator: ",\n")
    return """
    Response for \(request)
    -- begin response ------------
    \(response)
    -- end response --------------
    """
  }
}

extension SourceKitError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .crashed(let request):
      return """
        SourceKit crashed
          request: \(request)
        -- begin file content --------
        \(markSourceLocation(of: request) ?? "<unmodified>")
        -- end file content ----------
        """
    case .timedOut(let request):
      return """
        Timed out waiting for SourceKit response
          request: \(request)
        -- begin file content --------
        \(markSourceLocation(of: request) ?? "<unmodified>")
        -- end file content ----------
        """
    case .softTimeout(let request, let duration, let instructions):
      return """
        Request took \(duration) seconds (\(instructions.map(String.init) ?? "<unknown>") instructions) to execute. This is more than a tenth of the allowed time. This error will match XFails but won't count as an error by itself.
          request: \(request)
        -- begin file content --------
        \(markSourceLocation(of: request) ?? "<unmodified>")
        -- end file content ----------
        """
    case .failed(let reason, let request, let response):
      return """
        \(reason)
          request: \(request)
          response: \(response)
        -- begin file content --------
        \(markSourceLocation(of: request) ?? "<unmodified>")
        -- end file content ----------
        """
    }
  }

  /// Returns the current document's contents, marking the position at UTF-8 offset `offset` by `<markerName>`.
  private func documentContent(document: DocumentInfo, markingOffset offset: Int, markerName: String) -> String? {
    guard let source = document.modification?.content else { return nil }
    let index = source.utf8.index(source.utf8.startIndex, offsetBy: offset)
    return "\(source[..<index])<\(markerName)>\(source[index...])"
  }

  /// Returns the current document's contents, marking the UTF-8 offset range `range` by `<markerName>` and `</markerName>`.
  private func documentContent(document: DocumentInfo, markingOffsetRange range: Range<Int>, markerName: String) -> String? {
    guard let source = document.modification?.content else { return nil }
    let startIndex = source.utf8.index(source.utf8.startIndex, offsetBy: range.lowerBound)
    let endIndex = source.utf8.index(source.utf8.startIndex, offsetBy: range.upperBound)
    return "\(source[..<startIndex])<\(markerName)>\(source[startIndex..<endIndex])</\(markerName)>\(source[endIndex...])"
  }

  private func markSourceLocation(of request: RequestInfo) -> String? {
    switch request {
    case .editorOpen(let document):
      return document.modification?.content
    case .editorClose(let document):
      return document.modification?.content
    case .editorReplaceText(let document, let offset, let length, _):
      return documentContent(document: document, markingOffsetRange: offset..<(offset + length), markerName: "replace")
    case .format(let document, let offset):
      return documentContent(document: document, markingOffset: offset, markerName: "format")
    case .cursorInfo(let document, let offset, _):
      return documentContent(document: document, markingOffset: offset, markerName: "cursor-offset")
    case .codeCompleteOpen(let document, let offset, _):
      return documentContent(document: document, markingOffset: offset, markerName: "complete-offset")
    case .codeCompleteUpdate(let document, let offset, _):
      return documentContent(document: document, markingOffset: offset, markerName: "complete-offset")
    case .codeCompleteClose(let document, let offset):
      return documentContent(document: document, markingOffset: offset, markerName: "complete-offset")
    case .rangeInfo(let document, let offset, let length, _):
      return documentContent(document: document, markingOffsetRange: offset..<(offset + length), markerName: "range")
    case .semanticRefactoring(let document, let offset, _, _):
      return documentContent(document: document, markingOffset: offset, markerName: "refactor-offset")
    case .typeContextInfo(let document, let offset, _):
      return documentContent(document: document, markingOffset: offset, markerName: "type-context-info-offset")
    case .conformingMethodList(let document, let offset, _, _):
      return documentContent(document: document, markingOffset: offset, markerName: "conforming-method-list-offset")
    case .collectExpressionType(let document, _):
      return document.modification?.content
    case .writeModule(let document, _):
      return document.modification?.content
    case .interfaceGen(let document, _, _):
      return document.modification?.content
    case .statistics:
      return nil
    }
  }
}

extension StressTesterMessage: CustomStringConvertible {
  public var description: String {
    switch self {
    case .detected(let error):
      return "Failure detected: \(error)"
    case .produced(let responseData):
      return "Produced: \(responseData)"
    }
  }
}

public enum RequestKind: String, CaseIterable, CustomStringConvertible, Codable {
  case replaceText = "ReplaceText"
  case cursorInfo = "CursorInfo"
  case rangeInfo = "RangeInfo"
  case codeComplete = "CodeComplete"
  case codeCompleteUpdate = "CodeCompleteUpdate"
  case codeCompleteClose = "CodeCompleteClose"
  case typeContextInfo = "TypeContextInfo"
  case conformingMethodList = "ConformingMethodList"
  case collectExpressionType = "CollectExpressionType"
  case format = "Format"
  case testModule = "TestModule"
  case all = "All"

  public var description: String { self.rawValue }

  public static let allRequests: [RequestKind] =
    [.cursorInfo, .rangeInfo, .codeComplete, .collectExpressionType, .format,
     .typeContextInfo, .conformingMethodList, .testModule]

  public static func byName(_ name: String) -> RequestKind? {
    let lower = name.lowercased()
    return RequestKind.allCases
      .first(where: { $0.rawValue.lowercased() == lower })
  }

  public static func reduce(_ kinds: [RequestKind]) -> Set<RequestKind> {
    return Set(kinds.flatMap { kind -> [RequestKind] in
      switch kind {
      case .all:
        return allRequests
      default:
        return [kind]
      }
    })
  }
}
