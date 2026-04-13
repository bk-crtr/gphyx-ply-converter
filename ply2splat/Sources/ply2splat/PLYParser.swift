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
    
    var shDegree: Int {
        var shRestCount = 0
        for p in properties { if p.name.hasPrefix("f_rest_") { shRestCount += 1 } }
        if shRestCount >= 45 { return 3 }
        else if shRestCount >= 24 { return 2 }
        else if shRestCount >= 9 { return 1 }
        else { return 0 }
    }
}

final class PLYParser {

    func parse(data: Data) throws -> GaussianCloud {
        let header = try getHeader(data: data)
        return try parseVertices(data, header: header)
    }
    
    func getHeader(data: Data) throws -> PLYHeader {
        return try parseHeader(data)
    }

    private func parseHeader(_ data: Data) throws -> PLYHeader {
        guard data.count > 10 else { throw PLYError.invalidHeader("File too small") }

        let maxSearch = min(data.count, 65536)
        let searchData = data[0..<maxSearch]
        
        guard let endRange = searchData.range(of: "end_header".data(using: .ascii)!) else {
            throw PLYError.invalidHeader("No end_header found")
        }
        
        var dataOffset = endRange.upperBound
        while dataOffset < data.count {
            let byte = data[dataOffset]
            dataOffset += 1
            if byte == 10 { break } // \n
        }

        let headerData = data[0..<dataOffset]
        let headerStr = String(decoding: headerData, as: UTF8.self)

        var header = PLYHeader()
        header.dataOffset = dataOffset

        let lines = headerStr.components(separatedBy: .newlines)
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

        data.withUnsafeBytes { rawBuffer in
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
