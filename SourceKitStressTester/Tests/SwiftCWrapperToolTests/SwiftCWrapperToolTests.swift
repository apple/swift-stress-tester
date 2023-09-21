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

import Common
import SwiftCWrapper
import TestHelpers
import XCTest

class SwiftCWrapperToolTests: XCTestCase {
  var workspace: URL!

  var testStressTesterFile: URL!
  var testSwiftCFile: URL!
  var testSwiftCWrapperFile: URL!
  var testFile: URL!
  var testInvocationFile: URL!
  var errorJson: String!

  func testStatus() throws {
    typealias WrapperSpec = (compilerExit: Int32, stressTesterExit: Int32, expectedExit: Int32)
    let specs: [WrapperSpec] = [
      (compilerExit: 2, stressTesterExit: 1, expectedExit: 2),
      (compilerExit: 0, stressTesterExit: 1, expectedExit: 1),
      (compilerExit: 0, stressTesterExit: 0, expectedExit: 0),
      (compilerExit: 0, stressTesterExit: 6, expectedExit: 1)
    ]

    let environment: [String: String] = ["SK_STRESS_SWIFTC": testSwiftCFile.path]
    try specs.forEach { spec in
      let stdout = spec.stressTesterExit != 0 ? errorJson : nil

      ExecutableScript(at: testStressTesterFile,
                       exitCode: spec.stressTesterExit, stdout: stdout)
      ExecutableScript(at: testSwiftCFile,
                       exitCode: spec.compilerExit)

      let singleFileArgs: [String] = [testSwiftCWrapperFile.path, testFile.path]
      let wrapper = SwiftCWrapperTool(arguments: singleFileArgs, environment: environment)
      XCTAssertNoThrow(XCTAssertEqual(try wrapper.run(), spec.expectedExit))
    }
  }

  func testSilent() throws {
    typealias WrapperSpec = (compilerExit: Int32, stressTesterExit: Int32, expectedExit: Int32, silent: Bool)
    let specs: [WrapperSpec] = [
      (compilerExit: 2, stressTesterExit: 1, expectedExit: 2, silent: false),
      (compilerExit: 2, stressTesterExit: 1, expectedExit: 2, silent: true),
      (compilerExit: 0, stressTesterExit: 1, expectedExit: 1, silent: false),
      (compilerExit: 0, stressTesterExit: 1, expectedExit: 0, silent: true),
      (compilerExit: 0, stressTesterExit: 0, expectedExit: 0, silent: true),
      (compilerExit: 0, stressTesterExit: 0, expectedExit: 0, silent: false)
    ]

    let environment: [String: String] = ["SK_STRESS_SWIFTC": testSwiftCFile.path]
    try specs.forEach { spec in
      let stdout = spec.stressTesterExit != 0 ? errorJson : nil

      ExecutableScript(at: testStressTesterFile,
                       exitCode: spec.stressTesterExit, stdout: stdout)
      ExecutableScript(at: testSwiftCFile, exitCode: spec.compilerExit)

      let singleFileArgs: [String] = [testSwiftCWrapperFile.path, testFile.path]
      let environment = environment.merging(["SK_STRESS_SILENT": String(spec.silent)]) { _, new in new }
      let wrapper = SwiftCWrapperTool(arguments: singleFileArgs, environment: environment)
      XCTAssertNoThrow(XCTAssertEqual(try wrapper.run(), spec.expectedExit))
    }
  }

  func testStressTesterOperationQueue() throws {
    try XCTSkipIf(true, "Failing non-deterministically. Disabling until we have time to investigate - rdar://100970606")
    class TestOperation: Operation {
      var waitCount: Int

      init(waitCount: Int) {
        self.waitCount = waitCount
      }

      override func main() {
        while !isCancelled, waitCount > 0 {
          usleep(100)
          waitCount -= 1
        }
      }
    }

    let first = TestOperation(waitCount: 0)
    let second = TestOperation(waitCount: 10)
    let third = TestOperation(waitCount: 20)
    let fourth = TestOperation(waitCount: 30)

    StressTesterOperationQueue(operations: [first, second, third, fourth], maxWorkers: 2, completionHandler: { _, finishedOp, _, _ in
      // cancel later operations when the second operation completes
      return finishedOp !== second
    }).waitUntilFinished()

    XCTAssertFalse(first.isCancelled, "first was cancelled")
    XCTAssertFalse(second.isCancelled, "second was cancelled")
    XCTAssertTrue(third.isCancelled, "third wasn't cancelled")
    XCTAssertTrue(fourth.isCancelled, "fourth wasn't cancelled")
  }

  func testSwiftFileHeuristic() {
    func getSwiftFiles(from list: [String]) -> [String] {
      let wrapper: SwiftCWrapper = SwiftCWrapper(
        swiftcArgs: list, swiftcPath: "", stressTesterPath: "",
        astBuildLimit: nil, requestDurationsOutputFile: nil,
        rewriteModes: [], requestKinds: Set(),
        conformingMethodTypes: nil, extraCodeCompleteOptions: [], ignoreIssues: false, issueManager: nil,
        maxJobs: nil, dumpResponsesPath: nil, failFast: false,
        suppressOutput: false)
      return wrapper.swiftFiles.map { (file, _) in file }
    }
    let dirPath = workspace.appendingPathComponent("ConfusinglyNamedDir.swift", isDirectory: true).path
    let blacklistedDir = workspace.appendingPathComponent("SourcePackages/checkouts/SomeSubRepo", isDirectory: true).path
    let blacklistedFile = workspace.appendingPathComponent("SourcePackages/checkouts/SomeSubRepo/file.swift", isDirectory: false).path
    try! FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: false, attributes: nil)
    try! FileManager.default.createDirectory(atPath: blacklistedDir, withIntermediateDirectories: true, attributes: nil)
    guard FileManager.default.createFile(atPath: blacklistedFile, contents: nil) else { fatalError() }

    XCTAssertEqual(getSwiftFiles(from: [testFile.path,
                                        "/made-up.swift",
                                        "unrelated/path",
                                        blacklistedFile,
                                        dirPath]),
                   [testFile.path])
  }

  func testEnvParsing() {
    ExecutableScript(at: testSwiftCFile, exitCode: 0)
    let tester = ExecutableScript(at: testStressTesterFile, exitCode: 0,
                                  recordInvocationIn: testInvocationFile)

    let defaultEnvironment: [String: String] = [
      "SK_STRESS_SWIFTC": testSwiftCFile.path,
      "SK_STRESS_TEST": testStressTesterFile.path,
    ]

    // Check the produced invocations with default settings
    let singleFileArgs: [String] = [testSwiftCWrapperFile.path, testFile.path]
    XCTAssertNoThrow(XCTAssertEqual(try SwiftCWrapperTool(arguments: singleFileArgs, environment: defaultEnvironment).run(), 0))

    let defaultInvocations = tester.retrieveInvocations()
    XCTAssertEqual(defaultInvocations.count, 3)
    assertInvocationsMatch(invocations: defaultInvocations,
                           rewriteModes: [.none, .concurrent, .insideOut])

    // Check custom request kinds and rewrite modes are propagated through correctly
    let customRequestKinds = [RequestKind.cursorInfo, RequestKind.rangeInfo]
    let customEnvironment = defaultEnvironment.merging([
      "SK_STRESS_REQUESTS": customRequestKinds
        .map({ "\($0.rawValue)" }).joined(separator: " "),
      "SK_STRESS_REWRITE_MODES": [RewriteMode.basic, RewriteMode.insideOut]
        .map({ "\($0.rawValue)" }).joined(separator: " "),
      "SK_STRESS_CONFORMING_METHOD_TYPES": "s:SomeUSR s:OtherUSR s:ThirdUSR"
    ], uniquingKeysWith: { _, new in new })
    XCTAssertNoThrow(XCTAssertEqual(try SwiftCWrapperTool(arguments: singleFileArgs, environment: customEnvironment).run(), 0))

    let customInvocations = tester.retrieveInvocations()
    XCTAssertEqual(customInvocations.count, 2)
    assertInvocationsMatch(invocations: customInvocations,
                           rewriteModes: [.basic, .insideOut],
                           requestKinds: customRequestKinds)
  }

  func testIssueManager() {
    let xfail = ExpectedIssue(
      applicableConfigs: ["main"], issueUrl: "<issue-url>",
      path: "*/foo/bar.swift", modification: "unmodified",
      issueDetail: .editorReplaceText(offset: 42, length: 0, text: nil)
    )

    let xfail2 = ExpectedIssue(
      applicableConfigs: ["main"], issueUrl: "<issue-url",
      path: "*/foo/bar.swift", modification: "unmodified",
      issueDetail: .stressTesterCrash(status: 2, arguments: "*concurrent*"))

    let document1 = DocumentInfo(path: "/baz/foo/bar.swift", modification: nil)
    let request1 = RequestInfo.editorReplaceText(document: document1, offset: 42, length: 0, text: ".")
    let error1 = SourceKitError.crashed(request: request1)
    let issue1 = StressTesterIssue.failed(sourceKitError: error1, arguments: "")

    let request2 = RequestInfo.editorReplaceText(document: document1, offset: 42, length: 2, text: "hello")
    let error2 = SourceKitError.crashed(request: request2)
    let issue2 = StressTesterIssue.failed(sourceKitError: error2, arguments: "")

    let document2 = DocumentInfo(path: "/baz/bar.swift", modification: nil)
    let request3 = RequestInfo.editorReplaceText(document: document2, offset: 42, length: 0, text: ".")
    let error3 = SourceKitError.crashed(request: request3)
    let issue3 = StressTesterIssue.failed(sourceKitError: error3, arguments: "")

    let error4 = SourceKitError.failed(.errorResponse, request: request1, response: "foo")
    let issue4 = StressTesterIssue.failed(sourceKitError: error4, arguments: "")

    let issue5 = StressTesterIssue.errored(status: 2, file: "/bob/foo/bar.swift",
                                          arguments: "--rewrite-mode concurrent /bob/foo/bar.swift -- /bob/foo/bar.swift")
    let issue6 = StressTesterIssue.errored(status: 2,
                                            file: "/bob/foo/bar.swift",
                                            arguments: "--rewrite-mode basic /bob/foo/bar.swift -- /bob/foo/bar.swift")

    XCTAssertTrue(xfail.matches(issue1))
    XCTAssertFalse(xfail.matches(issue2))
    XCTAssertFalse(xfail.matches(issue3))
    XCTAssertTrue(xfail.matches(issue4))
    XCTAssertTrue(xfail2.matches(issue5))
    XCTAssertFalse(xfail2.matches(issue6))
  }

  override func setUp() {
    super.setUp()

    workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("StressTesterToolTests", isDirectory: true)

    try? FileManager.default.removeItem(at: workspace)
    try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)

    testSwiftCWrapperFile = workspace
      .appendingPathComponent("sk-swiftc-wrapper", isDirectory: false)
    testSwiftCFile = workspace
      .appendingPathComponent("swiftc", isDirectory: false)
    testStressTesterFile = workspace
      .appendingPathComponent("sk-stress-test", isDirectory: false)
    testFile = workspace
      .appendingPathComponent("test.swift", isDirectory: false)
    testInvocationFile = workspace
      .appendingPathComponent("invocations.txt", isDirectory: false)
    errorJson = """
      {"message": "detected", "error": {\
        "error": "timedOut",\
        "request": {\
          "document": {"path":"\(testFile.path)"},\
          "offset": 5,\
          "args": ["\(testFile.path)"],\
          "request": "cursorInfo"\
        }\
      }}
      """

    FileManager.default.createFile(atPath: testFile.path, contents: """
      func square(_ x: Int) -> Int {
        return x * x
      }
      print(square(9))
      """.data(using: .utf8))
  }

  override func tearDown() {
    super.tearDown()
    try? FileManager.default.removeItem(at: workspace)
  }

  private func assertInvocationsMatch(invocations: [Substring],
                                      rewriteModes: [RewriteMode],
                                      requestKinds: [RequestKind] = RequestKind.allRequests) {
    for invocation in invocations {
      XCTAssertTrue(invocation.contains("--format json"),
                    "Missing json format in '\(invocation)'")
      XCTAssertTrue(invocation.contains("--page 1/1"),
                    "Missing page in '\(invocation)'")

      var foundModes = [RewriteMode]()
      for rewriteMode in RewriteMode.allCases {
        if invocation.contains("--rewrite-mode \(rewriteMode)") {
          foundModes.append(rewriteMode)
        }
      }
      XCTAssertEqual(foundModes.count, 1,
                     "Found multiple rewrite modes \(foundModes) in '\(invocation)'")
      XCTAssertTrue(rewriteModes.contains(foundModes[0]),
                    "Expected a rewrite mode matching \(rewriteModes) in '\(invocation)'")

      var foundRequests = [RequestKind]()
      for request in RequestKind.allCases {
        if invocation.contains("--request \(request)") {
          foundRequests.append(request)
        }
      }
      XCTAssertTrue(Set(foundRequests)
                      .intersection(requestKinds).count == requestKinds.count,
                    "Expected only request kinds \(requestKinds) in '\(invocation)'")

      XCTAssertTrue(invocation.contains("--swiftc \(testSwiftCFile.path)"),
                    "Incorrect swiftc path in '\(invocation)'")
      XCTAssertTrue(invocation.contains("\(testFile.path) -- \(testFile.path)"),
                    "Incorrect file paths in '\(invocation)'")
    }
  }
}
