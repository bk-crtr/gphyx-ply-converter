import Foundation
import ModelIO
import simd

class MeshConverter {

    /// Converts a 3D mesh (GLB/OBJ/USDZ) to a GaussianCloud
    func convert(url: URL, progress: ((Double) -> Void)? = nil) throws -> GaussianCloud {

        let asset = MDLAsset(url: url)
        asset.loadTextures()

        var splats: [GaussianSplat] = []

        for i in 0..<asset.count {
            let object = asset.object(at: i)       // non-optional on macOS 14+
            if let mesh = object as? MDLMesh {
                processMesh(mesh, into: &splats)
            }
            progress?(Double(i + 1) / Double(max(asset.count, 1)))
        }

        // Recurse into children of the first root object
        if asset.count > 0 {
            traverse(asset.object(at: 0), into: &splats)
        }

        if splats.isEmpty {
            throw ConversionError.noGeometry
        }

        return GaussianCloud(splats: splats, shDegree: 0, isTransformed: true)
    }

    private func traverse(_ parent: MDLObject, into splats: inout [GaussianSplat]) {
        for child in parent.children.objects {
            if let mesh = child as? MDLMesh {
                processMesh(mesh, into: &splats)
            }
            traverse(child, into: &splats)
        }
    }

    private func processMesh(_ mesh: MDLMesh, into splats: inout [GaussianSplat]) {
        guard let vertexBuffer = mesh.vertexBuffers.first else { return }

        let vertexCount = mesh.vertexCount
        let descriptor = mesh.vertexDescriptor

        var positionOffset = -1
        var colorOffset = -1
        var stride = 0

        for attr in descriptor.attributes {
            guard let attr = attr as? MDLVertexAttribute else { continue }
            if attr.name == MDLVertexAttributePosition { positionOffset = attr.offset }
            if attr.name == MDLVertexAttributeColor    { colorOffset    = attr.offset }
        }

        for layout in descriptor.layouts {
            guard let layout = layout as? MDLVertexBufferLayout else { continue }
            if layout.stride > 0 { stride = layout.stride }
        }

        guard positionOffset >= 0, stride > 0 else { return }

        let rawData = vertexBuffer.map().bytes

        for i in 0..<vertexCount {
            let base = rawData.advanced(by: i * stride)

            let posPtr = base.advanced(by: positionOffset).assumingMemoryBound(to: Float.self)
            let position = SIMD3<Float>(posPtr[0], posPtr[1], posPtr[2])

            var r: Float = 0.5, g: Float = 0.5, b: Float = 0.5
            if colorOffset >= 0 {
                let colPtr = base.advanced(by: colorOffset).assumingMemoryBound(to: Float.self)
                r = colPtr[0]; g = colPtr[1]; b = colPtr[2]
            }

            let color = SIMD4<UInt8>(
                UInt8(clamping: Int(r * 255)),
                UInt8(clamping: Int(g * 255)),
                UInt8(clamping: Int(b * 255)),
                255
            )

            let splat = GaussianSplat(
                position: position,
                scale: SIMD3<Float>(0.01, 0.01, 0.01),     // small but visible
                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                opacity: 1.0,
                color: color,
                shDC: SIMD3<Float>(r, g, b),
                shRest: []
            )

            splats.append(splat)
        }
    }

    enum ConversionError: Error {
        case noGeometry
        case unsupportedFormat
    }
}
