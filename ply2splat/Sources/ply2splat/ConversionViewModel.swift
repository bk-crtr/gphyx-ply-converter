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
    
    // Settings
    @Published var exportSplat: Bool = true
    @Published var exportKSplat: Bool = true
    @Published var exportSPZ: Bool = true
    
    @Published var compressionLevel: Int = 1
    @Published var shDegree: Int = -1 // -1 means Auto
    @Published var useMetal: Bool = true
    
    @Published var isConverting: Bool = false
    @Published var progress: Double = 0.0
    @Published var logMessages: [LogMessage] = []
    
    func log(_ message: String) {
        DispatchQueue.main.async {
            self.logMessages.append(LogMessage(text: message))
        }
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
                // Rough estimate for 3DGS rendering VRAM (standard splat is ~250-300MB per 1M splats)
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
            UTType(filenameExtension: "glb"),
            UTType(filenameExtension: "gltf"),
            UTType(filenameExtension: "obj"),
            UTType(filenameExtension: "usdz"),
            UTType(filenameExtension: "usdc"),
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
    
    func applyWebReadyPreset() {
        self.exportSplat = false
        self.exportKSplat = true
        self.exportSPZ = true
        self.compressionLevel = 1
        self.shDegree = 1
        self.useMetal = true
        log("Applied 'Web Ready' preset: SH Degree 1, Compressed.")
    }
    
    func openDonationLink() {
        if let url = URL(string: "https://www.buymeacoffee.com/gphyx") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func startConversion() {
        guard !inputPath.isEmpty else { return }
        guard !outputDirectory.isEmpty else { return }
        
        isConverting = true
        progress = 0.0
        logMessages.removeAll()
        
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
                cloud = try converter.convert(url: inputURL) { p in
                    DispatchQueue.main.async { self.progress = p * 0.3 }
                }
                log("Extracted \(cloud.count) splats from mesh")
            }
            
            DispatchQueue.main.async { self.progress = 0.2 }
            
            // SH Capping
            let targetSH = self.shDegree == -1 ? cloud.shDegree : self.shDegree
            if targetSH < cloud.shDegree {
                cloud.capSHDegree(to: targetSH)
                log("Capped SH degree to \(targetSH)")
            }
            
            DispatchQueue.main.async { self.progress = 0.3 }
            
            // Transform
            if self.useMetal {
                log("Running Metal compute transforms...")
                let transformer = try MetalTransformer()
                try transformer.transform(&cloud)
                log("Metal transform complete")
            } else {
                log("CPU transform...")
                cloud.transformCPU()
                log("CPU transform complete")
            }
            
            DispatchQueue.main.async { self.progress = 0.5 }
            
            var completedCount = 0
            let totalExports = (exportSplat ? 1 : 0) + (exportKSplat ? 1 : 0) + (exportSPZ ? 1 : 0)
            
            if self.exportSplat {
                let path = outputDirURL.appendingPathComponent("\(basename).splat").path
                log("Writing .splat → \(path)")
                let writer = SplatWriter()
                try writer.write(cloud: cloud, to: path)
                completedCount += 1
                DispatchQueue.main.async { self.progress = 0.6 + 0.4 * (Double(completedCount) / Double(totalExports)) }
            }
            
            if self.exportKSplat {
                let path = outputDirURL.appendingPathComponent("\(basename).ksplat").path
                log("Writing .ksplat → \(path) (compression: \(self.compressionLevel))")
                let writer = KSplatWriter(compressionLevel: self.compressionLevel)
                try writer.write(cloud: cloud, to: path)
                completedCount += 1
                DispatchQueue.main.async { self.progress = 0.6 + 0.4 * (Double(completedCount) / Double(totalExports)) }
            }
            
            if self.exportSPZ {
                let path = outputDirURL.appendingPathComponent("\(basename).spz").path
                log("Writing .spz → \(path)")
                let writer = SPZWriter()
                try writer.write(cloud: cloud, to: path)
                completedCount += 1
                DispatchQueue.main.async { self.progress = 0.6 + 0.4 * (Double(completedCount) / Double(totalExports)) }
            }
            
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            log("✓ Done! Optimized \(cloud.count) splats in \(String(format: "%.2f", elapsed))s")
            
            DispatchQueue.main.async {
                self.isConverting = false
                self.progress = 1.0
            }
            
        } catch {
            log("Error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isConverting = false
            }
        }
    }
}
