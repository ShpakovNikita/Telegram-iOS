import Foundation
import UIKit
import Metal
import MetalKit
import Display

public final class LiquidGlassGlobalContext: NSObject {
    public static let willSnapshotNotification = Notification.Name("LiquidGlassWillSnapshotNotification")
    public static let didSnapshotNotification = Notification.Name("LiquidGlassDidSnapshotNotification")
    
    public static let shared = LiquidGlassGlobalContext()
    public static let useMainThreadRendering = true
    
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
    
    private func drawInBackgroundThread(captureRect: CGRect, window: UIWindow) {
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
                    
                    for view in self.activeViews.allObjects {
                        view.setNeedsDisplay()
                    }
                }
            }
        }
    }
    
    private var reusableContext: CGContext?
    private var reusableContextSize: CGSize = .zero
    
    private func drawInMainThread(captureRect: CGRect, window: UIWindow) {
        self.isProcessing = true
        let captureScale: CGFloat = 1.0
        let bufferWidth = Int(captureRect.width * captureScale)
        let bufferHeight = Int(captureRect.height * captureScale)
        
        if bufferWidth <= 0 || bufferHeight <= 0 {
            self.isProcessing = false
            return
        }
        
        let targetSize = CGSize(width: bufferWidth, height: bufferHeight)
        
        if self.reusableContextSize != targetSize || self.reusableContext == nil {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            
            self.reusableContext = CGContext(data: nil,
                                           width: bufferWidth,
                                           height: bufferHeight,
                                           bitsPerComponent: 8,
                                           bytesPerRow: bufferWidth * 4,
                                           space: colorSpace,
                                           bitmapInfo: bitmapInfo)
            
            self.reusableContext?.translateBy(x: 0, y: CGFloat(bufferHeight))
            self.reusableContext?.scaleBy(x: 1.0, y: -1.0)
            self.reusableContext?.scaleBy(x: captureScale, y: captureScale)
            self.reusableContextSize = targetSize
        }
        
        guard let context = self.reusableContext else {
            self.isProcessing = false
            return
        }
        
        context.clear(CGRect(origin: .zero, size: targetSize))
        
        // Hide glass views during capture to avoid capturing the glass itself and its content
        let viewsToHide = self.activeViews.allObjects.compactMap { view -> UIView? in
            if let superview = view.superview as? GlassBackgroundView {
                return superview
            }
            return nil
        }
        
        for view in viewsToHide {
            view.isHidden = true
        }
        
        context.saveGState()
        context.translateBy(x: -captureRect.origin.x, y: -captureRect.origin.y)
        
        NotificationCenter.default.post(name: LiquidGlassGlobalContext.willSnapshotNotification, object: nil)
        window.layer.render(in: context)
        NotificationCenter.default.post(name: LiquidGlassGlobalContext.didSnapshotNotification, object: nil)
        
        context.restoreGState()
        
        for view in viewsToHide {
            view.isHidden = false
        }
        
        if let originalImage = context.makeImage(), let textureLoader = self.textureLoader {
            do {
                let options: [MTKTextureLoader.Option: Any] = [
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .SRGB: false,
                    .generateMipmaps: false
                ]
                let newTexture = try textureLoader.newTexture(cgImage: originalImage, options: options)
                
                self.texture = newTexture
                self.globalFrame = captureRect
                
                for view in self.activeViews.allObjects {
                    view.setNeedsDisplay()
                }
            } catch {
                print("LiquidGlassGlobalContext Error: \(error)")
            }
        }
        
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
        
        
        
        if LiquidGlassGlobalContext.useMainThreadRendering {
            drawInMainThread(captureRect: captureRect, window: window)
        } else {
            drawInBackgroundThread(captureRect: captureRect, window: window)
        }
    }
}
