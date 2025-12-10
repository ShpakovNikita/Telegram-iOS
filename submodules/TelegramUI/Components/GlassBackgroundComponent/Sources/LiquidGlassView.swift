import Foundation
import UIKit
import Metal
import MetalKit
import AppBundle
import Display

private struct LiquidGlassUniforms {
    var time: Float
    var size: simd_float2
    var tintColor: simd_float4
    var cornerRadius: Float
    var padding: Float
}

private struct LiquidGlassVertex {
    var position: simd_float4
    var texCoord: simd_float2
}

public final class LiquidGlassView: MTKView {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var textureLoader: MTKTextureLoader?
    private var texture: MTLTexture?
    
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
    
    private var time: Float = 0.0
    private var timer: CADisplayLink?
    
    public init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        
        self.setupMetal()
        
        // Setup timer for animation
        let timer = CADisplayLink(target: self, selector: #selector(self.updateTimer))
        timer.add(to: .main, forMode: .common)
        self.timer = timer
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.timer?.invalidate()
    }
    
    @objc private func updateTimer() {
        self.time += 0.016
        self.updateImageFromSourceView()
        self.setNeedsDisplay()
    }
    
    private func setupMetal() {
        guard let device = self.device else { return }
        
        self.commandQueue = device.makeCommandQueue()
        self.textureLoader = MTKTextureLoader(device: device)
        
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
    
    private func updateImageFromSourceView() {
        if self.texture != nil {
            return
        }
        
        guard let textureLoader = self.textureLoader else {
             return
        }
        
        do {
            let options: [MTKTextureLoader.Option: Any] = [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .SRGB: false,
                .generateMipmaps: false
            ]
            
            if let image = UIImage(bundleImageName: "Camera/SelfiePlaceholder"), let cgImage = image.cgImage {
                self.texture = try textureLoader.newTexture(cgImage: cgImage, options: options)
            } else {
                print("LiquidGlassView: Could not load UIImage from bundle")
            }
        } catch {
            print("LiquidGlassView Static Texture Load Error: \(error)")
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
        
        var uniforms = LiquidGlassUniforms(
            time: self.time,
            size: simd_float2(Float(self.bounds.width * self.contentScaleFactor), Float(self.bounds.height * self.contentScaleFactor)),
            tintColor: simd_float4(Float(r), Float(g), Float(b), Float(a)),
            cornerRadius: Float(self.cornerRadius * self.contentScaleFactor),
            padding: 0
        )
        
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
        renderEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<LiquidGlassUniforms>.stride, index: 1)
        
        if let texture = self.texture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
