import Foundation
import UIKit
import Display
import AsyncDisplayKit

public protocol GlassContentProvider: AnyObject {
    var contentNode: ASDisplayNode { get }
}

public final class GlassContentProviderNode: ASDisplayNode, GlassContentProvider {
    public let contentNode: ASDisplayNode
    
    public init(contentNode: ASDisplayNode) {
        self.contentNode = contentNode
        
        super.init()
        
        self.addSubnode(contentNode)
        
        // Key optimization: specific ASDK call requested by user
        self.enableSubtreeRasterization()
    }
    
    override public func layout() {
        super.layout()
        
        self.contentNode.frame = self.bounds
    }
}
