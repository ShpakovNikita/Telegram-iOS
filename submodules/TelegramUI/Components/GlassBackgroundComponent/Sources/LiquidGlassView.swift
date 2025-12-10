import Foundation
import UIKit
import Metal
import MetalKit
import AppBundle
import Display

private struct LiquidGlassUniforms {
    var size: simd_float2
    var tintColor: simd_float4
    var cornerRadius: Float
    var padding: Float
    var screenRect: simd_float4
}

private struct LiquidGlassVertex {
    var position: simd_float4
    var texCoord: simd_float2
}

public final class LiquidGlassView: MTKView {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    
    public var cornerRadius: CGFloat = 0.0 {
        didSet {
            self.setNeedsDisplay()
        }
    }
    
    public override var tintColor: UIColor? {
        didSet {
            self.setNeedsDisplay()
        }
    }
    
    public init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        
        self.setupMetal()
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil {
            LiquidGlassGlobalContext.shared.add(self)
        } else {
            LiquidGlassGlobalContext.shared.remove(self)
        }
    }
    
    private func setupMetal() {
        guard let device = self.device else { return }
        
        self.commandQueue = device.makeCommandQueue()
        
        let bundleName = "GlassBackgroundComponentBundle"
        
        guard let bundlePath = Bundle(for: LiquidGlassView.self).path(forResource: bundleName, ofType: "bundle"),
              let bundle = Bundle(path: bundlePath) else {
            print("Could not find bundle \(bundleName)")
            return
        }
        
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            print("Could not load default library from bundle")
            return
        }
        
        guard let vertexFunction = library.makeFunction(name: "liquid_glass_vertex"),
              let fragmentFunction = library.makeFunction(name: "liquid_glass_fragment") else {
            print("Could not find shader functions")
            return
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat
        
        // Enable blending
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
    
    override public func draw(_ layer: CALayer, in ctx: CGContext) {
        if LiquidGlassGlobalContext.shared.isCapturing {
            // Be transparent during snapshot to avoid recursive reflection
            return
        }
        super.draw(layer, in: ctx)
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
        
        // Vertices for a full-quad
        let vertices = [
            LiquidGlassVertex(position: simd_float4(-1, -1, 0, 1), texCoord: simd_float2(0, 1)),
            LiquidGlassVertex(position: simd_float4( 1, -1, 0, 1), texCoord: simd_float2(1, 1)),
            LiquidGlassVertex(position: simd_float4(-1,  1, 0, 1), texCoord: simd_float2(0, 0)),
            LiquidGlassVertex(position: simd_float4( 1,  1, 0, 1), texCoord: simd_float2(1, 0))
        ]
        
        renderEncoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<LiquidGlassVertex>.stride, index: 0)
        
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.tintColor?.getRed(&r, green: &g, blue: &b, alpha: &a)
        
        var screenRectIdx = simd_float4(0, 0, 1, 1)
        let boundsInWindow = self.convert(self.bounds, to: nil)
        let globalFrame = LiquidGlassGlobalContext.shared.globalFrame
        
        if globalFrame.width > 0 && globalFrame.height > 0 {
            screenRectIdx = simd_float4(
                Float((boundsInWindow.origin.x - globalFrame.origin.x) / globalFrame.width),
                Float((boundsInWindow.origin.y - globalFrame.origin.y) / globalFrame.height),
                Float(boundsInWindow.size.width / globalFrame.width),
                Float(boundsInWindow.size.height / globalFrame.height)
            )
        }
        
        var uniforms = LiquidGlassUniforms(
            size: simd_float2(Float(self.bounds.width * self.contentScaleFactor), Float(self.bounds.height * self.contentScaleFactor)),
            tintColor: simd_float4(Float(r), Float(g), Float(b), Float(a)),
            cornerRadius: Float(self.cornerRadius * self.contentScaleFactor),
            padding: 0,
            screenRect: screenRectIdx
        )
        
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
        
        if let texture = LiquidGlassGlobalContext.shared.texture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
