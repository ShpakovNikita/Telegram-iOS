import Foundation
import UIKit
import Metal
import MetalKit
import Display

public final class LiquidGlassGlobalContext: NSObject {
    public static let shared = LiquidGlassGlobalContext()
    
    private var timer: CADisplayLink?
    private var activeViews = NSHashTable<LiquidGlassView>.weakObjects()
    
    public private(set) var texture: MTLTexture?
    public private(set) var globalFrame: CGRect = .zero
    private var textureLoader: MTKTextureLoader?
    
    private let queue = DispatchQueue(label: "org.telegram.LiquidGlassGlobalContext", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private var isProcessing = false
    
    public var isCapturing: Bool {
        return DispatchQueue.getSpecific(key: self.queueKey) != nil
    }
    
    private override init() {
        super.init()
        
        self.queue.setSpecific(key: self.queueKey, value: ())
        
        let device = MTLCreateSystemDefaultDevice()
        if let device = device {
            self.textureLoader = MTKTextureLoader(device: device)
        }
    }
    
    public func add(_ view: LiquidGlassView) {
        if self.activeViews.count == 0 {
            self.startTimer()
        }
        self.activeViews.add(view)
    }
    
    public func remove(_ view: LiquidGlassView) {
        self.activeViews.remove(view)
        if self.activeViews.count == 0 {
            self.stopTimer()
        }
    }
    
    private func startTimer() {
        if self.timer == nil {
            let timer = CADisplayLink(target: self, selector: #selector(self.update))
            timer.add(to: .main, forMode: .common)
            self.timer = timer
        }
    }
    
    private func stopTimer() {
        self.timer?.invalidate()
        self.timer = nil
        self.texture = nil
        self.isProcessing = false
    }
    
    @objc private func update() {
        guard let anyView = self.activeViews.allObjects.first, let window = anyView.window else {
            return
        }
        
        if self.isProcessing {
            return
        }
        
        let views = self.activeViews.allObjects
        var unionRect: CGRect?
        
        for view in views {
            let viewFrameInWindow = view.convert(view.bounds, to: window)
            if let current = unionRect {
                unionRect = current.union(viewFrameInWindow)
            } else {
                unionRect = viewFrameInWindow
            }
        }
        
        guard var captureRect = unionRect else { return }
        
        captureRect = captureRect.intersection(window.bounds)
        if captureRect.isEmpty { return }
        
        self.isProcessing = true
        
        let captureGLContext = self
        
        self.queue.async {
            // Optimization: 0.5 scale
            let captureScale: CGFloat = 0.5
            
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = captureScale
            
            let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
            let image = renderer.image { context in
                context.cgContext.translateBy(x: -captureRect.origin.x, y: -captureRect.origin.y)
                
                // Should be safe for AsyncDisplayKit
                window.layer.render(in: context.cgContext)
            }
            
            var newTexture: MTLTexture?
            
            if let originalImage = image.cgImage, let textureLoader = captureGLContext.textureLoader {
                // Sanitation, TODO: remove later
                let width = originalImage.width
                let height = originalImage.height
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                
                if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) {
                    
                    context.draw(originalImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                    
                    if let sanitizedImage = context.makeImage() {
                        do {
                            let options: [MTKTextureLoader.Option: Any] = [
                                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                                .SRGB: false,
                                .generateMipmaps: false
                            ]
                            newTexture = try textureLoader.newTexture(cgImage: sanitizedImage, options: options)
                        } catch {
                            print("LiquidGlassGlobalContext Error: \(error)")
                        }
                    }
                }
            }
            
            DispatchQueue.main.async {
                captureGLContext.isProcessing = false
                
                if let newTexture = newTexture {
                    captureGLContext.texture = newTexture
                    captureGLContext.globalFrame = captureRect
                    
                    for view in views {
                        view.setNeedsDisplay()
                    }
                }
            }
        }
    }
}
