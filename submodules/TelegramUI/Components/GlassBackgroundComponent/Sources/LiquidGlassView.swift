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
    private var composePipelineState: MTLRenderPipelineState?
    private var blurHPipelineState: MTLRenderPipelineState?
    private var blurVPipelineState: MTLRenderPipelineState?
    private var intermediateTexturePass1: MTLTexture?
    private var intermediateTexturePass2: MTLTexture?
    
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
              let composeFragmentFunction = library.makeFunction(name: "liquid_glass_compose"),
              let blurHFunction = library.makeFunction(name: "liquid_glass_blur_horizontal"),
              let blurVFunction = library.makeFunction(name: "liquid_glass_blur_vertical") else {
            print("Could not find shader functions")
            return
        }
        
        // Pass 1: Compose pipeline
        let composeDescriptor = MTLRenderPipelineDescriptor()
        composeDescriptor.vertexFunction = vertexFunction
        composeDescriptor.fragmentFunction = composeFragmentFunction
        composeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm // Intermediate format
        
        // Pass 2: Horizontal blur pipeline, draws to texture pass2
        let blurHDescriptor = MTLRenderPipelineDescriptor()
        blurHDescriptor.vertexFunction = vertexFunction
        blurHDescriptor.fragmentFunction = blurHFunction
        blurHDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Pass 3: Vertical blur pipeline, draws to screen
        let blurVDescriptor = MTLRenderPipelineDescriptor()
        blurVDescriptor.vertexFunction = vertexFunction
        blurVDescriptor.fragmentFunction = blurVFunction
        blurVDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat
        
        // Enable blending for final pass
        blurVDescriptor.colorAttachments[0].isBlendingEnabled = true
        blurVDescriptor.colorAttachments[0].rgbBlendOperation = .add
        blurVDescriptor.colorAttachments[0].alphaBlendOperation = .add
        blurVDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        blurVDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blurVDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        blurVDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            self.composePipelineState = try device.makeRenderPipelineState(descriptor: composeDescriptor)
            self.blurHPipelineState = try device.makeRenderPipelineState(descriptor: blurHDescriptor)
            self.blurVPipelineState = try device.makeRenderPipelineState(descriptor: blurVDescriptor)
        } catch {
            print("Failed to create pipeline states: \(error)")
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
              let finalRenderPassDescriptor = self.currentRenderPassDescriptor,
              let composePipelineState = self.composePipelineState,
              let blurHPipelineState = self.blurHPipelineState,
              let blurVPipelineState = self.blurVPipelineState,
              let commandQueue = self.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        let width = Int(self.bounds.width * self.contentScaleFactor)
        let height = Int(self.bounds.height * self.contentScaleFactor)
        
        if self.intermediateTexturePass1?.width != width || self.intermediateTexturePass1?.height != height {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            self.intermediateTexturePass1 = self.device?.makeTexture(descriptor: textureDescriptor)
            self.intermediateTexturePass2 = self.device?.makeTexture(descriptor: textureDescriptor)
        }
        
        guard let intermediateTexturePass1 = self.intermediateTexturePass1,
              let intermediateTexturePass2 = self.intermediateTexturePass2 else { return }
        
        // Vertices
        let vertices = [
            LiquidGlassVertex(position: simd_float4(-1, -1, 0, 1), texCoord: simd_float2(0, 1)),
            LiquidGlassVertex(position: simd_float4( 1, -1, 0, 1), texCoord: simd_float2(1, 1)),
            LiquidGlassVertex(position: simd_float4(-1,  1, 0, 1), texCoord: simd_float2(0, 0)),
            LiquidGlassVertex(position: simd_float4( 1,  1, 0, 1), texCoord: simd_float2(1, 0))
        ]
        
        // Uniforms Setup
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
            size: simd_float2(Float(width), Float(height)),
            tintColor: simd_float4(Float(r), Float(g), Float(b), Float(a)),
            cornerRadius: Float(self.cornerRadius * self.contentScaleFactor),
            padding: 0,
            screenRect: screenRectIdx
        )
        
        // Helper to encode a pass
        func encodePass(pipeline: MTLRenderPipelineState, 
                        outputTexture: MTLTexture?, 
                        outputPassDescriptor: MTLRenderPassDescriptor?, // Only one of outputTexture or outputPassDescriptor
                        inputTexture: MTLTexture?, 
                        clear: Bool) {
            
            var encoder: MTLRenderCommandEncoder?
            
            if let texture = outputTexture {
                let passDescriptor = MTLRenderPassDescriptor()
                passDescriptor.colorAttachments[0].texture = texture
                passDescriptor.colorAttachments[0].loadAction = clear ? .clear : .dontCare
                passDescriptor.colorAttachments[0].storeAction = .store
                passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            } else if let descriptor = outputPassDescriptor {
                encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            }
            
            if let encoder = encoder {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<LiquidGlassVertex>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
                
                if let input = inputTexture {
                    encoder.setFragmentTexture(input, index: 0)
                }
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
        }
        
        // Pass 1: Compose, glass -> texture pass1
        encodePass(pipeline: composePipelineState,
                   outputTexture: intermediateTexturePass1, 
                   outputPassDescriptor: nil, 
                   inputTexture: LiquidGlassGlobalContext.shared.texture, 
                   clear: true)
        
        // Pass 2: Horizontal blur, texture pass1 -> texture pass2
        encodePass(pipeline: blurHPipelineState,
                   outputTexture: intermediateTexturePass2, 
                   outputPassDescriptor: nil, 
                   inputTexture: intermediateTexturePass1, 
                   clear: false)
                   
        // Pass 3: Vertical blur, texture pass2 -> screen
        encodePass(pipeline: blurVPipelineState,
                   outputTexture: nil, 
                   outputPassDescriptor: finalRenderPassDescriptor, 
                   inputTexture: intermediateTexturePass2, 
                   clear: false)
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
