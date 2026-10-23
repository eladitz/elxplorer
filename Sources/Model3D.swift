// 3D files for the preview pane: 3MF (read here: it's a zip of XML), and the clean-up that makes
// print files (STL, OBJ, PLY, 3MF) show their shape under plain lighting, standing the right way up.

import AppKit
import SceneKit
import SceneKit.ModelIO
import ModelIO
import simd

enum Model3D {
    /// Loads any supported model as a scene, or nil if it can't be read.
    static func scene(_ url: URL) -> SCNScene? {
        let ext = url.pathExtension.lowercased()
        let scene: SCNScene?
        switch ext {
        case "3mf":
            scene = threeMF(url)
        case "stl", "obj", "ply":
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            // Many exported meshes carry no normals, and without them SceneKit draws them flat black.
            for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self)
            where mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.6)
            }
            scene = SCNScene(mdlAsset: asset)
        default:
            scene = try? SCNScene(url: url, options: [.convertToYUp: true])
        }
        guard let scene else { return nil }

        // Print files: a matte grey that reads well under the default lights (unless an OBJ has real textures).
        let isPrint = ["stl", "ply", "3mf", "obj"].contains(ext)
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let textured = geometry.materials.contains { $0.diffuse.contents is NSImage || $0.diffuse.contents is URL || $0.diffuse.contents is String }
            if geometry.materials.isEmpty || (isPrint && !textured) {
                let material = SCNMaterial()
                material.diffuse.contents = NSColor(calibratedWhite: 0.78, alpha: 1)
                material.specular.contents = NSColor(calibratedWhite: 0.25, alpha: 1)
                material.lightingModel = .blinn
                material.isDoubleSided = true
                geometry.materials = [material]
            }
        }

        // STL and 3MF use the 3D-printing convention (Z up); turn them so the print stands on its base.
        if ext == "stl" || ext == "3mf" {
            let upright = SCNNode()
            upright.eulerAngles.x = -.pi / 2
            for child in scene.rootNode.childNodes { child.removeFromParentNode(); upright.addChildNode(child) }
            scene.rootNode.addChildNode(upright)
        }
        return scene
    }

    // MARK: 3MF

    /// Every mesh in every model part (3D/3dmodel.model, and 3D/Objects/*.model in Bambu/Prusa projects).
    /// Geometry only; colours, build-plate transforms and components are ignored.
    private static func threeMF(_ url: URL) -> SCNScene? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("elxplorer-3mf-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        guard (try? fm.createDirectory(at: temp, withIntermediateDirectories: true)) != nil else { return nil }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        unzip.arguments = ["-x", "-f", url.path, "-C", temp.path, "--include", "*.model"]
        unzip.standardError = FileHandle.nullDevice
        guard (try? unzip.run()) != nil else { return nil }
        unzip.waitUntilExit()

        let scene = SCNScene()
        let walker = fm.enumerator(at: temp, includingPropertiesForKeys: nil)
        while let file = walker?.nextObject() as? URL {
            guard file.pathExtension.lowercased() == "model", let parser = XMLParser(contentsOf: file) else { continue }
            let reader = MeshReader()
            parser.delegate = reader
            parser.parse()
            for mesh in reader.meshes where !mesh.triangles.isEmpty {
                scene.rootNode.addChildNode(SCNNode(geometry: geometry(mesh)))
            }
        }
        return scene.rootNode.childNodes.isEmpty ? nil : scene
    }

    /// Flat-shaded triangles: each gets its own three corners and a face normal, which shows print facets crisply.
    private static func geometry(_ mesh: MeshReader.Mesh) -> SCNGeometry {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        positions.reserveCapacity(mesh.triangles.count * 3)
        normals.reserveCapacity(mesh.triangles.count * 3)
        for (a, b, c) in mesh.triangles {
            let p0 = mesh.vertices[a], p1 = mesh.vertices[b], p2 = mesh.vertices[c]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let length = simd_length(cross)
            let n: SIMD3<Double> = length > 0 ? cross / length : SIMD3<Double>(0, 0, 1)
            let normal = SCNVector3(CGFloat(n.x), CGFloat(n.y), CGFloat(n.z))
            for q in [p0, p1, p2] {
                positions.append(SCNVector3(CGFloat(q.x), CGFloat(q.y), CGFloat(q.z)))
                normals.append(normal)
            }
        }
        let element = SCNGeometryElement(indices: Array(0..<Int32(positions.count)), primitiveType: .triangles)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)], elements: [element])
    }

    final class MeshReader: NSObject, XMLParserDelegate {
        struct Mesh {
            var vertices: [SIMD3<Double>] = []
            var triangles: [(Int, Int, Int)] = []
        }
        var meshes: [Mesh] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            switch name.split(separator: ":").last {
            case "mesh":
                meshes.append(Mesh())
            case "vertex":
                guard !meshes.isEmpty else { return }
                let x = Double(a["x"] ?? "") ?? 0, y = Double(a["y"] ?? "") ?? 0, z = Double(a["z"] ?? "") ?? 0
                meshes[meshes.count - 1].vertices.append(SIMD3<Double>(x, y, z))
            case "triangle":
                guard !meshes.isEmpty, let i = Int(a["v1"] ?? ""), let j = Int(a["v2"] ?? ""), let k = Int(a["v3"] ?? "") else { return }
                let count = meshes[meshes.count - 1].vertices.count
                if max(i, j, k) < count { meshes[meshes.count - 1].triangles.append((i, j, k)) }
            default:
                break
            }
        }
    }
}
