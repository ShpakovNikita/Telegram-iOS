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
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        
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
        // Reset target to identity, spring will oscillate back
        self.targetScale = [1.0, 1.0]
        self.ensureDisplayLink()
    }
    
    private func ensureDisplayLink() {
        if self.displayLink == nil {
            let displayLink = CADisplayLink(target: self, selector: #selector(self.displayLinkTick))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
        self.isPaused = false
    }
    
    @objc private func displayLinkTick() {
        let dt: Float = 1.0 / 60.0 // Approximation, could use displayLink.duration
        
        // Spring physics: F = -k*x - c*v
        let displacement = self.scaleState - self.targetScale
        let springForce = -self.stiffness * displacement
        let dampingForce = -self.damping * self.scaleVelocity
        let acceleration = springForce + dampingForce
        
        self.scaleVelocity += acceleration * dt
        self.scaleState += self.scaleVelocity * dt
        
        // Calculate Physics Transform
        var finalTransform = CGAffineTransform(scaleX: CGFloat(self.scaleState.x), y: CGFloat(self.scaleState.y))
        
        // Apply Tracking (Parent Transform Sync)
        if let trackedView = self.trackedView, let superview = self.superview {
            // Use presentation layer for smooth animation tracking
            let presentationLayer = trackedView.layer.presentation() ?? trackedView.layer
            let presentationTransform = presentationLayer.affineTransform()
            
            // Combine scales (Physics * Tracked)
            finalTransform = presentationTransform.concatenating(finalTransform)
            
            // Update Center Position
            // To properly track, we need to convert the tracked point from the trackedView's current state to superview.
            // Converting from presentation layer to window, then to superview provides the current visual position.
            
            let targetPointInWindow = presentationLayer.convert(self.trackedLocation, to: nil)
            let targetPointInSuperview = superview.layer.convert(targetPointInWindow, from: nil)
            
            self.center = targetPointInSuperview
        }
        
        self.transform = finalTransform
        
        // Stop if settled AND tracking is idle
        let physicsSettled = length(self.scaleVelocity) < 0.001 && length(displacement) < 0.001 && length(self.targetScale - simd_float2(1,1)) < 0.001
        
        // Heuristic: If we are tracking, we only stop if the tracked view is not animating and physics is done.
        var isTrackingActive = false
        if self.trackedView != nil {
             isTrackingActive = (self.trackedView?.layer.animationKeys()?.count ?? 0) > 0
        }
        
        if physicsSettled && !isTrackingActive {
            self.scaleState = [1.0, 1.0]
            self.scaleVelocity = [0.0, 0.0]
            self.targetScale = [1.0, 1.0]
            // Only stop if we are truly done
            self.isPaused = true
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
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
