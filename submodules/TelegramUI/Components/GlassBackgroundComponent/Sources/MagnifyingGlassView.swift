import Foundation
import UIKit
import Metal
import MetalKit

private struct MagnifyingGlassUniforms {
    var size: simd_float2
    var cornerRadius: Float
    var padding: simd_float2
}

private struct Vertex {
    var position: simd_float4
    var uv: simd_float2
}

public final class MagnifyingGlassView: MTKView {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    
    private var currentUniforms = MagnifyingGlassUniforms(size: [0, 0], cornerRadius: 0, padding: [0, 0])
    
    public init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        
        // Only render on demand
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        
        self.setupMetal()
        self.setupVertices()
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupVertices() {
        guard let device = self.device else { return }
        
        let vertices: [Vertex] = [
            Vertex(position: [-1.0, -1.0, 0.0, 1.0], uv: [0.0, 1.0]),
            Vertex(position: [ 1.0, -1.0, 0.0, 1.0], uv: [1.0, 1.0]),
            Vertex(position: [-1.0,  1.0, 0.0, 1.0], uv: [0.0, 0.0]),
            Vertex(position: [ 1.0,  1.0, 0.0, 1.0], uv: [1.0, 0.0])
        ]
        
        self.vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Vertex>.stride, options: [])
    }
    
    private func setupMetal() {
        guard let device = self.device else { return }
        
        self.commandQueue = device.makeCommandQueue()
        
        let bundleName = "GlassBackgroundComponentBundle"
        
        guard let bundlePath = Bundle(for: MagnifyingGlassView.self).path(forResource: bundleName, ofType: "bundle"),
              let bundle = Bundle(path: bundlePath) else {
            print("Could not find bundle \(bundleName)")
            return
        }
        
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            print("Could not load default library from bundle")
            return
        }
        
        guard let vertexFunction = library.makeFunction(name: "magnifying_glass_vertex"),
              let fragmentFunction = library.makeFunction(name: "magnifying_glass_fragment") else {
            print("Could not find shader functions")
            return
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state: \(error)")
        }
    }
    
    public func update(size: CGSize, cornerRadius: CGFloat) {
        let scale = Float(self.contentScaleFactor)
        self.currentUniforms.size = [Float(size.width) * scale, Float(size.height) * scale]
        self.currentUniforms.cornerRadius = Float(cornerRadius) * scale
        
        self.setNeedsDisplay()
    }
    
    override public func draw(_ rect: CGRect) {
        guard let drawable = self.currentDrawable,
              let renderPassDescriptor = self.currentRenderPassDescriptor,
              let pipelineState = self.pipelineState,
              let commandQueue = self.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        var uniforms = self.currentUniforms
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<MagnifyingGlassUniforms>.size, index: 0)
        
        if let vertexBuffer = self.vertexBuffer {
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
        }
        
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MagnifyingGlassUniforms>.size, index: 0)
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
