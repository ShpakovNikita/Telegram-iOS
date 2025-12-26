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
    var touchPos: simd_float2
    var highlight: Float
    var padding2: Float
    var iconRect: simd_float4
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
    private var blurVPipelineStateHDR: MTLRenderPipelineState?
    // MRT Pipelines (with attachment 1)
    private var blurVPipelineStateMRT: MTLRenderPipelineState?
    private var blurVPipelineStateHDRMRT: MTLRenderPipelineState?
    private var copyPipelineState: MTLRenderPipelineState?
    
    private var intermediateTexturePass1: MTLTexture?
    private var intermediateTexturePass2: MTLTexture?
    
    public var additionalOutputTexture: MTLTexture?
    public var paddedCompositeOutputTexture: MTLTexture?
    
    public var cornerRadius: CGFloat = 0.0 {
        didSet {
            self.setNeedsDisplay()
        }
    }
    
    public var isInteractive: Bool = false
    
    private var highlightActive: Bool = false
    private var highlightPosition: CGPoint = .zero
    private var highlightIntensity: CGFloat = 0.0
    private var targetHighlightIntensity: CGFloat = 0.0
    
    private var displayLink: CADisplayLink?
    
    public func updateHighlight(active: Bool, position: CGPoint) {
        self.highlightActive = active
        if active {
            self.highlightPosition = position
        }
        
        self.targetHighlightIntensity = active ? 1.0 : 0.0
        
        if self.displayLink == nil {
            let displayLink = CADisplayLink(target: self, selector: #selector(self.displayLinkUpdate))
             displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
    }
    
    @objc private func displayLinkUpdate() {
        guard let displayLink = self.displayLink else {
            return
        }
        
        let target = self.targetHighlightIntensity
        var current = self.highlightIntensity
        
        let dt = displayLink.targetTimestamp - displayLink.timestamp
        // Frame-rate independent exponential decay
        let k: Double = 5.0
        let factor = 1.0 - exp(-k * dt)
        
        if abs(current - target) > 0.001 {
            current = current + (target - current) * factor
            self.highlightIntensity = current
            self.setNeedsDisplay()
        } else {
            current = target
            self.highlightIntensity = current
            self.setNeedsDisplay() // Ensure final frame is drawn
            
            // Stop loop if settled
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
    }
 
    public init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        
        if let layer = self.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
        }
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        
        // Optimize: Only draw when explicitly requested
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        
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
        
        // Pass 3: Vertical blur pipeline (SDR, used to switch from HDR when user is not interacting for better performance bandwidth)
        let blurVDescriptor = MTLRenderPipelineDescriptor()
        blurVDescriptor.vertexFunction = vertexFunction
        blurVDescriptor.fragmentFunction = blurVFunction
        blurVDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        blurVDescriptor.colorAttachments[0].isBlendingEnabled = true
        blurVDescriptor.colorAttachments[0].rgbBlendOperation = .add
        blurVDescriptor.colorAttachments[0].alphaBlendOperation = .add
        blurVDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        blurVDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blurVDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        blurVDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        // Pass 3: Vertical blur pipeline (HDR)
        let blurVDescriptorHDR = MTLRenderPipelineDescriptor()
        blurVDescriptorHDR.vertexFunction = vertexFunction
        blurVDescriptorHDR.fragmentFunction = blurVFunction
        blurVDescriptorHDR.colorAttachments[0].pixelFormat = .rgba16Float
        
        blurVDescriptorHDR.colorAttachments[0].isBlendingEnabled = true
        blurVDescriptorHDR.colorAttachments[0].rgbBlendOperation = .add
        blurVDescriptorHDR.colorAttachments[0].alphaBlendOperation = .add
        blurVDescriptorHDR.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        blurVDescriptorHDR.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blurVDescriptorHDR.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        blurVDescriptorHDR.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            self.composePipelineState = try device.makeRenderPipelineState(descriptor: composeDescriptor)
            self.blurHPipelineState = try device.makeRenderPipelineState(descriptor: blurHDescriptor)
            self.blurVPipelineState = try device.makeRenderPipelineState(descriptor: blurVDescriptor)
            self.blurVPipelineStateHDR = try device.makeRenderPipelineState(descriptor: blurVDescriptorHDR)
            
            // Setup MRT Pipelines Descriptors
            let blurVDescriptorMRT = blurVDescriptor.copy() as! MTLRenderPipelineDescriptor
            blurVDescriptorMRT.colorAttachments[1].pixelFormat = .rgba16Float // Ensure HDR for attachment
            blurVDescriptorMRT.colorAttachments[1].isBlendingEnabled = false
            
            let blurVDescriptorHDRMRT = blurVDescriptorHDR.copy() as! MTLRenderPipelineDescriptor
            blurVDescriptorHDRMRT.colorAttachments[1].pixelFormat = .rgba16Float // Ensure HDR for attachment
            blurVDescriptorHDRMRT.colorAttachments[1].isBlendingEnabled = false
            
            // Standard Pipelines (No MRT)
            // Uses standard function: "liquid_glass_blur_vertical"
            // No constants needed as we split entry points
            
            self.blurVPipelineState = try device.makeRenderPipelineState(descriptor: blurVDescriptor)
            self.blurVPipelineStateHDR = try device.makeRenderPipelineState(descriptor: blurVDescriptorHDR)
            
            // MRT Pipelines
            // Explicitly load the MRT variant function
            if let blurVFunctionMRT = library.makeFunction(name: "liquid_glass_blur_vertical_mrt") {
                blurVDescriptorMRT.fragmentFunction = blurVFunctionMRT
                self.blurVPipelineStateMRT = try device.makeRenderPipelineState(descriptor: blurVDescriptorMRT)
                
                blurVDescriptorHDRMRT.fragmentFunction = blurVFunctionMRT
                self.blurVPipelineStateHDRMRT = try device.makeRenderPipelineState(descriptor: blurVDescriptorHDRMRT)
            } else {
                print("Could not find liquid_glass_blur_vertical_mrt function")
                self.blurVPipelineStateHDRMRT = try device.makeRenderPipelineState(descriptor: blurVDescriptorHDRMRT)
            }
            
            // Copy Pipeline
            if let copyFunction = library.makeFunction(name: "simple_copy_fragment") {
                let copyDescriptor = MTLRenderPipelineDescriptor()
                copyDescriptor.vertexFunction = vertexFunction
                copyDescriptor.fragmentFunction = copyFunction
                copyDescriptor.colorAttachments[0].pixelFormat = .rgba16Float // We use float for composite
                // Blending enabled for compositing glass over background
                copyDescriptor.colorAttachments[0].isBlendingEnabled = true
                copyDescriptor.colorAttachments[0].rgbBlendOperation = .add
                copyDescriptor.colorAttachments[0].alphaBlendOperation = .add
                copyDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                copyDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                copyDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                copyDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                
                self.copyPipelineState = try device.makeRenderPipelineState(descriptor: copyDescriptor)
            }
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
        let requiredFormat: MTLPixelFormat = (self.highlightIntensity > 0.001 || self.targetHighlightIntensity > 0.001) ? .rgba16Float : .bgra8Unorm
        if self.colorPixelFormat != requiredFormat {
            self.colorPixelFormat = requiredFormat
            // Changing pixel format invalidates current drawable. Return and wait for next draw call.
            return
        }
        
        guard let drawable = self.currentDrawable,
              let finalRenderPassDescriptor = self.currentRenderPassDescriptor,
              let composePipelineState = self.composePipelineState,
              let blurHPipelineState = self.blurHPipelineState,
              let blurVPipelineStateSDR = self.blurVPipelineState,
              let blurVPipelineStateHDR = self.blurVPipelineStateHDR,
              let blurVPipelineStateHDRMRT = self.blurVPipelineStateHDRMRT,
              let blurVPipelineStateMRT = self.blurVPipelineStateMRT,
              let commandQueue = self.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Select pipeline based on current pixel format and MRT requirement
        let useHDR = (self.colorPixelFormat == .rgba16Float)
        let useMRT = (self.additionalOutputTexture != nil)
        
        let blurVPipelineState: MTLRenderPipelineState
        if useMRT {
            blurVPipelineState = useHDR ? blurVPipelineStateHDRMRT : blurVPipelineStateMRT
        } else {
            blurVPipelineState = useHDR ? blurVPipelineStateHDR : blurVPipelineStateSDR
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
        
        // Convert highlight position to pixels (from view coordinates)
        let xPos = min(self.frame.size.width, max(self.highlightPosition.x, 0))
        let touchPosPixels = simd_float2(Float(xPos * self.contentScaleFactor),
                                         Float(self.highlightPosition.y * self.contentScaleFactor))
        
        var uniforms = LiquidGlassUniforms(
            size: simd_float2(Float(width), Float(height)),
            tintColor: simd_float4(Float(r), Float(g), Float(b), Float(a)),
            cornerRadius: Float(self.cornerRadius * self.contentScaleFactor),
            padding: 0,
            screenRect: screenRectIdx,
            touchPos: touchPosPixels,
            highlight: Float(self.highlightIntensity),
            padding2: 0,
            iconRect: simd_float4(0, 0, 0, 0)
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
        if let outputTexture = self.additionalOutputTexture {
            finalRenderPassDescriptor.colorAttachments[1].texture = outputTexture
            finalRenderPassDescriptor.colorAttachments[1].loadAction = .clear
            finalRenderPassDescriptor.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            finalRenderPassDescriptor.colorAttachments[1].storeAction = .store
        }

        encodePass(pipeline: blurVPipelineState,
                   outputTexture: nil, 
                   outputPassDescriptor: finalRenderPassDescriptor, 
                   inputTexture: intermediateTexturePass2, 
                   clear: false)
        
        if let paddedTexture = self.paddedCompositeOutputTexture, let copyPipelineState = self.copyPipelineState {
            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = paddedTexture
            passDescriptor.colorAttachments[0].loadAction = .clear // Or .dontCare since we overwrite
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            passDescriptor.colorAttachments[0].storeAction = .store
            
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                encoder.setRenderPipelineState(copyPipelineState)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
                
                // 1. Draw Background (Padded area from Global Context)
                if let globalTexture = LiquidGlassGlobalContext.shared.texture, globalFrame.width > 0, globalFrame.height > 0 {
                    // Calculate UVs for the padded area
                    // Padded Rect in Window: boundsInWindow.insetBy(-20)
                    // We need to map this to GlobalFrame (which corresponds to globalTexture 0..1)
                    
                    let paddedWindowRect = boundsInWindow.insetBy(dx: -20.0, dy: -20.0)
                    
                    let uvX = Float((paddedWindowRect.origin.x - globalFrame.origin.x) / globalFrame.width)
                    let uvY = Float((paddedWindowRect.origin.y - globalFrame.origin.y) / globalFrame.height)
                    let uvW = Float(paddedWindowRect.width / globalFrame.width)
                    let uvH = Float(paddedWindowRect.height / globalFrame.height)
                    
                    let bgVertices = [
                        LiquidGlassVertex(position: simd_float4(-1, -1, 0, 1), texCoord: simd_float2(uvX, uvY + uvH)),
                        LiquidGlassVertex(position: simd_float4( 1, -1, 0, 1), texCoord: simd_float2(uvX + uvW, uvY + uvH)),
                        LiquidGlassVertex(position: simd_float4(-1,  1, 0, 1), texCoord: simd_float2(uvX, uvY)),
                        LiquidGlassVertex(position: simd_float4( 1,  1, 0, 1), texCoord: simd_float2(uvX + uvW, uvY))
                    ]
                    
                    encoder.setVertexBytes(bgVertices, length: bgVertices.count * MemoryLayout<LiquidGlassVertex>.stride, index: 0)
                    encoder.setFragmentTexture(globalTexture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                
                // 2. Draw Glass Output (Centered)
                if let glassOutput = self.additionalOutputTexture {
                    // Calculate Positions for Inner Quad (-1..1 space)
                    // Total Size = (Width+40, Height+40) assuming 1:1 scale for math simplcity (pixels)
                    // Padding = 20
                    // NDC is -1 to 1.
                    // Left edge (-1) corresponds to 0. Right edge (1) corresponds to Width.
                    // We want to inset by Padding.
                    // X0 = -1 + 2 * (Padding / TotalWidth)
                    // X1 =  1 - 2 * (Padding / TotalWidth)
                     
                    let totalWidth = Float(width) + 40.0 * Float(self.contentScaleFactor)
                    let totalHeight = Float(height) + 40.0 * Float(self.contentScaleFactor)
                    let padding = 20.0 * Float(self.contentScaleFactor)
                    
                    // Avoid divide by zero
                    if totalWidth > 0 && totalHeight > 0 {
                         let ndcMinX = -1.0 + 2.0 * (padding / totalWidth)
                         let ndcMaxX =  1.0 - 2.0 * (padding / totalWidth)
                         // Y in Metal is Bottom(-1) to Top(1)? Or Top(-1) to Bottom(1)?
                         // Standard strip: (-1, -1) is Bottom-Left or Top-Left depending on projection.
                         // In our case:
                         // Vertex 0: (-1, -1) -> uv (0, 1) Bottom Left
                         // Vertex 2: (-1, 1) -> uv (0, 0) Top Left
                         // So Y=-1 is Bottom. Padding from Bottom is same logic.
                         
                         let ndcMinY = -1.0 + 2.0 * (padding / totalHeight)
                         let ndcMaxY =  1.0 - 2.0 * (padding / totalHeight)
                        
                        let glassVertices = [
                            LiquidGlassVertex(position: simd_float4(ndcMinX, ndcMinY, 0, 1), texCoord: simd_float2(0, 1)),
                            LiquidGlassVertex(position: simd_float4(ndcMaxX, ndcMinY, 0, 1), texCoord: simd_float2(1, 1)),
                            LiquidGlassVertex(position: simd_float4(ndcMinX, ndcMaxY, 0, 1), texCoord: simd_float2(0, 0)),
                            LiquidGlassVertex(position: simd_float4(ndcMaxX, ndcMaxY, 0, 1), texCoord: simd_float2(1, 0))
                        ]
                        
                        encoder.setVertexBytes(glassVertices, length: glassVertices.count * MemoryLayout<LiquidGlassVertex>.stride, index: 0)
                        encoder.setFragmentTexture(glassOutput, index: 0)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    }
                }
                
                encoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
