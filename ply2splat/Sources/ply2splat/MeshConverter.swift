import Foundation
import ModelIO
import MetalKit
import simd

class MeshConverter {

    private func debugLog(_ message: String) {
        let log = "/tmp/gphyx_converter.log"
        let line = "\(Date()): \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: log) {
                if let handle = FileHandle(forWritingAtPath: log) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: log))
            }
        }
    }

    /// Converts a 3D mesh (GLB/OBJ/USDZ) to a GaussianCloud
    func convert(url: URL, progress: ((Double) -> Void)? = nil) throws -> GaussianCloud {
        debugLog("MeshConverter: Opening asset at \(url.path)")
        
        debugLog("MeshConverter: URL exists = \(FileManager.default.fileExists(atPath: url.path))")
        debugLog("MeshConverter: File extension = \(url.pathExtension)")
        debugLog("Supported extensions: \(MDLAsset.canImportFileExtension("obj") ? "obj YES" : "obj NO")")
        debugLog("Supported extensions: \(MDLAsset.canImportFileExtension("usdz") ? "usdz YES" : "usdz NO")")
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            debugLog("MeshConverter: Error - Could not create Metal Device.")
            throw ConversionError.unsupportedFormat
        }
        
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
        asset.loadTextures()
        
        debugLog("MeshConverter: Asset class = \(type(of: asset))")
        debugLog("MeshConverter: Asset count = \(asset.count)")
        
        var splats: [GaussianSplat] = []

        for i in 0..<asset.count {
            let object = asset.object(at: i)
            debugLog("MeshConverter: Processing top-level object \(i): \(object.name)")
            
            processAndTraverse(object, into: &splats)
            
            progress?(Double(i + 1) / Double(max(asset.count, 1)))
        }

        debugLog("MeshConverter: Finished conversion. Total splats extracted: \(splats.count)")

        if splats.isEmpty {
            debugLog("MeshConverter: Error - No geometry found in asset.")
            throw ConversionError.noGeometry
        }

        return GaussianCloud(splats: splats, shDegree: 0, isTransformed: true)
    }

    private func processAndTraverse(_ object: MDLObject, into splats: inout [GaussianSplat]) {
        if let mesh = object as? MDLMesh {
            debugLog("MeshConverter: Found Mesh object: \(object.name)")
            processMesh(mesh, into: &splats)
        } else {
            debugLog("MeshConverter: Object \(object.name) is not a MDLMesh (type: \(type(of: object)))")
        }
        
        if let children = object.children as? MDLObjectContainer {
            let childObjects = children.objects
            if !childObjects.isEmpty {
                debugLog("MeshConverter: Traversing \(childObjects.count) children of \(object.name)")
                for child in childObjects {
                    processAndTraverse(child, into: &splats)
                }
            }
        }
    }

    private func processMesh(_ mesh: MDLMesh, into splats: inout [GaussianSplat]) {
        guard let vertexBuffer = mesh.vertexBuffers.first else { 
            debugLog("MeshConverter: Warning - Mesh \(mesh.name) has no vertex buffers.")
            return 
        }

        let vertexCount = mesh.vertexCount
        let descriptor = mesh.vertexDescriptor
        
        debugLog("MeshConverter: Processing Mesh \(mesh.name) with \(vertexCount) vertices.")

        var positionOffset = -1
        var colorOffset = -1
        var stride = 0

        for attr in descriptor.attributes {
            guard let attr = attr as? MDLVertexAttribute else { continue }
            if attr.name == MDLVertexAttributePosition { 
                positionOffset = attr.offset 
                debugLog("MeshConverter: Found Position attribute at offset \(attr.offset)")
            }
            if attr.name == MDLVertexAttributeColor { 
                colorOffset = attr.offset 
                debugLog("MeshConverter: Found Color attribute at offset \(attr.offset)")
            }
        }

        for layout in descriptor.layouts {
            guard let layout = layout as? MDLVertexBufferLayout else { continue }
            if layout.stride > 0 { 
                stride = layout.stride 
                debugLog("MeshConverter: Found Layout with stride \(stride)")
            }
        }

        guard positionOffset >= 0, stride > 0 else { 
            debugLog("MeshConverter: Warning - Mesh \(mesh.name) missing position attribute or stride is 0.")
            return 
        }

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
                scale: SIMD3<Float>(-4.0, -4.0, -4.0),
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
