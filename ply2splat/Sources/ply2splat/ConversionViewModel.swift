import Foundation
import Combine
import UniformTypeIdentifiers
import AppKit

struct LogMessage: Identifiable {
    let id = UUID()
    let text: String
}

class ConversionViewModel: ObservableObject {
    @Published var inputPath: String = ""
    @Published var outputDirectory: String = ""
    
    // File Stats
    @Published var splatCount: Int = 0
    @Published var fileSHDegree: Int = 0
    @Published var fileSizeMB: Double = 0
    @Published var estimatedVRAM: Double = 0
    
    // Settings — hardcoded
    let exportSplat: Bool = true
    let exportKSplat: Bool = false
    let exportSPZ: Bool = false
    let useMetal: Bool = true
    let compressionLevel: Int = 1

    // User-adjustable
    @Published var shDegreeIndex: Int = 0    // 0:Auto, 1:0, 2:1, 3:2, 4:3
    @Published var splatPercentIndex: Int = 3 // 0:40%, 1:60%, 2:80%, 3:100%
    
    @Published var isConverting: Bool = false
    @Published var progress: Double = 0.0
    @Published var logMessages: [LogMessage] = []
    
    func log(_ message: String) {
        DispatchQueue.main.async {
            self.logMessages.append(LogMessage(text: message))
        }
    }
    
    func clearLogs() {
        self.logMessages.removeAll()
    }
    
    func copyLogsToClipboard() {
        let allLogs = logMessages.map { $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allLogs, forType: .string)
    }
    
    func updateOutputDirectory(from inputURL: URL) {
        let basename = inputURL.deletingPathExtension().lastPathComponent
        let newDir = inputURL.deletingLastPathComponent().appendingPathComponent("\(basename)_converted")
        self.outputDirectory = newDir.path
        analyzeFile(at: inputURL)
    }
    
    private func analyzeFile(at url: URL) {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let parser = PLYParser()
            let header = try parser.getHeader(data: data)
            DispatchQueue.main.async {
                self.splatCount = header.vertexCount
                self.fileSHDegree = header.shDegree
                self.fileSizeMB = Double(data.count) / (1024 * 1024)
                self.estimatedVRAM = Double(header.vertexCount) * 0.0003
            }
        } catch {
            log("Analysis error: \(error.localizedDescription)")
        }
    }
    
    func selectInputFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "ply"),
        ].compactMap { $0 }
        
        if panel.runModal() == .OK, let url = panel.url {
            self.inputPath = url.path
            self.updateOutputDirectory(from: url)
        }
    }
    
    func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            self.outputDirectory = url.path
        }
    }
    
    func openOutputDirectory() {
        guard !outputDirectory.isEmpty else { return }
        let url = URL(fileURLWithPath: outputDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(url)
    }
    
    func uniqueOutputPath(base: String, ext: String) -> String {
        let path = base + "." + ext
        if !FileManager.default.fileExists(atPath: path) { return path }
        var i = 1
        while FileManager.default.fileExists(atPath: "\(base)_\(i).\(ext)") { i += 1 }
        return "\(base)_\(i).\(ext)"
    }
    
    func startConversion() {
        guard !inputPath.isEmpty, !outputDirectory.isEmpty else { return }
        isConverting = true
        progress = 0.0
        
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputDirURL = URL(fileURLWithPath: outputDirectory)
        let basename = inputURL.deletingPathExtension().lastPathComponent
        
        do {
            try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
        } catch {
            log("Error: Cannot create output directory: \(error.localizedDescription)")
            isConverting = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.runConversion(inputURL: inputURL, outputDirURL: outputDirURL, basename: basename)
        }
    }
    
    private func runConversion(inputURL: URL, outputDirURL: URL, basename: String) {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let fileExtension = inputURL.pathExtension.lowercased()
            var cloud: GaussianCloud
            
            if fileExtension == "ply" {
                log("Parsing PLY: \(inputURL.lastPathComponent)")
                let plyData = try Data(contentsOf: inputURL)
                let parser = PLYParser()
                cloud = try parser.parse(data: plyData)
                log("Parsed \(cloud.count) splats, SH degree \(cloud.shDegree)")
            } else {
                log("Converting 3D mesh: \(inputURL.lastPathComponent)")
                let converter = MeshConverter()
                cloud = try converter.convert(url: inputURL, maxSplats: 500_000) { p in
                    DispatchQueue.main.async { self.progress = p * 0.3 }
                }
                log("Extracted \(cloud.count) splats from mesh")
            }
            
            DispatchQueue.main.async { self.progress = 0.2 }
            
            // SH Capping
            let targetSH: Int
            switch self.shDegreeIndex {
            case 1: targetSH = 0
            case 2: targetSH = 1
            case 3: targetSH = 2
            case 4: targetSH = 3
            default: targetSH = cloud.shDegree // Auto
            }
            if targetSH < cloud.shDegree {
                cloud.capSHDegree(to: targetSH)
                log("Capped SH degree to \(targetSH)")
            }
            
            // Splat Reduction
            let percentages = [40, 60, 80, 100]
            let splatPercent = percentages[self.splatPercentIndex]
            if splatPercent < 100 {
                log("Before reduction: \(cloud.count) splats")
                let target = max(1, Int(Double(cloud.count) * Double(splatPercent) / 100.0))
                var indices = Array(0..<cloud.splats.count)
                indices.shuffle()
                let selected = Set(indices.prefix(target))
                cloud.splats = cloud.splats.enumerated()
                    .filter { selected.contains($0.offset) }
                    .map { $0.element }
                log("After reduction: \(cloud.count) splats (\(splatPercent)%)")
            }
            
            DispatchQueue.main.async { self.progress = 0.35 }
            
            // Transform (always Metal)
            log("Running Metal compute transforms...")
            let transformer = try MetalTransformer()
            try transformer.transform(&cloud)
            log("Metal transform complete")
            
            DispatchQueue.main.async { self.progress = 0.6 }
            
            // Export .splat only
            var filenameSuffix = ""
            if self.shDegreeIndex > 0 {
                let targetSH = [0, 1, 2, 3][self.shDegreeIndex - 1]
                filenameSuffix += "_SH\(targetSH)"
            }
            if splatPercent < 100 {
                filenameSuffix += "_\(splatPercent)pct"
            }
            
            let finalBasename = basename + filenameSuffix
            let baseFilePath = outputDirURL.appendingPathComponent(finalBasename).path
            let path = uniqueOutputPath(base: baseFilePath, ext: "splat")
            log("Writing .splat → \(path)")
            let writer = SplatWriter()
            try writer.write(cloud: cloud, to: path)
            
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let fileSizeMB = Double(fileSize) / (1024 * 1024)
            log(String(format: "Output file: %.1f MB", fileSizeMB))
            
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            log("✓ Done! \(cloud.count) splats in \(String(format: "%.2f", elapsed))s")
            
            DispatchQueue.main.async {
                self.isConverting = false
                self.progress = 1.0
            }
            
        } catch {
            log("Error: \(error.localizedDescription)")
            DispatchQueue.main.async { self.isConverting = false }
        }
    }
}
