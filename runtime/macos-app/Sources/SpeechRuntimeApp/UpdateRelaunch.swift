import Foundation

/// Schedules the GUI relaunch after an update install.
///
/// The previous implementation ran `/usr/bin/open -n` before `NSApp.terminate`,
/// so the new instance could start while the old one was still registered and
/// hit the duplicate-instance guard in AppMain, silently quitting. The helper
/// process below waits (bounded) for the current app to exit, and only then
/// launches the explicit bundle path, so the old instance must terminate first.
enum UpdateRelaunch {
    /// Longest the helper waits for the current app to exit before giving up.
    static let maxWaitSeconds: TimeInterval = 30
    /// Interval between exit polls in the helper.
    static let pollSeconds: TimeInterval = 0.2

    enum Result: Equatable {
        /// The helper process was spawned successfully; it will open the app
        /// after the current PID exits. Safe to terminate now.
        case scheduled
        /// The helper could not be spawned; the app must stay running and
        /// report the error to the user.
        case failed
    }

    /// Spawns the relaunch helper for the given bundle path.
    ///
    /// `currentPID` is waited on by the helper before it opens `bundlePath`.
    /// The helper is a detached shell with null stdio so it survives the GUI
    /// process being replaced. `bundlePath` is passed as a positional
    /// argument — no string interpolation of the path into the script body.
    static func schedule(bundlePath: String, currentPID: pid_t) -> Result {
        scheduleCore(bundlePath: bundlePath, currentPID: currentPID, openPath: "/usr/bin/open",
                     pollSeconds: pollSeconds, maxWaitSeconds: maxWaitSeconds)
    }

    /// Test seam: lets tests point `open` at a harmless sink script and use
    /// short poll/wait windows. Production path always uses /usr/bin/open.
    static func scheduleForTesting(bundlePath: String, currentPID: pid_t, openPath: String,
                                   pollSeconds: Double, maxWaitSeconds: Double) -> Result {
        scheduleCore(bundlePath: bundlePath, currentPID: currentPID, openPath: openPath,
                     pollSeconds: pollSeconds, maxWaitSeconds: maxWaitSeconds)
    }

    private static func scheduleCore(bundlePath: String, currentPID: pid_t, openPath: String,
                                     pollSeconds: Double, maxWaitSeconds: Double) -> Result {
        guard currentPID > 0, !bundlePath.isEmpty, !openPath.isEmpty, pollSeconds > 0 else { return .failed }
        let maxPolls = Int(maxWaitSeconds / pollSeconds)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "n=0; while kill -0 \"$1\" 2>/dev/null; do "
                + "n=$((n+1)); [ $n -gt \(maxPolls) ] && exit 1; "
                + "sleep \(pollSeconds); "
                + "done; exec \"$3\" -n \"$2\"",
            "update-relaunch-helper",
            String(currentPID),
            bundlePath,
            openPath,
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            return .scheduled
        } catch {
            return .failed
        }
    }
}
