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
import Common

public struct SwiftCWrapperTool {
  let arguments: [String]
  let environment: [String: String]

  public init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.arguments = arguments
    self.environment = environment
  }

  public func run() throws -> Int32 {
    /// Non-default path to swiftc
    let swiftcEnv = EnvOption("SK_STRESS_SWIFTC", type: String.self)
    /// Non-default path to sk-stress-test
    let stressTesterEnv = EnvOption("SK_STRESS_TEST", type: String.self)
    /// Always return the same exit code as the underlying swiftc, even if stress testing uncovers failures
    let ignoreIssuesEnv = EnvOption("SK_STRESS_SILENT", type: Bool.self)
    /// Limit the number of sourcekit requests made per-file based on the number of AST rebuilds they trigger
    let astBuildLimitEnv = EnvOption("SK_STRESS_AST_BUILD_LIMIT", type: Int.self)
    /// A file in which measurements how long the SourceKit requests issued by the stress tester took, should be aggregated
    let requestDurationsOutputFileEnv = EnvOption("SK_STRESS_REQUEST_DURATIONS_FILE", type: String.self)
    /// Output only what the wrapped compiler outputs
    let suppressOutputEnv = EnvOption("SK_STRESS_SUPPRESS_OUTPUT", type: Bool.self)
    /// Non-default space-separated list of rewrite modes to use
    let rewriteModesEnv = EnvOption("SK_STRESS_REWRITE_MODES", type: [RewriteMode].self)
    /// Non-default space-separated list of request types to use
    let requestKindsEnv = EnvOption("SK_STRESS_REQUESTS", type: [RequestKind].self)
    /// Non-default space-separated list of protocol USRs to use for the ConformingMethodList request
    let conformingMethodTypesEnv = EnvOption("SK_STRESS_CONFORMING_METHOD_TYPES", type: [String].self)
    /// Limit the number of jobs
    let maxJobsEnv = EnvOption("SK_STRESS_MAX_JOBS", type: Int.self)
    /// Dump sourcekitd's responses to the supplied path
    let dumpResponsesPathEnv = EnvOption("SK_STRESS_DUMP_RESPONSES_PATH", type: String.self)
    /// Extra arguments to pass to code completion requests in the `key.codecomplete.options` dictionary.
    /// Key and values are separated by `=`. Multiple options are separated by `,`.
    let extraCodeCompleteOptionsEnv = EnvOption("SK_EXTRA_CODE_COMPLETE_OPTIONS", type: String.self)

    // IssueManager params:
    /// Non-default path to the json file containing expected failures
    let expectedFailuresPathEnv = EnvOption("SK_XFAILS_PATH", type: String.self)
    /// Non-default path to write the results json file to
    let outputPathEnv = EnvOption("SK_STRESS_OUTPUT", type: String.self)
    /// The value of the 'config' field to use when suggesting entries to add to the expected
    /// failures json file to mark an unexpected failure as expected.
    let activeConfigEnv = EnvOption("SK_STRESS_ACTIVE_CONFIG", type: String.self)

    guard let swiftc = (try swiftcEnv.get(from: environment) ?? pathFromXcrun(for: "swiftc")) else {
      throw EnvOptionError.noFallback(key: swiftcEnv.key, target: "swiftc")
    }
    guard let stressTester = (try stressTesterEnv.get(from: environment) ?? defaultStressTesterPath) else {
      throw EnvOptionError.noFallback(key: stressTesterEnv.key, target: "sk-stress-test")
    }
    let ignoreIssues = try ignoreIssuesEnv.get(from: environment) ?? false
    let suppressOutput = try suppressOutputEnv.get(from: environment) ?? false
    let astBuildLimit = try astBuildLimitEnv.get(from: environment)
    let requestDurationsOutputFile = try requestDurationsOutputFileEnv.get(from: environment).map(URL.init(fileURLWithPath:))
    let rewriteModes = try rewriteModesEnv.get(from: environment) ?? [.none, .concurrent, .insideOut]
    let requestKinds = RequestKind.reduce(try requestKindsEnv.get(from: environment) ?? [.all])
    let conformingMethodTypes = try conformingMethodTypesEnv.get(from: environment)
    let maxJobs = try maxJobsEnv.get(from: environment)
    let dumpResponsesPath = try dumpResponsesPathEnv.get(from: environment)
    let extraCodeCompleteOptions = try extraCodeCompleteOptionsEnv.get(from: environment)

    var issueManager: IssueManager? = nil
    if let expectedFailuresPath = try expectedFailuresPathEnv.get(from: environment),
      let outputPath = try outputPathEnv.get(from: environment),
      let activeConfig = try activeConfigEnv.get(from: environment) {
      issueManager = IssueManager(
        activeConfig: activeConfig,
        expectedIssuesFile: URL(fileURLWithPath: expectedFailuresPath, isDirectory: false),
        resultsFile: URL(fileURLWithPath: outputPath, isDirectory: false),
        activeRequests: requestKinds
      )
    }

    let wrapper = SwiftCWrapper(swiftcArgs: Array(arguments.dropFirst()),
                                swiftcPath: swiftc,
                                stressTesterPath: stressTester,
                                astBuildLimit: astBuildLimit,
                                requestDurationsOutputFile: requestDurationsOutputFile,
                                rewriteModes: rewriteModes,
                                requestKinds: requestKinds,
                                conformingMethodTypes: conformingMethodTypes,
                                extraCodeCompleteOptions: extraCodeCompleteOptions?.split(separator: ",").map(String.init) ?? [],
                                ignoreIssues: ignoreIssues,
                                issueManager: issueManager,
                                maxJobs: maxJobs,
                                dumpResponsesPath: dumpResponsesPath,
                                failFast: true,
                                suppressOutput: suppressOutput)
    return try wrapper.run()
  }

  var defaultStressTesterPath: String? {
    let wrapperPath = URL(fileURLWithPath: arguments[0])
      .deletingLastPathComponent()
      .appendingPathComponent("sk-stress-test")
      .path

    guard FileManager.default.isExecutableFile(atPath: wrapperPath) else { return nil }
    return wrapperPath
  }
}

protocol EnvOptionKind: Equatable {
  init(value: String, fromKey: String) throws
}

struct EnvOption<T: EnvOptionKind> {
  let key: String
  let type: T.Type

  init(_ key: String, type: T.Type) {
    self.key = key
    self.type = type
  }

  func get(from environment: [String: String]) throws -> T? {
    guard let value = environment[key] else {
      return nil
    }
    return try type.init(value: value, fromKey: key)
  }
}

public enum EnvOptionError: Swift.Error, CustomStringConvertible {
  case typeMismatch(key: String, value: String, expectedType: Any.Type)
  case unknownValue(key: String, value: String, validValues: [CustomStringConvertible])
  case noFallback(key: String, target: String)

  public var description: String {
    switch self {
    case .typeMismatch(let key, let value, let expectedType):
      return "environment variable '\(key)' should have a value of type '\(expectedType)'; given '\(value)'"
    case .noFallback(let key, let target):
      return "couldn't locate \(target); please set environment variable \(key) to its path"
    case .unknownValue(let key, let value, let validValues):
      return "unknown value \(value) provided via environment variable \(key); should be one of: '\(validValues.map{ String(describing: $0)}.joined(separator: "', '"))'"
    }
  }
}

extension String: EnvOptionKind {
  init(value: String, fromKey: String) throws { self.init(value) }
}
extension Int: EnvOptionKind {
  init(value: String, fromKey key: String) throws {
    guard let converted = Int(value) else {
      throw EnvOptionError.typeMismatch(key: key, value: value, expectedType: Int.self)
    }
    self = converted
  }
}
extension Bool: EnvOptionKind {
  init(value: String, fromKey key: String) throws {
    switch value.lowercased() {
    case "true", "1":
      self = true
    case "false", "0":
      self = false
    default:
      throw EnvOptionError.typeMismatch(key: key, value: value, expectedType: Bool.self)
    }
  }
}
extension RewriteMode: EnvOptionKind {
  init(value: String, fromKey key: String) throws {
    guard let mode = RewriteMode.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) else {
      throw EnvOptionError.unknownValue(key: key, value: value, validValues: RewriteMode.allCases.map { $0.rawValue })
    }
    self = mode
  }
}

extension Array: EnvOptionKind where Element: EnvOptionKind {
  init(value: String, fromKey key: String) throws {
    self = try value.split(separator: " ").map {
      try Element.init(value: String($0), fromKey: key)
    }
  }
}

extension RequestKind: EnvOptionKind {
  init(value: String, fromKey key: String) throws {
    guard let kind = RequestKind.byName(value) else {
      throw EnvOptionError.unknownValue(key: key, value: value, validValues: RequestKind.allCases.map { $0.rawValue })
    }
    self = kind
  }
}
