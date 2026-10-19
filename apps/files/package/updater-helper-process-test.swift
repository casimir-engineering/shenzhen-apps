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

terminateExactTargetApplication()
