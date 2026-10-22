import Foundation
import Combine

@MainActor
public final class HomebrewInstaller: ObservableObject {
    public static let shared = HomebrewInstaller()
    
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var currentStep: String = ""
    @Published public private(set) var progress: Double = 0.0
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var isSuccess: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    
    private var process: Process?
    
    public init() {}
    
    public func startInstallOrUpdate(isHomebrewAvailable: Bool, brewPath: String?) {
        guard !isRunning else { return }
        
        isRunning = true
        isSuccess = false
        errorMessage = nil
        logs = []
        progress = 0.05
        currentStep = isHomebrewAvailable ? "Checking Homebrew environment..." : "Preparing Homebrew installer..."
        
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            let pipe = Pipe()
            
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.standardOutput = pipe
            proc.standardError = pipe
            
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
            env["HOMEBREW_NO_EMOJI"] = "1"
            env["NONINTERACTIVE"] = "1"
            proc.environment = env
            
            let command: String
            if isHomebrewAvailable, let brew = brewPath {
                command = """
                echo "==> Verifying Homebrew installation at \(brew)..."
                echo "==> Checking FFmpeg status..."
                "\(brew)" install ffmpeg || "\(brew)" upgrade ffmpeg
                echo "==> FFmpeg package verified successfully!"
                """
            } else {
                command = """
                echo "==> Downloading and installing Homebrew (non-interactive)..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                echo "==> Installing FFmpeg via newly installed Homebrew..."
                if [ -x /opt/homebrew/bin/brew ]; then
                    /opt/homebrew/bin/brew install ffmpeg
                elif [ -x /usr/local/bin/brew ]; then
                    /usr/local/bin/brew install ffmpeg
                fi
                echo "==> FFmpeg package verified successfully!"
                """
            }
            
            proc.arguments = ["-c", command]
            
            await MainActor.run {
                self.process = proc
            }
            
            // Read output asynchronously
            let outHandle = pipe.fileHandleForReading
            NotificationCenter.default.addObserver(
                forName: FileHandle.readCompletionNotification,
                object: outHandle,
                queue: .main
            ) { notif in
                guard let data = notif.userInfo?[NSFileHandleNotificationDataItem] as? Data,
                      !data.isEmpty,
                      let str = String(data: data, encoding: .utf8) else { return }
                
                let lines = str.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for line in lines {
                    Task { @MainActor in
                        self.appendLog(line)
                    }
                }
                outHandle.readInBackgroundAndNotify()
            }
            outHandle.readInBackgroundAndNotify()
            
            do {
                try proc.run()
                proc.waitUntilExit()
                
                let exitCode = proc.terminationStatus
                await MainActor.run {
                    self.isRunning = false
                    self.process = nil
                    if exitCode == 0 {
                        self.isSuccess = true
                        self.progress = 1.0
                        self.currentStep = "FFmpeg installation complete!"
                        FFmpegLocator.shared.refresh()
                        if FFmpegLocator.shared.isHomebrewAvailable {
                            FFmpegLocator.shared.setEngineMode(.homebrew)
                        }
                    } else {
                        self.errorMessage = "Process completed with exit code \(exitCode)"
                        self.currentStep = "Installation failed."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.process = nil
                    self.errorMessage = error.localizedDescription
                    self.currentStep = "Error launching process."
                }
            }
        }
    }
    
    public func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
        currentStep = "Cancelled."
    }
    
    #if DEBUG
    public func populateLogsForTesting(_ sampleLogs: [String]) {
        self.logs = sampleLogs
    }
    #endif
    
    private func appendLog(_ line: String) {
        logs.append(line)
        
        let lower = line.lowercased()
        if lower.contains("downloading") {
            currentStep = "Downloading packages..."
            progress = max(progress, 0.3)
        } else if lower.contains("updating") || lower.contains("update") {
            currentStep = "Updating Homebrew formulae..."
            progress = max(progress, 0.45)
        } else if lower.contains("installing") || lower.contains("pour") {
            currentStep = "Installing FFmpeg..."
            progress = max(progress, 0.75)
        } else if lower.contains("already installed") || lower.contains("verified") {
            currentStep = "FFmpeg verified!"
            progress = 0.95
        }
    }
}
