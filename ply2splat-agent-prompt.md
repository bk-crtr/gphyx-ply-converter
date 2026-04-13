# TASK: Create Xcode Project "ply2splat" — Metal-Accelerated Gaussian Splat PLY Converter

## OVERVIEW

Create a **macOS Command Line Tool** Xcode project called `ply2splat`.
This is a standalone CLI utility that converts 3D Gaussian Splatting `.ply` files to three output formats: `.splat`, `.ksplat`, `.spz`.
It uses **Metal compute shaders** for GPU-accelerated data transformation on Apple Silicon.

**Platform:** macOS 14+ (Sonoma), Apple Silicon (M4 Pro)
**Language:** Swift 5.9+, Metal Shading Language
**Dependencies:** Metal.framework, Foundation.framework, system libz (zlib)
**No external packages.** Everything is self-contained.

---

## XCODE PROJECT SETUP

1. Create new Xcode project → **macOS → Command Line Tool** → Product Name: `ply2splat`
2. Language: Swift
3. Deployment Target: macOS 14.0
4. In Build Settings:
   - Set `SWIFT_VERSION` = 5.9
   - Under "Linked Frameworks and Libraries" add: `Metal.framework`
   - Under "Other Linker Flags" add: `-lz` (for system zlib compression)
5. Build Configuration: Release, architecture arm64
6. Signing: Sign to Run Locally (no distribution certificate needed)

---

## FILE STRUCTURE

Create exactly these 6 Swift source files in the project:

```
ply2splat/
├── main.swift              — CLI entry point, argument parsing, orchestration
├── GaussianCloud.swift     — Data model: GaussianSplat struct + GaussianCloud container
├── PLYParser.swift         — Binary PLY parser (header + vertex data)
├── MetalTransformer.swift  — Metal compute: sigmoid, exp, normalize quat, SH→RGB
├── SplatWriter.swift       — .splat exporter (antimatter15 format, 32 bytes/splat)
├── KSplatWriter.swift      — .ksplat exporter (mkkellogg format, compression 0/1/2)
└── SPZWriter.swift         — .spz exporter (Niantic format, zlib compressed)
```

No .metal files needed — the Metal shader is compiled from a source string at runtime via `device.makeLibrary(source:options:)`.

---

## FILE 1: main.swift

```swift
// File: main.swift
import Foundation

// ─── CLI ─────────────────────────────────────────────────────
let version = "1.0.0"

func printUsage() {
    let usage = """
    ply2splat v\(version) — Gaussian Splat PLY converter (Metal-accelerated)
    
    USAGE:
      ply2splat <input.ply> [options]
    
    OUTPUT FORMATS (at least one required):
      --splat <output.splat>       antimatter15 format (32 bytes/splat, no SH)
      --ksplat <output.ksplat>     mkkellogg format (compression 0|1|2)
      --spz <output.spz>           Niantic SPZ format (~10x smaller)
      --all <basename>             Export all three: basename.splat, .ksplat, .spz
    
    OPTIONS:
      --sh-degree <0|1|2|3>        Max SH degree to preserve (default: auto from PLY)
      --compression <0|1|2>        KSPLAT compression level (default: 1)
      --alpha-threshold <0-255>    Remove splats with alpha below this (default: 1)
      --no-metal                   Disable Metal, use CPU fallback
      --verbose                    Print detailed progress
      --help                       Show this help
    
    EXAMPLES:
      ply2splat scene.ply --all scene
      ply2splat scene.ply --splat scene.splat --spz scene.spz
      ply2splat scene.ply --ksplat scene.ksplat --compression 2 --sh-degree 1
    
    © GPHYX 2025
    """
    print(usage)
}

// ─── Parse arguments ─────────────────────────────────────────
var args = CommandLine.arguments.dropFirst().makeIterator()
var inputPath: String?
var splatOutput: String?
var ksplatOutput: String?
var spzOutput: String?
var maxSHDegree: Int = -1  // -1 = auto
var compressionLevel: Int = 1
var alphaThreshold: Int = 1
var useMetal: Bool = true
var verbose: Bool = false

while let arg = args.next() {
    switch arg {
    case "--help", "-h":
        printUsage()
        exit(0)
    case "--splat":
        guard let val = args.next() else { fputs("Error: --splat requires path\n", stderr); exit(1) }
        splatOutput = val
    case "--ksplat":
        guard let val = args.next() else { fputs("Error: --ksplat requires path\n", stderr); exit(1) }
        ksplatOutput = val
    case "--spz":
        guard let val = args.next() else { fputs("Error: --spz requires path\n", stderr); exit(1) }
        spzOutput = val
    case "--all":
        guard let val = args.next() else { fputs("Error: --all requires basename\n", stderr); exit(1) }
        splatOutput = val + ".splat"
        ksplatOutput = val + ".ksplat"
        spzOutput = val + ".spz"
    case "--sh-degree":
        guard let val = args.next(), let v = Int(val), (0...3).contains(v) else {
            fputs("Error: --sh-degree requires 0-3\n", stderr); exit(1)
        }
        maxSHDegree = v
    case "--compression":
        guard let val = args.next(), let v = Int(val), (0...2).contains(v) else {
            fputs("Error: --compression requires 0-2\n", stderr); exit(1)
        }
        compressionLevel = v
    case "--alpha-threshold":
        guard let val = args.next(), let v = Int(val), (0...255).contains(v) else {
            fputs("Error: --alpha-threshold requires 0-255\n", stderr); exit(1)
        }
        alphaThreshold = v
    case "--no-metal":
        useMetal = false
    case "--verbose":
        verbose = true
    default:
        if arg.hasPrefix("-") {
            fputs("Unknown option: \(arg)\n", stderr); exit(1)
        }
        inputPath = arg
    }
}

guard let input = inputPath else {
    fputs("Error: no input PLY file specified\n", stderr)
    printUsage()
    exit(1)
}

if splatOutput == nil && ksplatOutput == nil && spzOutput == nil {
    fputs("Error: no output format specified (use --splat, --ksplat, --spz, or --all)\n", stderr)
    printUsage()
    exit(1)
}

// ─── Run ─────────────────────────────────────────────────────
func log(_ msg: String) {
    if verbose { print("[ply2splat] \(msg)") }
}

do {
    let startTime = CFAbsoluteTimeGetCurrent()

    // 1. Parse PLY
    log("Parsing PLY: \(input)")
    let plyData = try Data(contentsOf: URL(fileURLWithPath: input))
    let parser = PLYParser()
    var cloud = try parser.parse(data: plyData)
    log("Parsed \(cloud.count) splats, SH degree \(cloud.shDegree)")

    // 2. Apply SH degree cap
    if maxSHDegree >= 0 && maxSHDegree < cloud.shDegree {
        cloud.capSHDegree(to: maxSHDegree)
        log("Capped SH degree to \(maxSHDegree)")
    }

    // 3. Transform on Metal (sigmoid, exp(scale), normalize quaternion, SH→RGB)
    if useMetal {
        log("Running Metal compute transforms...")
        let transformer = try MetalTransformer()
        try transformer.transform(&cloud)
        log("Metal transform complete")
    } else {
        log("CPU transform...")
        cloud.transformCPU()
        log("CPU transform complete")
    }

    // 4. Filter by alpha
    if alphaThreshold > 0 {
        let before = cloud.count
        cloud.filterByAlpha(minAlpha: UInt8(alphaThreshold))
        log("Filtered \(before - cloud.count) splats below alpha \(alphaThreshold), \(cloud.count) remaining")
    }

    // 5. Export
    if let path = splatOutput {
        log("Writing .splat → \(path)")
        let writer = SplatWriter()
        try writer.write(cloud: cloud, to: path)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 ?? 0
        log(".splat written: \(formatBytes(size))")
    }

    if let path = ksplatOutput {
        log("Writing .ksplat → \(path) (compression: \(compressionLevel))")
        let writer = KSplatWriter(compressionLevel: compressionLevel)
        try writer.write(cloud: cloud, to: path)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 ?? 0
        log(".ksplat written: \(formatBytes(size))")
    }

    if let path = spzOutput {
        log("Writing .spz → \(path)")
        let writer = SPZWriter()
        try writer.write(cloud: cloud, to: path)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 ?? 0
        log(".spz written: \(formatBytes(size))")
    }

    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
    let inputSize = try FileManager.default.attributesOfItem(atPath: input)[.size] as? UInt64 ?? 0

    print("✓ Converted \(cloud.count) splats in \(String(format: "%.2f", elapsed))s")
    print("  Input:  \(formatBytes(inputSize))")
    if let p = splatOutput {
        let s = try FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64 ?? 0
        print("  .splat: \(formatBytes(s))")
    }
    if let p = ksplatOutput {
        let s = try FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64 ?? 0
        print("  .ksplat:\(formatBytes(s))")
    }
    if let p = spzOutput {
        let s = try FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64 ?? 0
        print("  .spz:   \(formatBytes(s))")
    }

} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func formatBytes(_ bytes: UInt64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}
```

---

## FILE 2: GaussianCloud.swift

```swift
// File: GaussianCloud.swift
import Foundation
import simd

/// Per-splat data in raw (untransformed) form from PLY, then transformed in-place.
/// After transform: opacity = sigmoid(raw), scale = exp(raw), quaternion normalized, color = SH→RGB
struct GaussianSplat {
    var position: SIMD3<Float>      // xyz
    var scale: SIMD3<Float>         // raw from PLY → exp() after transform
    var rotation: simd_quatf        // raw from PLY → normalized after transform
    var opacity: Float              // raw from PLY → sigmoid after transform
    var color: SIMD4<UInt8>         // RGBA 0-255, computed from SH DC after transform
    var shDC: SIMD3<Float>          // f_dc_0/1/2 raw
    var shRest: [Float]             // f_rest_0..N raw
}

/// Cloud of Gaussian splats with metadata
struct GaussianCloud {
    var splats: [GaussianSplat]
    var shDegree: Int               // 0, 1, 2, or 3
    var isTransformed: Bool = false

    var count: Int { splats.count }

    /// Number of SH rest coefficients per splat based on degree
    var shRestCount: Int {
        switch shDegree {
        case 0: return 0
        case 1: return 9
        case 2: return 24
        case 3: return 45
        default: return 0
        }
    }

    /// Number of SH coefficients per channel for a given degree
    static func shCoeffsPerChannel(degree: Int) -> Int {
        switch degree {
        case 0: return 1
        case 1: return 4    // 1 + 3
        case 2: return 9    // 1 + 3 + 5
        case 3: return 16   // 1 + 3 + 5 + 7
        default: return 1
        }
    }

    mutating func capSHDegree(to degree: Int) {
        guard degree < shDegree else { return }
        let newRestCount: Int
        switch degree {
        case 0: newRestCount = 0
        case 1: newRestCount = 9
        case 2: newRestCount = 24
        default: return
        }
        for i in splats.indices {
            if splats[i].shRest.count > newRestCount {
                splats[i].shRest = Array(splats[i].shRest.prefix(newRestCount))
            }
        }
        shDegree = degree
    }

    /// CPU fallback for transform
    mutating func transformCPU() {
        guard !isTransformed else { return }
        let SH_C0: Float = 0.28209479177387814

        for i in splats.indices {
            // sigmoid(opacity)
            splats[i].opacity = 1.0 / (1.0 + exp(-splats[i].opacity))

            // exp(scale)
            splats[i].scale = SIMD3(
                exp(splats[i].scale.x),
                exp(splats[i].scale.y),
                exp(splats[i].scale.z)
            )

            // normalize quaternion
            let q = splats[i].rotation
            let len = sqrt(q.real * q.real + simd_dot(q.imag, q.imag))
            if len > 0 {
                splats[i].rotation = simd_quatf(
                    ix: q.imag.x / len,
                    iy: q.imag.y / len,
                    iz: q.imag.z / len,
                    r: q.real / len
                )
            }

            // SH DC → RGB
            let r = clampByte(splats[i].shDC.x * SH_C0 + 0.5)
            let g = clampByte(splats[i].shDC.y * SH_C0 + 0.5)
            let b = clampByte(splats[i].shDC.z * SH_C0 + 0.5)
            let a = clampByte(splats[i].opacity)
            splats[i].color = SIMD4(r, g, b, a)
        }
        isTransformed = true
    }

    mutating func filterByAlpha(minAlpha: UInt8) {
        splats.removeAll { $0.color.w < minAlpha }
    }
}

func clampByte(_ v: Float) -> UInt8 {
    UInt8(max(0, min(255, v * 255.0)))
}
```

---

## FILE 3: PLYParser.swift

```swift
// File: PLYParser.swift
import Foundation
import simd

enum PLYError: LocalizedError {
    case invalidHeader(String)
    case unsupportedFormat(String)
    case dataTruncated

    var errorDescription: String? {
        switch self {
        case .invalidHeader(let msg): return "Invalid PLY header: \(msg)"
        case .unsupportedFormat(let msg): return "Unsupported PLY format: \(msg)"
        case .dataTruncated: return "PLY data truncated"
        }
    }
}

struct PLYProperty {
    let name: String
    let type: String    // float, double, uchar, int, uint, short
    var byteSize: Int {
        switch type {
        case "double": return 8
        case "float", "int", "uint", "int32", "uint32": return 4
        case "short", "ushort", "int16", "uint16": return 2
        case "uchar", "uint8", "char", "int8": return 1
        default: return 4
        }
    }
}

struct PLYHeader {
    var vertexCount: Int = 0
    var properties: [PLYProperty] = []
    var dataOffset: Int = 0
    var isLittleEndian: Bool = true
    var stride: Int { properties.reduce(0) { $0 + $1.byteSize } }
}

final class PLYParser {

    func parse(data: Data) throws -> GaussianCloud {
        let header = try parseHeader(data)
        return try parseVertices(data, header: header)
    }

    private func parseHeader(_ data: Data) throws -> PLYHeader {
        guard data.count > 10 else { throw PLYError.invalidHeader("File too small") }

        // Read up to 16KB for header
        let maxHeader = min(data.count, 16384)
        guard let headerText = String(data: data[0..<maxHeader], encoding: .ascii) else {
            throw PLYError.invalidHeader("Cannot decode header as ASCII")
        }

        guard let endRange = headerText.range(of: "end_header") else {
            throw PLYError.invalidHeader("No end_header found")
        }

        let headerStr = String(headerText[headerText.startIndex..<endRange.upperBound])
        // data starts after end_header + newline
        let dataOffset = headerStr.utf8.count + 1

        var header = PLYHeader()
        header.dataOffset = dataOffset

        let lines = headerStr.components(separatedBy: "\n")
        var inVertexElement = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("format") {
                if trimmed.contains("binary_little_endian") {
                    header.isLittleEndian = true
                } else if trimmed.contains("binary_big_endian") {
                    header.isLittleEndian = false
                } else if trimmed.contains("ascii") {
                    throw PLYError.unsupportedFormat("ASCII PLY not supported, use binary")
                }
            } else if trimmed.hasPrefix("element vertex") {
                let parts = trimmed.split(separator: " ")
                header.vertexCount = Int(parts.last ?? "0") ?? 0
                inVertexElement = true
            } else if trimmed.hasPrefix("element") {
                inVertexElement = false
            } else if trimmed.hasPrefix("property") && inVertexElement {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 3 && !trimmed.contains("list") {
                    header.properties.append(PLYProperty(
                        name: String(parts[2]),
                        type: String(parts[1])
                    ))
                }
            }
        }

        guard header.vertexCount > 0 else {
            throw PLYError.invalidHeader("No vertices found")
        }

        return header
    }

    private func parseVertices(_ data: Data, header: PLYHeader) throws -> GaussianCloud {
        let stride = header.stride
        let requiredSize = header.dataOffset + header.vertexCount * stride
        guard data.count >= requiredSize else {
            throw PLYError.dataTruncated
        }

        // Build property offset lookup
        var propOffset: [String: Int] = [:]
        var propType: [String: String] = [:]
        var offset = 0
        for prop in header.properties {
            propOffset[prop.name] = offset
            propType[prop.name] = prop.type
            offset += prop.byteSize
        }

        // Determine SH degree
        let hasDC = propOffset["f_dc_0"] != nil
        var shRestCount = 0
        while propOffset["f_rest_\(shRestCount)"] != nil { shRestCount += 1 }
        let shDegree: Int
        if shRestCount >= 45 { shDegree = 3 }
        else if shRestCount >= 24 { shDegree = 2 }
        else if shRestCount >= 9 { shDegree = 1 }
        else { shDegree = 0 }

        // Parse all vertices
        var splats = [GaussianSplat]()
        splats.reserveCapacity(header.vertexCount)

        try data.withUnsafeBytes { rawBuffer in
            let basePtr = rawBuffer.baseAddress!

            for i in 0..<header.vertexCount {
                let vPtr = basePtr + header.dataOffset + i * stride

                func readFloat(_ name: String) -> Float {
                    guard let off = propOffset[name] else { return 0 }
                    let type = propType[name]!
                    let ptr = vPtr + off
                    switch type {
                    case "float":
                        return ptr.loadUnaligned(as: Float.self)
                    case "double":
                        return Float(ptr.loadUnaligned(as: Double.self))
                    case "uchar", "uint8":
                        return Float(ptr.load(as: UInt8.self))
                    case "int", "int32":
                        return Float(ptr.loadUnaligned(as: Int32.self))
                    default:
                        return ptr.loadUnaligned(as: Float.self)
                    }
                }

                let position = SIMD3<Float>(readFloat("x"), readFloat("y"), readFloat("z"))
                let scale = SIMD3<Float>(readFloat("scale_0"), readFloat("scale_1"), readFloat("scale_2"))
                let rotation = simd_quatf(
                    ix: readFloat("rot_1"),
                    iy: readFloat("rot_2"),
                    iz: readFloat("rot_3"),
                    r: readFloat("rot_0")
                )
                let opacity = readFloat("opacity")

                let shDC: SIMD3<Float>
                if hasDC {
                    shDC = SIMD3(readFloat("f_dc_0"), readFloat("f_dc_1"), readFloat("f_dc_2"))
                } else {
                    // Fallback: try red/green/blue
                    shDC = SIMD3(readFloat("red"), readFloat("green"), readFloat("blue"))
                }

                var shRest = [Float]()
                if shRestCount > 0 {
                    shRest.reserveCapacity(shRestCount)
                    for s in 0..<shRestCount {
                        shRest.append(readFloat("f_rest_\(s)"))
                    }
                }

                splats.append(GaussianSplat(
                    position: position,
                    scale: scale,
                    rotation: rotation,
                    opacity: opacity,
                    color: SIMD4(0, 0, 0, 0),  // computed after transform
                    shDC: shDC,
                    shRest: shRest
                ))
            }
        }

        return GaussianCloud(splats: splats, shDegree: shDegree)
    }
}
```

---

## FILE 4: MetalTransformer.swift

**CRITICAL:** The Metal shader is compiled from a source string at runtime. Do NOT create a .metal file. The shader code is embedded in the Swift string below.

```swift
// File: MetalTransformer.swift
import Foundation
import Metal
import simd

enum MetalError: LocalizedError {
    case noDevice
    case noQueue
    case shaderCompilationFailed(String)
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal device available"
        case .noQueue: return "Failed to create command queue"
        case .shaderCompilationFailed(let e): return "Metal shader compilation failed: \(e)"
        case .bufferCreationFailed: return "Failed to create Metal buffer"
        }
    }
}

/// GPU-packed splat for Metal compute (matches struct in shader)
struct GPUSplat {
    var px: Float; var py: Float; var pz: Float    // position
    var sx: Float; var sy: Float; var sz: Float    // scale (raw → exp)
    var qx: Float; var qy: Float; var qz: Float; var qw: Float  // quaternion (raw → normalized)
    var opacity: Float                              // raw → sigmoid
    var dcR: Float; var dcG: Float; var dcB: Float // SH DC coefficients
    // Output
    var r: UInt8; var g: UInt8; var b: UInt8; var a: UInt8 // computed RGBA
    var _pad: Float  // alignment padding
}

final class MetalTransformer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalError.noQueue }
        self.device = device
        self.queue = queue

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct GPUSplat {
            float px, py, pz;
            float sx, sy, sz;
            float qx, qy, qz, qw;
            float opacity;
            float dcR, dcG, dcB;
            uchar r, g, b, a;
            float _pad;
        };

        kernel void transformSplats(
            device GPUSplat *splats [[buffer(0)]],
            constant uint &count [[buffer(1)]],
            uint gid [[thread_position_in_grid]]
        ) {
            if (gid >= count) return;

            // sigmoid(opacity)
            float sig = 1.0f / (1.0f + exp(-splats[gid].opacity));
            splats[gid].opacity = sig;

            // exp(scale)
            splats[gid].sx = exp(splats[gid].sx);
            splats[gid].sy = exp(splats[gid].sy);
            splats[gid].sz = exp(splats[gid].sz);

            // normalize quaternion
            float qx = splats[gid].qx;
            float qy = splats[gid].qy;
            float qz = splats[gid].qz;
            float qw = splats[gid].qw;
            float len = sqrt(qx*qx + qy*qy + qz*qz + qw*qw);
            if (len > 0.0f) {
                float inv = 1.0f / len;
                splats[gid].qx = qx * inv;
                splats[gid].qy = qy * inv;
                splats[gid].qz = qz * inv;
                splats[gid].qw = qw * inv;
            }

            // SH DC → RGB (SH_C0 = 0.28209479177387814)
            float SH_C0 = 0.28209479177387814f;
            float rf = splats[gid].dcR * SH_C0 + 0.5f;
            float gf = splats[gid].dcG * SH_C0 + 0.5f;
            float bf = splats[gid].dcB * SH_C0 + 0.5f;

            splats[gid].r = uchar(clamp(rf * 255.0f, 0.0f, 255.0f));
            splats[gid].g = uchar(clamp(gf * 255.0f, 0.0f, 255.0f));
            splats[gid].b = uchar(clamp(bf * 255.0f, 0.0f, 255.0f));
            splats[gid].a = uchar(clamp(sig * 255.0f, 0.0f, 255.0f));
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let function = library.makeFunction(name: "transformSplats") else {
                throw MetalError.shaderCompilationFailed("transformSplats not found")
            }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch let error as MetalError {
            throw error
        } catch {
            throw MetalError.shaderCompilationFailed(error.localizedDescription)
        }
    }

    func transform(_ cloud: inout GaussianCloud) throws {
        guard !cloud.isTransformed else { return }
        let count = cloud.count
        guard count > 0 else { return }

        // Pack into GPU struct
        var gpuSplats = [GPUSplat]()
        gpuSplats.reserveCapacity(count)
        for s in cloud.splats {
            gpuSplats.append(GPUSplat(
                px: s.position.x, py: s.position.y, pz: s.position.z,
                sx: s.scale.x, sy: s.scale.y, sz: s.scale.z,
                qx: s.rotation.imag.x, qy: s.rotation.imag.y,
                qz: s.rotation.imag.z, qw: s.rotation.real,
                opacity: s.opacity,
                dcR: s.shDC.x, dcG: s.shDC.y, dcB: s.shDC.z,
                r: 0, g: 0, b: 0, a: 0,
                _pad: 0
            ))
        }

        let bufferSize = MemoryLayout<GPUSplat>.stride * count
        guard let buffer = device.makeBuffer(
            bytes: &gpuSplats,
            length: bufferSize,
            options: .storageModeShared
        ) else { throw MetalError.bufferCreationFailed }

        var splatCount = UInt32(count)
        guard let countBuffer = device.makeBuffer(
            bytes: &splatCount,
            length: MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else { throw MetalError.bufferCreationFailed }

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw MetalError.noQueue
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBuffer(countBuffer, offset: 0, index: 1)

        let threadgroupSize = MTLSize(width: min(pipeline.threadExecutionWidth, count), height: 1, depth: 1)
        let threadgroups = MTLSize(width: (count + threadgroupSize.width - 1) / threadgroupSize.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        // Read back
        let resultPtr = buffer.contents().bindMemory(to: GPUSplat.self, capacity: count)
        for i in 0..<count {
            let g = resultPtr[i]
            cloud.splats[i].scale = SIMD3(g.sx, g.sy, g.sz)
            cloud.splats[i].rotation = simd_quatf(ix: g.qx, iy: g.qy, iz: g.qz, r: g.qw)
            cloud.splats[i].opacity = g.opacity
            cloud.splats[i].color = SIMD4(g.r, g.g, g.b, g.a)
        }

        cloud.isTransformed = true
    }
}
```

---

## FILE 5: SplatWriter.swift

```swift
// File: SplatWriter.swift
import Foundation
import simd

/// Writes .splat format (antimatter15)
/// Layout: 32 bytes per splat, no header, no SH
/// [pos_x:f32][pos_y:f32][pos_z:f32][scale_x:f32][scale_y:f32][scale_z:f32][r:u8][g:u8][b:u8][a:u8][quat_w:u8][quat_x:u8][quat_y:u8][quat_z:u8]
/// Total: 24 (6 floats) + 4 (RGBA) + 4 (quaternion as u8) = 32 bytes
final class SplatWriter {

    func write(cloud: GaussianCloud, to path: String) throws {
        let count = cloud.count
        let bytesPerSplat = 32
        var buffer = Data(capacity: count * bytesPerSplat)

        for splat in cloud.splats {
            // Position (3 × float32 = 12 bytes)
            var px = splat.position.x; buffer.append(contentsOf: withUnsafeBytes(of: &px) { Array($0) })
            var py = splat.position.y; buffer.append(contentsOf: withUnsafeBytes(of: &py) { Array($0) })
            var pz = splat.position.z; buffer.append(contentsOf: withUnsafeBytes(of: &pz) { Array($0) })

            // Scale (3 × float32 = 12 bytes) — already exp'd
            var sx = splat.scale.x; buffer.append(contentsOf: withUnsafeBytes(of: &sx) { Array($0) })
            var sy = splat.scale.y; buffer.append(contentsOf: withUnsafeBytes(of: &sy) { Array($0) })
            var sz = splat.scale.z; buffer.append(contentsOf: withUnsafeBytes(of: &sz) { Array($0) })

            // Color RGBA (4 bytes)
            buffer.append(splat.color.x)  // R
            buffer.append(splat.color.y)  // G
            buffer.append(splat.color.z)  // B
            buffer.append(splat.color.w)  // A

            // Quaternion as 4 × uint8 (normalized -1..1 → 0..255)
            // .splat format: [w, x, y, z] encoded as (q * 128 + 128)
            let q = splat.rotation
            buffer.append(quatToU8(q.real))    // w
            buffer.append(quatToU8(q.imag.x))  // x
            buffer.append(quatToU8(q.imag.y))  // y
            buffer.append(quatToU8(q.imag.z))  // z
        }

        try buffer.write(to: URL(fileURLWithPath: path))
    }

    private func quatToU8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, (v * 128.0 + 128.0).rounded())))
    }
}
```

---

## FILE 6: KSplatWriter.swift

```swift
// File: KSplatWriter.swift
import Foundation
import simd

/// Writes .ksplat format (mkkellogg/GaussianSplats3D)
///
/// File structure:
/// - Header (4 bytes): magic version u8, section count u32... etc.
/// - Section headers: per-section metadata (bucket info, compression, counts)
/// - Section data: packed splat data per section
///
/// Compression level 0: all floats 32-bit
/// Compression level 1: position/scale/rotation/SH as float16
/// Compression level 2: same as 1 but SH as uint8
///
/// For simplicity, we write a single section with all splats (no spatial bucketing
/// for compression 0, basic center-offset bucketing for 1/2).
final class KSplatWriter {
    let compressionLevel: Int

    init(compressionLevel: Int = 1) {
        self.compressionLevel = min(max(compressionLevel, 0), 2)
    }

    func write(cloud: GaussianCloud, to path: String) throws {
        var buffer = Data()

        // ── KSplat file header ──
        // Version tag: we write version 0 (uncompressed) or version 1 (compressed)
        // Format from GaussianSplats3D SplatBuffer:
        //
        // File header (16 bytes):
        //   [0]  u16: version/magic (0 = uncompressed sections, 1 = compressed)
        //   [2]  u8:  sectionCount
        //   [3]  u8:  splatCount high bits padding
        //   [4]  u32: total splatCount
        //   [8]  u8:  compressionLevel
        //   [9]  u8:  SH degree stored
        //   [10] u8[6]: reserved

        let version: UInt16 = compressionLevel > 0 ? 1 : 0
        let sectionCount: UInt8 = 1
        let splatCount = UInt32(cloud.count)
        let shDeg = UInt8(cloud.shDegree)

        appendU16(&buffer, version)
        buffer.append(sectionCount)
        buffer.append(0) // padding
        appendU32(&buffer, splatCount)
        buffer.append(UInt8(compressionLevel))
        buffer.append(shDeg)
        buffer.append(contentsOf: [UInt8](repeating: 0, count: 6)) // reserved

        // ── Section header (64 bytes) ──
        let bucketSize: UInt32 = 256
        let bucketCount: UInt32 = UInt32((cloud.count + Int(bucketSize) - 1) / Int(bucketSize))
        let blockSize: Float = 5.0

        // Calculate per-splat data sizes
        let bytesPerSplat = splatDataSize(cloud: cloud)
        let totalDataSize = UInt32(cloud.count) * UInt32(bytesPerSplat)

        // Bucket storage: for compressed, each bucket has 12 bytes header (center xyz as f32)
        let bucketStorageSize: UInt32 = compressionLevel > 0 ? bucketCount * 12 : 0

        // Section header
        appendU32(&buffer, splatCount)
        appendU32(&buffer, splatCount)          // maxSplatCount
        appendU32(&buffer, bucketSize)
        appendU32(&buffer, bucketCount)
        appendF32(&buffer, blockSize)
        appendF32(&buffer, blockSize * 0.5)
        appendU32(&buffer, bucketStorageSize)
        appendU32(&buffer, compressionLevel > 0 ? 1 : 0) // compressionScaleRange
        appendU32(&buffer, totalDataSize + bucketStorageSize)
        appendU32(&buffer, bucketCount)         // fullBucketCount (simplified)
        appendU32(&buffer, 0)                   // partiallyFilledBucketCount

        // Scene center (compute bounding box center)
        let center = computeCenter(cloud)
        appendF32(&buffer, center.x)
        appendF32(&buffer, center.y)
        appendF32(&buffer, center.z)

        // Pad to 64 bytes total section header
        let sectionHeaderSoFar = 44 + 12  // 11 u32/f32 fields + 3 f32 center = 56 bytes
        let sectionHeaderPad = 64 - sectionHeaderSoFar
        buffer.append(contentsOf: [UInt8](repeating: 0, count: sectionHeaderPad))

        // ── Bucket headers (for compressed) ──
        if compressionLevel > 0 {
            // Each bucket: center (3 × f32) = 12 bytes
            let splatsPerBucket = Int(bucketSize)
            for bIdx in 0..<Int(bucketCount) {
                let start = bIdx * splatsPerBucket
                let end = min(start + splatsPerBucket, cloud.count)
                let bCenter = bucketCenter(cloud: cloud, start: start, end: end)
                appendF32(&buffer, bCenter.x)
                appendF32(&buffer, bCenter.y)
                appendF32(&buffer, bCenter.z)
            }
        }

        // ── Splat data ──
        switch compressionLevel {
        case 0:
            writeUncompressed(&buffer, cloud: cloud)
        case 1, 2:
            writeCompressed(&buffer, cloud: cloud)
        default:
            writeUncompressed(&buffer, cloud: cloud)
        }

        try buffer.write(to: URL(fileURLWithPath: path))
    }

    // ── Uncompressed (level 0) ──
    // Per splat: position(3×f32) + scale(3×f32) + rotation(4×f32) + color(4×u8) + SH
    private func writeUncompressed(_ buffer: inout Data, cloud: GaussianCloud) {
        for splat in cloud.splats {
            appendF32(&buffer, splat.position.x)
            appendF32(&buffer, splat.position.y)
            appendF32(&buffer, splat.position.z)
            appendF32(&buffer, splat.scale.x)
            appendF32(&buffer, splat.scale.y)
            appendF32(&buffer, splat.scale.z)
            appendF32(&buffer, splat.rotation.real)
            appendF32(&buffer, splat.rotation.imag.x)
            appendF32(&buffer, splat.rotation.imag.y)
            appendF32(&buffer, splat.rotation.imag.z)
            buffer.append(splat.color.x)
            buffer.append(splat.color.y)
            buffer.append(splat.color.z)
            buffer.append(splat.color.w)
            appendF32(&buffer, splat.shDC.x)
            appendF32(&buffer, splat.shDC.y)
            appendF32(&buffer, splat.shDC.z)
            for coeff in splat.shRest {
                appendF32(&buffer, coeff)
            }
        }
    }

    // ── Compressed (level 1/2) ──
    private func writeCompressed(_ buffer: inout Data, cloud: GaussianCloud) {
        let splatsPerBucket = 256
        let bucketCount = (cloud.count + splatsPerBucket - 1) / splatsPerBucket

        for bIdx in 0..<bucketCount {
            let start = bIdx * splatsPerBucket
            let end = min(start + splatsPerBucket, cloud.count)
            let bCenter = bucketCenter(cloud: cloud, start: start, end: end)

            for i in start..<end {
                let splat = cloud.splats[i]

                // Position as offset from bucket center → float16
                appendF16(&buffer, splat.position.x - bCenter.x)
                appendF16(&buffer, splat.position.y - bCenter.y)
                appendF16(&buffer, splat.position.z - bCenter.z)

                // Scale → float16 (already exp'd, store log for reconstruction)
                appendF16(&buffer, log(max(splat.scale.x, 1e-10)))
                appendF16(&buffer, log(max(splat.scale.y, 1e-10)))
                appendF16(&buffer, log(max(splat.scale.z, 1e-10)))

                // Rotation → float16 (w, x, y, z)
                appendF16(&buffer, splat.rotation.real)
                appendF16(&buffer, splat.rotation.imag.x)
                appendF16(&buffer, splat.rotation.imag.y)
                appendF16(&buffer, splat.rotation.imag.z)

                // Color RGBA
                buffer.append(splat.color.x)
                buffer.append(splat.color.y)
                buffer.append(splat.color.z)
                buffer.append(splat.color.w)

                // SH coefficients
                if compressionLevel == 1 {
                    appendF16(&buffer, splat.shDC.x)
                    appendF16(&buffer, splat.shDC.y)
                    appendF16(&buffer, splat.shDC.z)
                    for coeff in splat.shRest {
                        appendF16(&buffer, coeff)
                    }
                } else {
                    // uint8 (level 2): DC as float16, rest quantized to uint8
                    appendF16(&buffer, splat.shDC.x)
                    appendF16(&buffer, splat.shDC.y)
                    appendF16(&buffer, splat.shDC.z)
                    for coeff in splat.shRest {
                        let normalized = (coeff + 2.0) / 4.0
                        let byte = UInt8(max(0, min(255, normalized * 255.0)))
                        buffer.append(byte)
                    }
                }
            }
        }
    }

    private func splatDataSize(cloud: GaussianCloud) -> Int {
        let shRestCount = cloud.splats.first?.shRest.count ?? 0
        switch compressionLevel {
        case 0:  return 12 + 12 + 16 + 4 + 12 + shRestCount * 4
        case 1:  return 6 + 6 + 8 + 4 + 6 + shRestCount * 2
        case 2:  return 6 + 6 + 8 + 4 + 6 + shRestCount * 1
        default: return 44
        }
    }

    private func computeCenter(_ cloud: GaussianCloud) -> SIMD3<Float> {
        var minP = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for s in cloud.splats {
            minP = simd_min(minP, s.position)
            maxP = simd_max(maxP, s.position)
        }
        return (minP + maxP) * 0.5
    }

    private func bucketCenter(cloud: GaussianCloud, start: Int, end: Int) -> SIMD3<Float> {
        var sum = SIMD3<Float>(repeating: 0)
        let count = end - start
        for i in start..<end { sum += cloud.splats[i].position }
        return count > 0 ? sum / Float(count) : SIMD3(repeating: 0)
    }

    // ── Binary helpers ──
    private func appendU16(_ data: inout Data, _ v: UInt16) {
        var val = v; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendU32(_ data: inout Data, _ v: UInt32) {
        var val = v; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendF32(_ data: inout Data, _ v: Float) {
        var val = v; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }
    private func appendF16(_ data: inout Data, _ v: Float) {
        let bits = floatToHalf(v)
        var val = bits; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    private func floatToHalf(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = (bits >> 31) & 1
        let exponent = Int((bits >> 23) & 0xFF) - 127
        let mantissa = bits & 0x7FFFFF

        if exponent > 15 {
            return UInt16(sign << 15) | 0x7C00
        } else if exponent < -14 {
            if exponent < -24 { return UInt16(sign << 15) }
            let shift = -14 - exponent
            let m = (mantissa | 0x800000) >> (shift + 13)
            return UInt16(sign << 15) | UInt16(m)
        } else {
            let e = UInt16(exponent + 15)
            let m = UInt16(mantissa >> 13)
            return UInt16(sign << 15) | (e << 10) | m
        }
    }
}
```

---

## FILE 7: SPZWriter.swift

```swift
// File: SPZWriter.swift
import Foundation
import simd

/// Writes .spz format (Niantic Labs)
///
/// SPZ binary layout:
///   Header (16 bytes):
///     [0..3]   magic: "SPZ\0" (4 bytes)
///     [4..7]   version: u32 (currently 2)
///     [8..11]  numPoints: u32
///     [12]     shDegree: u8
///     [13]     flags: u8 (bit 0 = antialiased)
///     [14..15] reserved: u16
///
///   Then zlib-compressed payload:
///     positions:  numPoints × 3 × f32 (little-endian)
///     alphas:     numPoints × 1 × u8 (quantized 0-255)
///     colors:     numPoints × 3 × u8 (SH DC → RGB, 0-255)
///     scales:     numPoints × 3 × u8 (quantized log-scale)
///     rotations:  numPoints × 4 × u8 (quaternion)
///     sh:         numPoints × shCoeffs × 3 × u8 (quantized)
///
/// Note: SPZ uses RUB coordinate system (right-up-back, OpenGL convention).
/// PLY typically uses RDF. We do the conversion: PLY(x,y,z) → SPZ(x,-y,-z).
final class SPZWriter {

    func write(cloud: GaussianCloud, to path: String) throws {
        let count = cloud.count
        guard count > 0 else { throw SPZError.emptyCloud }

        var headerData = Data()

        // Magic
        headerData.append(contentsOf: [0x53, 0x50, 0x5A, 0x00]) // "SPZ\0"
        // Version
        appendU32(&headerData, 2)
        // numPoints
        appendU32(&headerData, UInt32(count))
        // shDegree
        headerData.append(UInt8(cloud.shDegree))
        // flags (0 = not antialiased)
        headerData.append(0)
        // reserved
        headerData.append(contentsOf: [0, 0])

        // ── Build payload (uncompressed) ──
        var payload = Data()

        // Positions: N × 3 × f32
        // Coordinate transform: PLY RDF → SPZ RUB: (x, -y, -z)
        for splat in cloud.splats {
            appendF32(&payload, splat.position.x)
            appendF32(&payload, -splat.position.y)
            appendF32(&payload, -splat.position.z)
        }

        // Alphas: N × u8
        for splat in cloud.splats {
            payload.append(splat.color.w)
        }

        // Colors: N × 3 × u8
        for splat in cloud.splats {
            payload.append(splat.color.x)
            payload.append(splat.color.y)
            payload.append(splat.color.z)
        }

        // Scales: N × 3 × u8 (quantized log-scale)
        let logScales = cloud.splats.map { s -> SIMD3<Float> in
            SIMD3(
                log(max(s.scale.x, 1e-10)),
                log(max(s.scale.y, 1e-10)),
                log(max(s.scale.z, 1e-10))
            )
        }

        var minLog = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxLog = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for ls in logScales {
            minLog = simd_min(minLog, ls)
            maxLog = simd_max(maxLog, ls)
        }
        let globalMinLog = min(minLog.x, min(minLog.y, minLog.z))
        let globalMaxLog = max(maxLog.x, max(maxLog.y, maxLog.z))
        let logRange = globalMaxLog - globalMinLog
        let logScale = logRange > 0 ? 255.0 / logRange : 0

        for ls in logScales {
            payload.append(quantize(ls.x, min: globalMinLog, scale: logScale))
            payload.append(quantize(ls.y, min: globalMinLog, scale: logScale))
            payload.append(quantize(ls.z, min: globalMinLog, scale: logScale))
        }

        // Rotations: N × 4 × u8
        for splat in cloud.splats {
            let q = splat.rotation
            let sign: Float = q.real >= 0 ? 1.0 : -1.0
            payload.append(quatToU8(q.real * sign))
            payload.append(quatToU8(q.imag.x * sign))
            payload.append(quatToU8(q.imag.y * sign))
            payload.append(quatToU8(q.imag.z * sign))
        }

        // SH coefficients (for degree > 0)
        if cloud.shDegree > 0 {
            let restCount = cloud.splats.first?.shRest.count ?? 0
            if restCount > 0 {
                var shMin: Float = .greatestFiniteMagnitude
                var shMax: Float = -.greatestFiniteMagnitude
                for splat in cloud.splats {
                    for c in splat.shRest {
                        shMin = min(shMin, c)
                        shMax = max(shMax, c)
                    }
                }
                let shRange = shMax - shMin
                let shScale = shRange > 0 ? 255.0 / shRange : 0

                for splat in cloud.splats {
                    for c in splat.shRest {
                        payload.append(quantize(c, min: shMin, scale: shScale))
                    }
                }
            }
        }

        // ── Compress payload with zlib ──
        let compressed = try zlibCompress(payload)

        // ── Write file: header + compressed payload ──
        var output = headerData
        output.append(compressed)

        try output.write(to: URL(fileURLWithPath: path))
    }

    // ── Helpers ──

    private func quantize(_ v: Float, min: Float, scale: Float) -> UInt8 {
        UInt8(max(0, min(255, ((v - min) * scale).rounded())))
    }

    private func quatToU8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, ((v + 1.0) * 0.5 * 255.0).rounded())))
    }

    private func appendU32(_ data: inout Data, _ v: UInt32) {
        var val = v; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    private func appendF32(_ data: inout Data, _ v: Float) {
        var val = v; data.append(contentsOf: withUnsafeBytes(of: &val) { Array($0) })
    }

    /// Zlib compression (deflate) using system libz
    private func zlibCompress(_ data: Data) throws -> Data {
        return try data.withUnsafeBytes { rawBuffer -> Data in
            let sourcePtr = rawBuffer.bindMemory(to: UInt8.self)
            let sourceLen = data.count

            let destLen = sourceLen + sourceLen / 100 + 12 + 256
            var dest = [UInt8](repeating: 0, count: destLen)
            var actualLen = UInt(destLen)

            let result = compress2(
                &dest,
                &actualLen,
                sourcePtr.baseAddress!,
                UInt(sourceLen),
                6  // compression level
            )

            guard result == 0 /* Z_OK */ else {
                throw SPZError.compressionFailed
            }

            return Data(dest.prefix(Int(actualLen)))
        }
    }
}

// Import zlib's compress2 function
@_silgen_name("compress2")
func compress2(
    _ dest: UnsafeMutablePointer<UInt8>,
    _ destLen: UnsafeMutablePointer<UInt>,
    _ source: UnsafePointer<UInt8>,
    _ sourceLen: UInt,
    _ level: Int32
) -> Int32

enum SPZError: LocalizedError {
    case emptyCloud
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .emptyCloud: return "Cannot write SPZ: cloud is empty"
        case .compressionFailed: return "Zlib compression failed"
        }
    }
}
```

---

## BUILD & TEST

After creating all files:

1. Build: `Cmd+B` (Release configuration, arm64)
2. Product location: `DerivedData/.../Build/Products/Release/ply2splat`
3. Test run:
```bash
./ply2splat --help
./ply2splat scene.ply --all scene --verbose
```

## IMPORTANT NOTES

- **No .metal files.** The Metal shader is compiled at runtime from a string in MetalTransformer.swift.
- **No SPM packages.** Everything is self-contained, only system frameworks.
- **zlib** is linked via `-lz` linker flag. The `compress2` function is imported via `@_silgen_name`.
- **All byte order is little-endian** (native on Apple Silicon).
- **GPUSplat struct** must have identical memory layout in Swift and Metal. The `_pad` field ensures 4-byte alignment after the 4 `uchar` output fields.
