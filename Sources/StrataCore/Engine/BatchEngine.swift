import Foundation
import SwiftUI

@MainActor
public final class BatchEngine: ObservableObject {
    public static let shared = BatchEngine()
    
    @Published public var items: [BatchItem] = []
    @Published public var isRunning: Bool = false
    @Published public var currentItemIndex: Int? = nil
    
    // Batch Presets
    @Published public var defaultContainer: ContainerFormat = .mp4
    @Published public var defaultStripMetadata: Bool = true
    @Published public var defaultFastStart: Bool = true
    @Published public var defaultAudioPreset: BatchAudioPreset = .passthrough
    @Published public var defaultSubtitlePreset: BatchSubtitlePreset = .keepAll
    @Published public var customOutputFolder: URL? = nil
    
    // Status & Notifications
    @Published public var errorMessage: String? = nil
    @Published public var showSuccessToast: Bool = false
    @Published public var successMessage: String? = nil
    
    private var engineTask: Task<Void, Never>?
    private var currentRemuxEngine: RemuxEngine?
    
    public init() {}
    
    public var completedCount: Int {
        items.filter {
            if case .completed = $0.status { return true }
            return false
        }.count
    }
    
    public var pendingCount: Int {
        items.filter {
            if case .pending = $0.status { return true }
            return false
        }.count
    }
    
    public func addFiles(_ urls: [URL]) {
        var unsupportedFiles: [URL] = []
        var validURLs: [URL] = []
        
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if !ProbePipeline.commonMediaExtensions.contains(ext) {
                unsupportedFiles.append(url)
            } else {
                validURLs.append(url)
            }
        }
        
        if !unsupportedFiles.isEmpty {
            if unsupportedFiles.count == 1 {
                let ext = unsupportedFiles[0].pathExtension.uppercased()
                if ext.isEmpty {
                    self.errorMessage = "Unsupported File Format: The selected file is not a supported media file."
                } else {
                    self.errorMessage = "Unsupported File Format: '.\(ext)' is not a supported media file. Strata works with video, audio, and subtitle files."
                }
            } else {
                let exts = Array(Set(unsupportedFiles.map { "'.\($0.pathExtension.uppercased())'" })).sorted().joined(separator: ", ")
                self.errorMessage = "Unsupported File Formats: \(exts) are not supported media files and were not added."
            }
        }
        
        for url in validURLs {
            // Avoid duplicate source URL in queue if already pending
            if items.contains(where: { $0.sourceURL == url && $0.status == .pending }) {
                continue
            }
            
            let item = BatchItem(
                sourceURL: url,
                targetContainer: defaultContainer,
                stripMetadata: defaultStripMetadata,
                fastStart: defaultFastStart,
                isCustomSingleItem: false,
                audioPreset: defaultAudioPreset,
                subtitlePreset: defaultSubtitlePreset,
                status: .probing
            )
            items.append(item)
            
            let itemId = item.id
            Task {
                do {
                    let media = try await ProbePipeline.shared.probe(fileURL: url)
                    await MainActor.run {
                        if let idx = self.items.firstIndex(where: { $0.id == itemId }) {
                            self.items[idx].mediaFile = media
                            self.items[idx].status = .ready
                            self.configurePresets(for: idx)
                        }
                    }
                } catch {
                    await MainActor.run {
                        if let idx = self.items.firstIndex(where: { $0.id == itemId }) {
                            self.items[idx].status = .failed(message: error.localizedDescription)
                            self.items[idx].errorMessage = error.localizedDescription
                            self.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
    
    public func removeItems(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }
    
    public func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
    }
    
    public func clearCompleted() {
        items.removeAll {
            if case .completed = $0.status { return true }
            return false
        }
    }
    
    public func clearAll() {
        cancel()
        items.removeAll()
        errorMessage = nil
        showSuccessToast = false
        successMessage = nil
    }
    
    /// Enqueues a file with custom track selections, audio transcoding options,
    /// imported tracks, destination URL, metadata strip, and FastStart preferences.
    public func enqueueCustomItem(
        media: MediaFile,
        targetContainer: ContainerFormat,
        outputURL: URL?,
        stripMetadata: Bool,
        fastStart: Bool
    ) {
        let item = BatchItem(
            sourceURL: media.url,
            mediaFile: media,
            targetContainer: targetContainer,
            outputURL: outputURL,
            stripMetadata: stripMetadata,
            fastStart: fastStart,
            isCustomSingleItem: true,
            audioPreset: .passthrough,
            subtitlePreset: .keepAll,
            status: .ready
        )
        items.append(item)
    }
    
    private func configurePresets(for index: Int) {
        guard index < items.count else { return }
        // Preserve custom configuration from Single Mode without applying batch presets
        if items[index].isCustomSingleItem { return }
        guard var media = items[index].mediaFile else { return }
        let item = items[index]
        
        // Configure audio according to preset
        for i in 0..<media.tracks.count {
            if media.tracks[i].mediaType == .audio {
                switch item.audioPreset {
                case .passthrough:
                    media.tracks[i].action = .copy
                case .transcodeNonAAC:
                    if media.tracks[i].codecName.lowercased().contains("aac") {
                        media.tracks[i].action = .copy
                    } else {
                        media.tracks[i].action = .transcodeAAC_Stereo
                    }
                case .alwaysAACStereo:
                    media.tracks[i].action = .transcodeAAC_Stereo
                case .alwaysAAC51:
                    media.tracks[i].action = .transcodeAAC_51
                }
            } else if media.tracks[i].mediaType == .subtitle {
                switch item.subtitlePreset {
                case .keepAll:
                    media.tracks[i].isSelected = true
                case .keepFirst:
                    let subTracks = media.tracks.filter { $0.mediaType == .subtitle }
                    media.tracks[i].isSelected = (media.tracks[i].id == subTracks.first?.id)
                case .stripAll:
                    media.tracks[i].isSelected = false
                }
            }
        }
        items[index].mediaFile = media
    }
    
    public func startQueue() {
        guard !isRunning else { return }
        isRunning = true
        
        engineTask = Task {
            for index in 0..<self.items.count {
                if Task.isCancelled { break }
                
                let item = self.items[index]
                guard item.status == .ready || item.status == .pending else { continue }
                
                await MainActor.run {
                    self.currentItemIndex = index
                    self.items[index].status = .processing(progress: 0.0, speed: "Starting...")
                }
                
                // Ensure probed
                var mediaFile = item.mediaFile
                if mediaFile == nil {
                    do {
                        mediaFile = try await ProbePipeline.shared.probe(fileURL: item.sourceURL)
                        let resolvedMedia = mediaFile
                        await MainActor.run {
                            self.items[index].mediaFile = resolvedMedia
                            self.configurePresets(for: index)
                        }
                    } catch {
                        await MainActor.run {
                            self.items[index].status = .failed(message: error.localizedDescription)
                        }
                        continue
                    }
                }
                
                guard let validMedia = self.items[index].mediaFile else { continue }
                
                // Determine output destination
                let outURL: URL
                if let custom = item.outputURL {
                    outURL = custom
                } else if let customFolder = self.customOutputFolder {
                    let baseName = item.sourceURL.deletingPathExtension().lastPathComponent
                    outURL = customFolder.appendingPathComponent("\(baseName).\(item.targetContainer.fileExtension)")
                } else {
                    let folder = item.sourceURL.deletingLastPathComponent()
                    let baseName = item.sourceURL.deletingPathExtension().lastPathComponent
                    let filename = "\(baseName).remuxed.\(item.targetContainer.fileExtension)"
                    outURL = folder.appendingPathComponent(filename)
                }
                
                let options = RemuxOptions(
                    targetContainer: item.targetContainer,
                    outputURL: outURL,
                    stripAllMetadata: item.stripMetadata,
                    stripChapters: false,
                    fastStart: item.fastStart && item.targetContainer.supportsFastStart
                )
                
                let engine = RemuxEngine()
                self.currentRemuxEngine = engine
                let startTime = Date()
                
                let progressStream = await engine.run(file: validMedia, options: options)
                
                for await update in progressStream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.items[index].progress = update.progress
                        self.items[index].speed = update.speed
                        self.items[index].status = .processing(progress: update.progress, speed: update.speed)
                    }
                }
                
                let elapsed = Date().timeIntervalSince(startTime)
                await MainActor.run {
                    if self.items[index].progress >= 0.99 {
                        self.items[index].status = .completed(elapsedTime: elapsed)
                    } else if case .processing = self.items[index].status {
                        self.items[index].status = .completed(elapsedTime: elapsed)
                    }
                }
            }
            
            await MainActor.run {
                self.isRunning = false
                self.currentItemIndex = nil
                self.currentRemuxEngine = nil
                let done = self.completedCount
                if done > 0 {
                    self.successMessage = "Batch Export Complete: \(done) item\(done == 1 ? "" : "s") processed"
                    self.showSuccessToast = true
                }
            }
        }
    }
    
    public func cancel() {
        engineTask?.cancel()
        engineTask = nil
        Task {
            await currentRemuxEngine?.cancel()
            await MainActor.run {
                self.isRunning = false
                if let idx = self.currentItemIndex, idx < self.items.count {
                    if case .processing = self.items[idx].status {
                        self.items[idx].status = .ready
                    }
                }
                self.currentItemIndex = nil
                self.currentRemuxEngine = nil
            }
        }
    }
}
