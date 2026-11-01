import AppKit
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: \(message)\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 7 else {
    fail("usage: updater-helper-process-test.swift HELPER STAGED_APP TARGET_APP TAG READY_PATH LOG_PATH")
}

let helper = CommandLine.arguments[1]
let stagedApp = CommandLine.arguments[2]
let targetApp = CommandLine.arguments[3]
let expectedTag = CommandLine.arguments[4]
let readyPath = CommandLine.arguments[5]
let logPath = CommandLine.arguments[6]
let bundleIdentifier = "com.intuition.shenzhenfiles"
let normalizedTarget = URL(fileURLWithPath: targetApp)
    .standardizedFileURL.resolvingSymlinksInPath().path

private func exactTargetApplication() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first { app in
            guard !app.isTerminated, let bundleURL = app.bundleURL else { return false }
            return bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == normalizedTarget
        }
}

private func terminateExactTargetApplication() {
    guard let app = exactTargetApplication() else { return }
    app.terminate()
    let deadline = Date().addingTimeInterval(5)
    while !app.isTerminated && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if !app.isTerminated {
        app.forceTerminate()
    }
}

let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    .filter { !$0.isTerminated }
guard alreadyRunning.isEmpty else {
    fail("Shenzhen Files is already running; quit it before exercising the updater helper")
}

FileManager.default.createFile(atPath: logPath, contents: nil)
guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
    fail("could not open helper log at \(logPath)")
}
defer { try? logHandle.close() }

let task = Process()
task.executableURL = URL(fileURLWithPath: helper)
task.arguments = ["--post-update", stagedApp, targetApp, expectedTag, readyPath]
task.standardOutput = logHandle
task.standardError = logHandle

do {
    try task.run()
} catch {
    fail("Foundation Process could not launch the updater helper: \(error)")
}

let readyDeadline = Date().addingTimeInterval(15)
var observedReady = false
while Date() < readyDeadline {
    if FileManager.default.fileExists(atPath: readyPath) {
        observedReady = true
        break
    }
    if !task.isRunning {
        break
    }
    Thread.sleep(forTimeInterval: 0.01)
}

guard observedReady else {
    task.terminate()
    task.waitUntilExit()
    terminateExactTargetApplication()
    fail("updater helper exited or timed out before its readiness marker was observed")
}
print("READY_MARKER=observed")

let exitDeadline = Date().addingTimeInterval(35)
while task.isRunning && Date() < exitDeadline {
    Thread.sleep(forTimeInterval: 0.05)
}
if task.isRunning {
    task.terminate()
    task.waitUntilExit()
    terminateExactTargetApplication()
    fail("updater helper did not finish within 35 seconds")
}
if task.terminationStatus != 0 {
    terminateExactTargetApplication()
    fail("updater helper exited with status \(task.terminationStatus)")
}
print("HELPER_EXIT=0")

let relaunched = exactTargetApplication()
guard let relaunched else {
    fail("helper exited successfully but the exact updated bundle was not running")
}
print("EXACT_RELAUNCH=observed")

/// The environment a process of ours started with (KERN_PROCARGS2: argc, the executable path, argv, then the
/// environment), or nil when it cannot be read.
private func environment(of pid: pid_t) -> [String: String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var strings: [String] = []
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }  // the executable path
    while index < size {
        while index < size, buffer[index] == 0 { index += 1 }  // its padding
        guard index < size else { break }
        let begin = index
        while index < size, buffer[index] != 0 { index += 1 }
        strings.append(String(decoding: buffer[begin..<index], as: UTF8.self))
        if strings.count > argc, strings.last!.isEmpty { break }
    }
    var environment: [String: String] = [:]
    for entry in strings.dropFirst(argc) {
        guard let equals = entry.firstIndex(of: "=") else { break }
        environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return environment
}

// The test runs the helper with a home of its own; LaunchServices starts the relaunched app with the session's
// environment unless the helper carries the home over. With the person's home, the test copy would serve their
// Friends.
let testHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
guard let relaunchedEnvironment = environment(of: relaunched.processIdentifier) else {
    terminateExactTargetApplication()
    fail("could not read the relaunched app's environment")
}
guard relaunchedEnvironment["HOME"] == testHome,
      relaunchedEnvironment["CFFIXED_USER_HOME"] == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
else {
    terminateExactTargetApplication()
    fail("the relaunched app runs with HOME=\(relaunchedEnvironment["HOME"] ?? "(unset)"), not the test's \(testHome)")
}
print("RELAUNCH_HOME=test")

terminateExactTargetApplication()
