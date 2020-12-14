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
import StressTester
import TestHelpers
import XCTest

class StressTesterToolTests: XCTestCase {
  var workspace: URL!
  var testFile: URL!
  var swiftcPath: String!

  func testCommandLine() {
    let valid: [String] = [testFile.path, "--", testFile.path]

    // No source file
    XCTAssertThrowsError(try StressTesterTool.parse([]))

    // No compiler args
    XCTAssertThrowsError(try StressTesterTool.parse([testFile.path]))

    // Compiler args missing file
    // FIXME: Add back in when validate is back to normal
    // XCTAssertThrowsError(try StressTesterTool.parse([testFile.path, "--", "anything"]))

    // Limit seed with no limit
    XCTAssertThrowsError(try StressTesterTool.parse(["--limit-seed 10"] + valid))

    // Limit and page with no seed
    XCTAssertThrowsError(try StressTesterTool.parse(["--limit 10 --page 1/4"] + valid))

    // Defaults
    StressTesterToolTests.assertParse(valid) { defaults in
      XCTAssertEqual(defaults.rewriteMode, .none)
      XCTAssertEqual(defaults.format, .humanReadable)
      XCTAssertEqual(defaults.limit, nil)
      XCTAssertEqual(defaults.limitSeed, nil)
      XCTAssertEqual(defaults.page, Page())
      XCTAssertEqual(defaults.requests, [.ide])
      XCTAssertEqual(defaults.dryRun, false)
      XCTAssertEqual(defaults.reportResponses, false)
      XCTAssertEqual(defaults.conformingMethodsTypeList, ["s:SQ", "s:SH"])
      // FIXME: Change to swiftcPath when validate is back to normal
      XCTAssertEqual(defaults.swiftc, nil)
      XCTAssertEqual(defaults.file, testFile)
      XCTAssertEqual(defaults.compilerArgs, [CompilerArg(testFile!.path)])
    }

    let allLong: [String] = [
      "--rewrite-mode", "basic",
      "--format", "json",
      "--limit", "1",
      "--limit-seed", "3",
      "--page", "2/5",
      "--request", "CursorInfo", "--request", "CODECOMPLETE",
      "--dry-run",
      "--report-responses",
      "--type-list-item", "foo", "--type-list-item", "bar",
      "--temp-dir", workspace.path,
      "--swiftc", swiftcPath
    ] + valid
    let allShort: [String] = [
      "-m", "basic",
      "-f", "json",
      "-l", "1",
      "--limit-seed", "3", // no short
      "-p", "2/5",
      "-r", "CursorInfo", "-r", "CODECOMPLETE",
      "-d",
      "--report-responses", // no short
      "-t", "foo", "-t", "bar",
      "--temp-dir", workspace.path, // no short
      "-s", swiftcPath
    ] + valid
    let assertValid = { [workspace, swiftcPath, testFile] (args: [String]) in
      StressTesterToolTests.assertParse(args) { tool in
        XCTAssertEqual(tool.rewriteMode, .basic)
        XCTAssertEqual(tool.format, .json)
        XCTAssertEqual(tool.limit, 1)
        XCTAssertEqual(tool.limitSeed, 3)
        XCTAssertEqual(tool.page, Page(2, of: 5))
        XCTAssertEqual(tool.requests, [.cursorInfo, .codeComplete])
        XCTAssertEqual(tool.dryRun, true)
        XCTAssertEqual(tool.reportResponses, true)
        XCTAssertEqual(tool.conformingMethodsTypeList, ["foo", "bar"])
        XCTAssertEqual(tool.tempDir, workspace)
        XCTAssertEqual(tool.swiftc, swiftcPath)
        XCTAssertEqual(tool.file, testFile!)
        XCTAssertEqual(tool.compilerArgs, [CompilerArg(testFile!.path)])
      }
    }
    assertValid(allLong)
    assertValid(allShort)

    // Unknown flag
    XCTAssertThrowsError(try StressTesterTool.parse(["--not-an-option"] + valid))

    // Missing
    XCTAssertThrowsError(try StressTesterTool.parse(["--format"] + valid))

    // Unknown values
    XCTAssertThrowsError(try StressTesterTool.parse(["--format", "blah"] + valid))
    XCTAssertThrowsError(try StressTesterTool.parse(["--request", "Unknown"] + valid))
  }

  func testDumpResponses() {
    var responses = [SourceKitResponseData]()
    let options = StressTesterOptions(requests: [.codeComplete],
                                      rewriteMode: .none,
                                      conformingMethodsTypeList: [],
                                      page: Page(),
                                      tempDir: workspace,
                                      responseHandler: { responseData in
                                        responses.append(responseData)
                                      })

    let tester = StressTester(options: options)
    XCTAssertNoThrow(try tester.run(swiftc: swiftcPath,
                                    compilerArgs: CompilerArgs(
                                      for: testFile,
                                      args: [CompilerArg(testFile.path)],
                                      tempDir: workspace)),
                     "no sourcekitd crashes in test program")
    XCTAssertFalse(responses.isEmpty, "produces responses")
    XCTAssertTrue(responses.allSatisfy { response in
      if case .codeComplete = response.request { return true }
      return false
    }, "request filter is respected")
    XCTAssertFalse(responses.allSatisfy { $0.results.isEmpty }, "responses have results")
  }

  func testModuleRequest() {
    let swiftc = ExecutableScript(
      at: workspace.appendingPathComponent("swiftc", isDirectory: false),
      exitCode: 0,recordInvocationIn:
        workspace.appendingPathComponent("invocation.txt", isDirectory: false))

    // All these args should be removed
    let args = ["-incremental", "-whole-module-optimization",
                "-num-threads", "2",
                "-output-file-map", "/none/here",
                testFile.path].map({ CompilerArg($0) })
    let options = StressTesterOptions(requests: [.testModule],
                                      rewriteMode: .none,
                                      conformingMethodsTypeList: [],
                                      page: Page(),
                                      tempDir: workspace)

    let tester = StressTester(options: options)
    // Expect interface request to fail since no module will be generated
    XCTAssertThrowsError(try tester.run(swiftc: swiftc.file.path,
                                        compilerArgs: CompilerArgs(
                                          for: testFile,
                                          args: args,
                                          tempDir: workspace)))

    let invocations = swiftc.retrieveInvocations()
    let expectedInvocation = "-Xfrontend -experimental-allow-module-with-compiler-errors -emit-module -module-name Test -emit-module-path \(workspace.appendingPathComponent("Test.swiftmodule").path) -"
    XCTAssertEqual(1, invocations.count)
    XCTAssertEqual(expectedInvocation, String(invocations[0]),
                  "incorrect args sent to swiftc")
  }

  override func setUp() {
    super.setUp()

    workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("StressTesterToolTests", isDirectory: true)

    try? FileManager.default.removeItem(at: workspace)
    try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)

    testFile = workspace
      .appendingPathComponent("test.swift")

    FileManager.default.createFile(atPath: testFile.path, contents: """
      func square(_ x: Int) -> Int {
        return x * x
      }
      print(square(9))
      """.data(using: .utf8))

    swiftcPath = pathFromXcrun(for: "swiftc")
  }

  override func tearDown() {
    super.tearDown()
    try? FileManager.default.removeItem(at: workspace)
  }

  private static func assertParse(_ args: [String],
                                  file: StaticString = #file, line: UInt = #line,
                                  closure: (StressTesterTool) throws -> Void) {
    do {
      let parsed = try StressTesterTool.parse(args)
      try closure(parsed)
    } catch {
      let message = StressTesterTool.message(for: error)
      XCTFail("\"\(message)\" — \(error)", file: (file), line: line)
    }
  }
}
