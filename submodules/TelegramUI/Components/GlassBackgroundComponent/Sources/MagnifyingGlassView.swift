import Foundation
import UIKit
import Metal
import MetalKit

// Must match SimpleUniforms in LiquidGlass.metal
private struct MagnifyingGlassUniforms {
    var size: simd_float2
    var tintColor: simd_float4
    var cornerRadius: Float
    var padding: Float // Repurposed for iconScale
    var screenRect: simd_float4
    var touchPos: simd_float2
    var highlight: Float
    var padding2: Float
    var iconRect: simd_float4
}

private struct Vertex {
    var position: simd_float4
    var uv: simd_float2
}

public final class MagnifyingGlassView: MTKView {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    
    private var currentUniforms = MagnifyingGlassUniforms(
        size: [0, 0],
        tintColor: [0, 0, 0, 0],
        cornerRadius: 0,
        padding: 1.2, // Default Icon Scale
        screenRect: [0, 0, 0, 0],
        touchPos: [0, 0],
        highlight: 0,
        padding2: 0,
        iconRect: [0, 0, 0, 0]
    )

    private var displayLink: CADisplayLink?

    
    // Physics State
    private var scaleState: simd_float2 = [1.0, 1.0]
    private var scaleVelocity: simd_float2 = [0.0, 0.0]
    private var targetScale: simd_float2 = [1.0, 1.0]
    
    // Tracking
    public weak var trackedView: UIView?
    public var trackedLocation: CGPoint = .zero
    
    // Config
    private let stiffness: Float = 300.0
    private let damping: Float = 15.0
    
    public init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        self.colorPixelFormat = .rgba16Float // HDR
        if let layer = self.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
        }
        self.framebufferOnly = true
        
        // Shadow Setup
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOffset = CGSize(width: 0.0, height: 10.0)
        self.layer.shadowRadius = 20.0
        self.layer.shadowOpacity = 0.3
        self.layer.shouldRasterize = false
        
        // Use DisplayLink for physics animation
        self.isPaused = true 
        self.enableSetNeedsDisplay = false
        
        self.setupMetal()
        self.setupVertices()
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.displayLink?.invalidate()
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
        
        // Reusing vertex function from LiquidGlass or maintaining compatible one
        // LiquidGlass also has "liquid_glass_vertex". We can use that if struct matches.
        // VertexIn in LiquidGlass: float4 position, float2 texCoord.
        // Our Vertex struct: position, uv.
        // Match names: texCoord vs uv.
        // To be safe, let's use "liquid_glass_vertex" and rename our swift struct/field to match if needed, 
        // OR rely on attribute index mapping.
        // LiquidGlass.metal uses [[buffer(0)]] for vertex array.
        // LiquidGlass VertexIn: position, texCoord.
        // We will match Vertex struct.
        
        guard let vertexFunction = library.makeFunction(name: "liquid_glass_vertex"),
              let fragmentFunction = library.makeFunction(name: "magnifying_glass_fragment") else {
            print("Could not find shader functions")
            return
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float // HDR
        
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
        
        // Update Shadow Path
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius)
        self.layer.shadowPath = path.cgPath
        
        // Trigger one frame to ensure visual update if manual
        self.draw()
    }
    
    public func update(panVelocity: CGPoint) {
        // Map X velocity to target scale
        let sensitivity: Float = 0.0005
        let maxStretch: Float = 0.2
        
        let velX = Float(panVelocity.x)
        let factor = min(abs(velX) * sensitivity, maxStretch)
        
        // Only squash/stretch on X as requested
        self.targetScale = [1.0 + factor, 1.0 - factor * 0.5]
        
        self.ensureDisplayLink()
    }
    
    public func resetPhysics() {
        self.targetScale = [1.0, 1.0]
        self.ensureDisplayLink()
    }
    
    private func ensureDisplayLink() {
        if self.displayLink == nil {
            let displayLink = CADisplayLink(target: self, selector: #selector(self.displayLinkTick))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
        self.isPaused = true
    }
    
    @objc private func displayLinkTick() {
        let dt: Float = 1.0 / 60.0
        
        let displacement = self.scaleState - self.targetScale
        let springForce = -self.stiffness * displacement
        let dampingForce = -self.damping * self.scaleVelocity
        let acceleration = springForce + dampingForce
        
        self.scaleVelocity += acceleration * dt
        self.scaleState += self.scaleVelocity * dt
        
        var finalTransform = CGAffineTransform(scaleX: CGFloat(self.scaleState.x), y: CGFloat(self.scaleState.y))
        
        if let trackedView = self.trackedView, let superview = self.superview {
            let presentationLayer = trackedView.layer.presentation() ?? trackedView.layer
            let presentationTransform = presentationLayer.affineTransform()
            
            finalTransform = presentationTransform.concatenating(finalTransform)
            
            let targetPointInWindow = presentationLayer.convert(self.trackedLocation, to: nil)
            let targetPointInSuperview = superview.layer.convert(targetPointInWindow, from: nil)
            
            self.center = targetPointInSuperview
        }
        
        self.transform = finalTransform
        
        let physicsSettled = length(self.scaleVelocity) < 0.001 && length(displacement) < 0.001 && length(self.targetScale - simd_float2(1,1)) < 0.001
        
        var isTrackingActive = false
        if self.trackedView != nil {
             isTrackingActive = (self.trackedView?.layer.animationKeys()?.count ?? 0) > 0
        }
        
        if physicsSettled && !isTrackingActive {
            self.scaleState = [1.0, 1.0]
            self.scaleVelocity = [0.0, 0.0]
            self.targetScale = [1.0, 1.0]
            self.isPaused = true
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
        
        self.draw()
    }
    
    // Textures
    public var backgroundTexture: MTLTexture?
    public var backgroundTextureFrame: CGRect?
    public var contentTexture: MTLTexture?
    
    override public func draw(_ rect: CGRect) {
        guard let drawable = self.currentDrawable,
              let renderPassDescriptor = self.currentRenderPassDescriptor,
              let pipelineState = self.pipelineState,
              let commandQueue = self.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        // Update Glass Rect
        var uniforms = self.currentUniforms
        if let backgroundTexture = self.backgroundTexture {
            let scale = CGFloat(self.contentScaleFactor)
            
            if let bgFrame = self.backgroundTextureFrame {
                let dX = self.frame.origin.x - bgFrame.origin.x
                let dY = self.frame.origin.y - bgFrame.origin.y
                
                let uvX = dX / bgFrame.width
                let uvY = dY / bgFrame.height
                let uvW = self.frame.width / bgFrame.width
                let uvH = self.frame.height / bgFrame.height
                
                uniforms.screenRect = [Float(uvX), Float(uvY), Float(uvW), Float(uvH)]
            } else {
                let textureWidth = CGFloat(backgroundTexture.width)
                let textureHeight = CGFloat(backgroundTexture.height)
                
                if textureWidth > 0 && textureHeight > 0 {
                    let x = (self.frame.origin.x * scale) / textureWidth
                    let y = (self.frame.origin.y * scale) / textureHeight
                    let w = (self.frame.width * scale) / textureWidth
                    let h = (self.frame.height * scale) / textureHeight
                    
                    uniforms.screenRect = [Float(x), Float(y), Float(w), Float(h)]
                }
            }
        }
        
        if let contentTexture = self.contentTexture {
            let scale = CGFloat(self.contentScaleFactor)
            let textureWidth = CGFloat(contentTexture.width)
            let textureHeight = CGFloat(contentTexture.height)
            
            if textureWidth > 0 && textureHeight > 0 {
                let x = (self.frame.origin.x * scale) / textureWidth
                let y = (self.frame.origin.y * scale) / textureHeight
                let w = (self.frame.width * scale) / textureWidth
                let h = (self.frame.height * scale) / textureHeight
                
                uniforms.iconRect = [Float(x), Float(y), Float(w), Float(h)]
            }
        }
        // Tint Color mapping (unused currently but consistent)
        // uniforms.tintColor...
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<MagnifyingGlassUniforms>.size, index: 1) // Buffer 1 matches LiquidGlass conventions
        
        if let vertexBuffer = self.vertexBuffer {
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0) // Buffer 0 matches LiquidGlass vertex function expectation
        }
        
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<MagnifyingGlassUniforms>.size, index: 1)
        
        // Bind Textures
        if let backgroundTexture = self.backgroundTexture {
            renderEncoder.setFragmentTexture(backgroundTexture, index: 0)
        }
        if let contentTexture = self.contentTexture {
            renderEncoder.setFragmentTexture(contentTexture, index: 1)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
