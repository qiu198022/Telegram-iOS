import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import TextSelectionNode
import TelegramCore
import SwiftSignalKit
import ReactionSelectionNode

final class ContextControllerExtractedPresentationNode: ASDisplayNode, ContextControllerPresentationNode, UIScrollViewDelegate {
    private final class ContentNode: ASDisplayNode {
        let offsetContainerNode: ASDisplayNode
        let containingNode: ContextExtractedContentContainingNode
        
        var animateClippingFromContentAreaInScreenSpace: CGRect?
        var storedGlobalFrame: CGRect?
        
        init(containingNode: ContextExtractedContentContainingNode) {
            self.offsetContainerNode = ASDisplayNode()
            self.containingNode = containingNode
            
            super.init()
            
            self.addSubnode(self.offsetContainerNode)
        }
        
        func update(presentationData: PresentationData, size: CGSize, transition: ContainedViewLayoutTransition) {
        }
        
        func takeContainingNode() {
            if self.containingNode.contentNode.supernode !== self.offsetContainerNode {
                self.offsetContainerNode.addSubnode(self.containingNode.contentNode)
            }
        }
        
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if !self.bounds.contains(point) {
                return nil
            }
            if !self.containingNode.contentRect.contains(point) {
                return nil
            }
            return self.view
        }
    }
    
    private final class AnimatingOutState {
        var currentContentScreenFrame: CGRect
        
        init(
            currentContentScreenFrame: CGRect
        ) {
            self.currentContentScreenFrame = currentContentScreenFrame
        }
    }
    
    private let getController: () -> ContextControllerProtocol?
    private let requestUpdate: (ContainedViewLayoutTransition) -> Void
    private let requestDismiss: (ContextMenuActionResult) -> Void
    private let requestAnimateOut: (ContextMenuActionResult, @escaping () -> Void) -> Void
    private let source: ContextExtractedContentSource
    
    private let backgroundNode: NavigationBackgroundNode
    private let dismissTapNode: ASDisplayNode
    private let dismissAccessibilityArea: AccessibilityAreaNode
    private let clippingNode: ASDisplayNode
    private let scrollNode: ASScrollNode
    
    private var reactionContextNode: ReactionContextNode?
    private var reactionContextNodeIsAnimatingOut: Bool = false
    
    private var contentNode: ContentNode?
    private let contentRectDebugNode: ASDisplayNode
    private let actionsStackNode: ContextControllerActionsStackNode
    
    private var animatingOutState: AnimatingOutState?
    
    private var strings: PresentationStrings?
    
    init(
        getController: @escaping () -> ContextControllerProtocol?,
        requestUpdate: @escaping (ContainedViewLayoutTransition) -> Void,
        requestDismiss: @escaping (ContextMenuActionResult) -> Void,
        requestAnimateOut: @escaping (ContextMenuActionResult, @escaping () -> Void) -> Void,
        source: ContextExtractedContentSource
    ) {
        self.getController = getController
        self.requestUpdate = requestUpdate
        self.requestDismiss = requestDismiss
        self.requestAnimateOut = requestAnimateOut
        self.source = source
        
        self.backgroundNode = NavigationBackgroundNode(color: .clear, enableBlur: false)
        
        self.dismissTapNode = ASDisplayNode()
        
        self.dismissAccessibilityArea = AccessibilityAreaNode()
        self.dismissAccessibilityArea.accessibilityTraits = .button
        
        self.clippingNode = ASDisplayNode()
        self.clippingNode.clipsToBounds = true
        
        self.scrollNode = ASScrollNode()
        self.scrollNode.canCancelAllTouchesInViews = true
        self.scrollNode.view.delaysContentTouches = false
        self.scrollNode.view.showsVerticalScrollIndicator = false
        if #available(iOS 11.0, *) {
            self.scrollNode.view.contentInsetAdjustmentBehavior = .never
        }
        
        self.contentRectDebugNode = ASDisplayNode()
        self.contentRectDebugNode.isUserInteractionEnabled = false
        self.contentRectDebugNode.backgroundColor = UIColor.red.withAlphaComponent(0.2)
        
        self.actionsStackNode = ContextControllerActionsStackNode(
            getController: getController,
            requestDismiss: { result in
                requestDismiss(result)
            },
            requestUpdate: requestUpdate
        )
        
        super.init()
        
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.clippingNode)
        self.clippingNode.addSubnode(self.scrollNode)
        self.scrollNode.addSubnode(self.dismissTapNode)
        self.scrollNode.addSubnode(self.dismissAccessibilityArea)
        self.scrollNode.addSubnode(self.actionsStackNode)
        
        /*#if DEBUG
        self.scrollNode.addSubnode(self.contentRectDebugNode)
        #endif*/
        
        self.scrollNode.view.delegate = self
        
        self.dismissTapNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dismissTapGesture(_:))))
        
        self.dismissAccessibilityArea.activate = { [weak self] in
            self?.requestDismiss(.default)
            
            return true
        }
    }
    
    @objc func dismissTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.requestDismiss(.default)
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.bounds.contains(point) {
            if let reactionContextNode = self.reactionContextNode {
                if let result = reactionContextNode.hitTest(self.view.convert(point, to: reactionContextNode.view), with: event) {
                    return result
                }
            }
            
            if !self.source.ignoreContentTouches, let contentNode = self.contentNode {
                let contentPoint = self.view.convert(point, to: contentNode.containingNode.contentNode.view)
                if let result = contentNode.containingNode.contentNode.customHitTest?(contentPoint) {
                    return result
                } else if let result = contentNode.containingNode.contentNode.hitTest(contentPoint, with: event) {
                    if result is TextSelectionNodeView {
                        return result
                    } else if contentNode.containingNode.contentRect.contains(contentPoint) {
                        return contentNode.containingNode.contentNode.view
                    }
                }
            }
            
            return self.scrollNode.hitTest(self.view.convert(point, to: self.scrollNode.view), with: event)
        } else {
            return nil
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let reactionContextNode = self.reactionContextNode {
            let isIntersectingContent = scrollView.contentOffset.y >= 10.0
            reactionContextNode.updateIsIntersectingContent(isIntersectingContent: isIntersectingContent, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
    }
    
    func highlightGestureMoved(location: CGPoint) {
        self.actionsStackNode.highlightGestureMoved(location: self.view.convert(location, to: self.actionsStackNode.view))
        
        if let reactionContextNode = self.reactionContextNode {
            reactionContextNode.highlightGestureMoved(location: self.view.convert(location, to: reactionContextNode.view))
        }
    }
    
    func highlightGestureFinished(performAction: Bool) {
        self.actionsStackNode.highlightGestureFinished(performAction: performAction)
        
        if let reactionContextNode = self.reactionContextNode {
            reactionContextNode.highlightGestureFinished(performAction: performAction)
        }
    }
    
    func replaceItems(items: ContextController.Items, animated: Bool) {
        self.actionsStackNode.replace(item: makeContextControllerActionsStackItem(items: items), animated: animated)
    }
    
    func pushItems(items: ContextController.Items) {
        let currentScrollingState = self.getCurrentScrollingState()
        let positionLock = self.getActionsStackPositionLock()
        self.actionsStackNode.push(item: makeContextControllerActionsStackItem(items: items), currentScrollingState: currentScrollingState, positionLock: positionLock, animated: true)
    }
    
    func popItems() {
        self.actionsStackNode.pop()
    }
    
    private func getCurrentScrollingState() -> CGFloat {
        return self.scrollNode.view.contentOffset.y
    }
    
    private func getActionsStackPositionLock() -> CGFloat? {
        return self.actionsStackNode.view.convert(CGPoint(), to: self.view).y
    }
    
    func update(
        presentationData: PresentationData,
        layout: ContainerViewLayout,
        transition: ContainedViewLayoutTransition,
        stateTransition: ContextControllerPresentationNodeStateTransition?
    ) {
        let contentActionsSpacing: CGFloat = 7.0
        let actionsEdgeInset: CGFloat = 12.0
        let actionsSideInset: CGFloat = 6.0
        let topInset: CGFloat = layout.insets(options: .statusBar).top + 8.0
        let bottomInset: CGFloat = 10.0
        
        let contentNode: ContentNode
        var contentTransition = transition
        
        if self.strings !== presentationData.strings {
            self.strings = presentationData.strings
            
            self.dismissAccessibilityArea.accessibilityLabel = presentationData.strings.VoiceOver_DismissContextMenu
        }
        
        self.backgroundNode.updateColor(
            color: presentationData.theme.contextMenu.dimColor,
            enableBlur: true,
            forceKeepBlur: true,
            transition: .immediate
        )
        
        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(), size: layout.size), beginWithCurrentState: true)
        self.backgroundNode.update(size: layout.size, transition: transition)
        
        transition.updateFrame(node: self.clippingNode, frame: CGRect(origin: CGPoint(), size: layout.size), beginWithCurrentState: true)
        if self.scrollNode.frame != CGRect(origin: CGPoint(), size: layout.size) {
            transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: layout.size), beginWithCurrentState: true)
        }
        
        if let current = self.contentNode {
            contentNode = current
        } else {
            guard let takeInfo = self.source.takeView() else {
                return
            }
            contentNode = ContentNode(containingNode: takeInfo.contentContainingNode)
            contentNode.animateClippingFromContentAreaInScreenSpace = takeInfo.contentAreaInScreenSpace
            self.scrollNode.insertSubnode(contentNode, aboveSubnode: self.actionsStackNode)
            self.contentNode = contentNode
            contentTransition = .immediate
        }
        
        var animateReactionsIn = false
        var contentTopInset: CGFloat = topInset
        var removedReactionContextNode: ReactionContextNode?
        if let reactionItems = self.actionsStackNode.topReactionItems, !reactionItems.reactionItems.isEmpty {
            if self.reactionContextNode == nil {
                let reactionContextNode = ReactionContextNode(context: reactionItems.context, theme: presentationData.theme, items: reactionItems.reactionItems)
                self.reactionContextNode = reactionContextNode
                self.addSubnode(reactionContextNode)
                
                if transition.isAnimated {
                    animateReactionsIn = true
                }
                
                reactionContextNode.reactionSelected = { [weak self] reaction in
                    guard let strongSelf = self, let controller = strongSelf.getController() as? ContextController else {
                        return
                    }
                    controller.reactionSelected?(reaction)
                }
            }
            contentTopInset += 70.0
        } else if let reactionContextNode = self.reactionContextNode {
            self.reactionContextNode = nil
            removedReactionContextNode = reactionContextNode
        }
        
        switch stateTransition {
        case .animateIn, .animateOut:
            contentNode.storedGlobalFrame = convertFrame(contentNode.containingNode.contentRect, from: contentNode.containingNode.view, to: self.view)
        case .none:
            if contentNode.storedGlobalFrame == nil {
                contentNode.storedGlobalFrame = convertFrame(contentNode.containingNode.contentRect, from: contentNode.containingNode.view, to: self.view)
            }
        }
        
        let contentParentGlobalFrame = convertFrame(contentNode.containingNode.bounds, from: contentNode.containingNode.view, to: self.view)
        
        let contentRectGlobalFrame = CGRect(origin: CGPoint(x: contentNode.containingNode.contentRect.minX, y: (contentNode.storedGlobalFrame?.maxY ?? 0.0) - contentNode.containingNode.contentRect.height), size: contentNode.containingNode.contentRect.size)
        var contentRect = CGRect(origin: CGPoint(x: contentRectGlobalFrame.minX, y: contentRectGlobalFrame.maxY - contentNode.containingNode.contentRect.size.height), size: contentNode.containingNode.contentRect.size)
        if case .animateOut = stateTransition {
            contentRect.origin.y = self.contentRectDebugNode.frame.maxY - contentRect.size.height
        }
        
        var defaultScrollY: CGFloat = 0.0
        if self.animatingOutState == nil {
            contentNode.update(
                presentationData: presentationData,
                size: contentNode.containingNode.bounds.size,
                transition: contentTransition
            )
            
            let actionsConstrainedHeight: CGFloat
            if let actionsPositionLock = self.actionsStackNode.topPositionLock {
                actionsConstrainedHeight = layout.size.height - bottomInset - layout.intrinsicInsets.bottom - actionsPositionLock
            } else {
                actionsConstrainedHeight = layout.size.height - contentTopInset - contentRect.height - contentActionsSpacing - bottomInset - layout.intrinsicInsets.bottom
            }
            
            let actionsSize = self.actionsStackNode.update(
                presentationData: presentationData,
                constrainedSize: CGSize(width: layout.size.width, height: actionsConstrainedHeight),
                transition: transition
            )
            
            if case .animateOut = stateTransition {
            } else {
                if let topPositionLock = self.actionsStackNode.topPositionLock {
                    contentRect.origin.y = topPositionLock - contentActionsSpacing - contentRect.height
                } else if self.source.keepInPlace {
                } else {
                    if contentRect.minY < contentTopInset {
                        contentRect.origin.y = contentTopInset
                    }
                    var combinedBounds = CGRect(origin: CGPoint(x: 0.0, y: contentRect.minY), size: CGSize(width: layout.size.width, height: contentRect.height + contentActionsSpacing + actionsSize.height))
                    if combinedBounds.maxY > layout.size.height - bottomInset - layout.intrinsicInsets.bottom {
                        combinedBounds.origin.y = layout.size.height - bottomInset - layout.intrinsicInsets.bottom - combinedBounds.height
                    }
                    if combinedBounds.minY < contentTopInset {
                        combinedBounds.origin.y = contentTopInset
                    }
                    
                    contentRect.origin.y = combinedBounds.minY
                }
            }
            
            if let reactionContextNode = self.reactionContextNode {
                var reactionContextNodeTransition = transition
                if reactionContextNode.frame.isEmpty {
                    reactionContextNodeTransition = .immediate
                }
                reactionContextNodeTransition.updateFrame(node: reactionContextNode, frame: CGRect(origin: CGPoint(), size: layout.size), beginWithCurrentState: true)
                reactionContextNode.updateLayout(size: layout.size, insets: UIEdgeInsets(top: topInset, left: 0.0, bottom: 0.0, right: 0.0), anchorRect: contentRect.offsetBy(dx: contentParentGlobalFrame.minX, dy: 0.0), transition: reactionContextNodeTransition)
            }
            if let removedReactionContextNode = removedReactionContextNode {
                removedReactionContextNode.animateOut(to: contentRect, animatingOutToReaction: false)
                transition.updateAlpha(node: removedReactionContextNode, alpha: 0.0, completion: { [weak removedReactionContextNode] _ in
                    removedReactionContextNode?.removeFromSupernode()
                })
            }
            
            transition.updateFrame(node: self.contentRectDebugNode, frame: contentRect, beginWithCurrentState: true)
            
            var actionsFrame = CGRect(origin: CGPoint(x: actionsSideInset, y: contentRect.maxY + contentActionsSpacing), size: actionsSize)
            if self.source.keepInPlace {
                actionsFrame.origin.y = contentRect.minY - contentActionsSpacing - actionsFrame.height
            }
            if self.source.centerActionsHorizontally {
                actionsFrame.origin.x = floor(contentParentGlobalFrame.minX + contentRect.midX - actionsFrame.width / 2.0)
                if actionsFrame.maxX > layout.size.width - actionsEdgeInset {
                    actionsFrame.origin.x = layout.size.width - actionsEdgeInset - actionsFrame.width
                }
                if actionsFrame.minX < actionsEdgeInset {
                    actionsFrame.origin.x = actionsEdgeInset
                }
            } else {
                if contentRect.midX < layout.size.width / 2.0 {
                    actionsFrame.origin.x = contentParentGlobalFrame.minX + contentRect.minX + actionsSideInset - 4.0
                } else {
                    actionsFrame.origin.x = contentParentGlobalFrame.minX + contentRect.maxX - actionsSideInset - actionsSize.width - 1.0
                }
                if actionsFrame.maxX > layout.size.width - actionsEdgeInset {
                    actionsFrame.origin.x = layout.size.width - actionsEdgeInset - actionsFrame.width
                }
                if actionsFrame.minX < actionsEdgeInset {
                    actionsFrame.origin.x = actionsEdgeInset
                }
            }
            transition.updateFrame(node: self.actionsStackNode, frame: actionsFrame, beginWithCurrentState: true)
            
            contentTransition.updateFrame(node: contentNode, frame: CGRect(origin: CGPoint(x: contentParentGlobalFrame.minX + contentRect.minX - contentNode.containingNode.contentRect.minX, y: contentRect.minY - contentNode.containingNode.contentRect.minY), size: contentNode.containingNode.bounds.size), beginWithCurrentState: true)
            
            let contentHeight: CGFloat
            if self.actionsStackNode.topPositionLock != nil {
                contentHeight = layout.size.height
            } else {
                contentHeight = actionsFrame.maxY + bottomInset + layout.intrinsicInsets.bottom
            }
            let contentSize = CGSize(width: layout.size.width, height: contentHeight)
            
            if self.scrollNode.view.contentSize != contentSize {
                let previousContentOffset = self.scrollNode.view.contentOffset
                self.scrollNode.view.contentSize = contentSize
                if let storedScrollingState = self.actionsStackNode.storedScrollingState {
                    self.actionsStackNode.clearStoredScrollingState()
                    
                    self.scrollNode.view.contentOffset = CGPoint(x: 0.0, y: storedScrollingState)
                }
                if case .none = stateTransition, transition.isAnimated {
                    let contentOffset = self.scrollNode.view.contentOffset
                    transition.animateOffsetAdditive(layer: self.scrollNode.layer, offset: previousContentOffset.y - contentOffset.y)
                }
            }
            
            self.actionsStackNode.updatePanSelection(isEnabled: contentSize.height <= layout.size.height)
            
            defaultScrollY = contentSize.height - layout.size.height
            if defaultScrollY < 0.0 {
                defaultScrollY = 0.0
            }
            
            self.dismissTapNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: contentSize.width, height: max(contentSize.height, layout.size.height)))
            self.dismissAccessibilityArea.frame = CGRect(origin: CGPoint(), size: CGSize(width: contentSize.width, height: max(contentSize.height, layout.size.height)))
        }
        
        switch stateTransition {
        case .animateIn:
            contentNode.takeContainingNode()
            
            let duration: Double = 0.42
            let springDamping: CGFloat = 104.0
            
            self.scrollNode.view.contentOffset = CGPoint(x: 0.0, y: defaultScrollY)
            
            self.backgroundNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            
            if let animateClippingFromContentAreaInScreenSpace = contentNode.animateClippingFromContentAreaInScreenSpace {
                self.clippingNode.layer.animateFrame(from: CGRect(origin: CGPoint(x: 0.0, y: animateClippingFromContentAreaInScreenSpace.minY), size: CGSize(width: layout.size.width, height: animateClippingFromContentAreaInScreenSpace.height)), to: CGRect(origin: CGPoint(), size: layout.size), duration: 0.2)
                self.clippingNode.layer.animateBoundsOriginYAdditive(from: animateClippingFromContentAreaInScreenSpace.minY, to: 0.0, duration: 0.2)
            }
            
            let currentContentScreenFrame = convertFrame(contentNode.containingNode.contentRect, from: contentNode.containingNode.view, to: self.view)
            let currentContentLocalFrame = convertFrame(contentRect, from: self.scrollNode.view, to: self.view)
            let animationInContentDistance = currentContentLocalFrame.maxY - currentContentScreenFrame.maxY
            
            contentNode.layer.animateSpring(
                from: -animationInContentDistance as NSNumber, to: 0.0 as NSNumber,
                keyPath: "position.y",
                duration: duration,
                delay: 0.0,
                initialVelocity: 0.0,
                damping: springDamping,
                additive: true
            )
            
            self.actionsStackNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.05)
            self.actionsStackNode.layer.animateSpring(
                from: 0.01 as NSNumber,
                to: 1.0 as NSNumber,
                keyPath: "transform.scale",
                duration: duration,
                delay: 0.0,
                initialVelocity: 0.0,
                damping: springDamping,
                additive: false
            )
            
            let actionsSize = self.actionsStackNode.bounds.size
            
            var actionsPositionDeltaXDistance: CGFloat = 0.0
            if self.source.centerActionsHorizontally {
                actionsPositionDeltaXDistance = currentContentScreenFrame.midX - self.actionsStackNode.frame.midX
            }
            
            let actionsVerticalTransitionDirection: CGFloat
            if contentNode.frame.minY < self.actionsStackNode.frame.minY {
                actionsVerticalTransitionDirection = -1.0
            } else {
                actionsVerticalTransitionDirection = 1.0
            }
            let actionsPositionDeltaYDistance = -animationInContentDistance + actionsVerticalTransitionDirection * actionsSize.height / 2.0 - contentActionsSpacing
            self.actionsStackNode.layer.animateSpring(
                from: NSValue(cgPoint: CGPoint(x: actionsPositionDeltaXDistance, y: actionsPositionDeltaYDistance)),
                to: NSValue(cgPoint: CGPoint()),
                keyPath: "position",
                duration: duration,
                delay: 0.0,
                initialVelocity: 0.0,
                damping: springDamping,
                additive: true
            )
            
            if let reactionContextNode = self.reactionContextNode {
                let reactionsPositionDeltaYDistance = -animationInContentDistance
                reactionContextNode.layer.animateSpring(
                    from: NSValue(cgPoint: CGPoint(x: 0.0, y: reactionsPositionDeltaYDistance)),
                    to: NSValue(cgPoint: CGPoint()),
                    keyPath: "position",
                    duration: duration,
                    delay: 0.0,
                    initialVelocity: 0.0,
                    damping: springDamping,
                    additive: true
                )
                reactionContextNode.animateIn(from: currentContentScreenFrame)
            }
            
            self.actionsStackNode.animateIn()
            
            contentNode.containingNode.isExtractedToContextPreview = true
            contentNode.containingNode.isExtractedToContextPreviewUpdated?(true)
            contentNode.containingNode.willUpdateIsExtractedToContextPreview?(true, transition)
            
            contentNode.containingNode.layoutUpdated = { [weak self] _, animation in
                guard let strongSelf = self, let _ = strongSelf.contentNode else {
                    return
                }
                
                if let _ = strongSelf.animatingOutState {
                    /*let updatedContentScreenFrame = convertFrame(contentNode.containingNode.contentRect, from: contentNode.containingNode.view, to: strongSelf.view)
                    if animatingOutState.currentContentScreenFrame != updatedContentScreenFrame {
                        let offset = CGPoint(
                            x: updatedContentScreenFrame.minX - animatingOutState.currentContentScreenFrame.minX,
                            y: updatedContentScreenFrame.minY - animatingOutState.currentContentScreenFrame.minY
                        )
                        let _ = offset
                        
                        //animation.animator.updatePosition(layer: contentNode.layer, position: contentNode.position.offsetBy(dx: offset.x, dy: offset.y), completion: nil)
                        
                        animatingOutState.currentContentScreenFrame = updatedContentScreenFrame
                    }*/
                } else {
                    strongSelf.requestUpdate(animation.transition)
                    
                    /*let updatedContentScreenFrame = convertFrame(contentNode.containingNode.contentRect, from: contentNode.containingNode.view, to: strongSelf.view)
                    if let storedGlobalFrame = contentNode.storedGlobalFrame {
                        let offset = CGPoint(
                            x: updatedContentScreenFrame.minX - storedGlobalFrame.minX,
                            y: updatedContentScreenFrame.maxY - storedGlobalFrame.maxY
                        )
                        
                        if !offset.x.isZero || !offset.y.isZero {
                            //print("contentNode.frame = \(contentNode.frame)")
                            //animation.animator.updateBounds(layer: contentNode.layer, bounds: contentNode.layer.bounds.offsetBy(dx: -offset.x, dy: -offset.y), completion: nil)
                        }
                        
                        //animatingOutState.currentContentScreenFrame = updatedContentScreenFrame
                    }*/
                }
            }
            
            /*
            public var updateAbsoluteRect: ((CGRect, CGSize) -> Void)?
            public var applyAbsoluteOffset: ((CGPoint, ContainedViewLayoutTransitionCurve, Double) -> Void)?
            public var applyAbsoluteOffsetSpring: ((CGFloat, Double, CGFloat) -> Void)?
            public var layoutUpdated: ((CGSize) -> Void)?
            public var updateDistractionFreeMode: ((Bool) -> Void)?
            public var requestDismiss: (() -> Void)*/
        case let .animateOut(result, completion):
            let duration: Double
            let timingFunction: String
            switch result {
            case .default, .dismissWithoutContent:
                duration = self.reactionContextNodeIsAnimatingOut ? 0.25 : 0.2
                timingFunction = CAMediaTimingFunctionName.easeInEaseOut.rawValue
            case let .custom(customTransition):
                switch customTransition {
                case let .animated(customDuration, curve):
                    duration = customDuration
                    timingFunction = curve.timingFunction
                case .immediate:
                    duration = self.reactionContextNodeIsAnimatingOut ? 0.25 : 0.2
                    timingFunction = CAMediaTimingFunctionName.easeInEaseOut.rawValue
                }
            }
            
            let putBackInfo = self.source.putBack()
            
            if let putBackInfo = putBackInfo {
                self.clippingNode.layer.animateFrame(from: CGRect(origin: CGPoint(), size: layout.size), to: CGRect(origin: CGPoint(x: 0.0, y: putBackInfo.contentAreaInScreenSpace.minY), size: CGSize(width: layout.size.width, height: putBackInfo.contentAreaInScreenSpace.height)), duration: duration, timingFunction: timingFunction, removeOnCompletion: false)
                self.clippingNode.layer.animateBoundsOriginYAdditive(from: 0.0, to: putBackInfo.contentAreaInScreenSpace.minY, duration: duration, timingFunction: timingFunction, removeOnCompletion: false)
            }
            
            let currentContentScreenFrame = convertFrame(contentNode.containingNode.contentRect, from: contentNode.containingNode.view, to: self.view)
            
            self.animatingOutState = AnimatingOutState(
                currentContentScreenFrame: currentContentScreenFrame
            )
            
            let currentContentLocalFrame = convertFrame(contentRect, from: self.scrollNode.view, to: self.view)
            
            let animationInContentDistance: CGFloat
            
            switch result {
            case .default, .custom:
                animationInContentDistance = currentContentLocalFrame.minY - currentContentScreenFrame.minY
            case .dismissWithoutContent:
                animationInContentDistance = 0.0
                contentNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false)
            }
            
            let actionsVerticalTransitionDirection: CGFloat
            if contentNode.frame.minY < self.actionsStackNode.frame.minY {
                actionsVerticalTransitionDirection = -1.0
            } else {
                actionsVerticalTransitionDirection = 1.0
            }
            
            contentNode.containingNode.willUpdateIsExtractedToContextPreview?(false, transition)
            
            contentNode.offsetContainerNode.position = contentNode.offsetContainerNode.position.offsetBy(dx: 0.0, dy: -animationInContentDistance)
            let reactionContextNodeIsAnimatingOut = self.reactionContextNodeIsAnimatingOut
            contentNode.offsetContainerNode.layer.animate(
                from: animationInContentDistance as NSNumber,
                to: 0.0 as NSNumber,
                keyPath: "position.y",
                timingFunction: timingFunction,
                duration: duration,
                delay: 0.0,
                additive: true,
                completion: { [weak self] _ in
                    Queue.mainQueue().after(reactionContextNodeIsAnimatingOut ? 0.2 * UIView.animationDurationFactor() : 0.0, {
                        contentNode.containingNode.isExtractedToContextPreview = false
                        contentNode.containingNode.isExtractedToContextPreviewUpdated?(false)
                        
                        if let strongSelf = self, let contentNode = strongSelf.contentNode {
                            contentNode.containingNode.addSubnode(contentNode.containingNode.contentNode)
                        }
                        
                        completion()
                    })
                }
            )
            
            self.actionsStackNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, removeOnCompletion: false)
            self.actionsStackNode.layer.animate(
                from: 1.0 as NSNumber,
                to: 0.01 as NSNumber,
                keyPath: "transform.scale",
                timingFunction: timingFunction,
                duration: duration,
                delay: 0.0,
                removeOnCompletion: false
            )
            
            let actionsSize = self.actionsStackNode.bounds.size
            
            var actionsPositionDeltaXDistance: CGFloat = 0.0
            if self.source.centerActionsHorizontally {
                actionsPositionDeltaXDistance = currentContentScreenFrame.midX - self.actionsStackNode.frame.midX
            }
            let actionsPositionDeltaYDistance = -animationInContentDistance + actionsVerticalTransitionDirection * actionsSize.height / 2.0 - contentActionsSpacing
            self.actionsStackNode.layer.animate(
                from: NSValue(cgPoint: CGPoint()),
                to: NSValue(cgPoint: CGPoint(x: actionsPositionDeltaXDistance, y: actionsPositionDeltaYDistance)),
                keyPath: "position",
                timingFunction: timingFunction,
                duration: duration,
                delay: 0.0,
                removeOnCompletion: false,
                additive: true
            )
            
            self.backgroundNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, removeOnCompletion: false)
            
            if let reactionContextNode = self.reactionContextNode {
                reactionContextNode.animateOut(to: currentContentScreenFrame, animatingOutToReaction: self.reactionContextNodeIsAnimatingOut)
            }
        case .none:
            if animateReactionsIn, let reactionContextNode = self.reactionContextNode {
                reactionContextNode.animateIn(from: contentRect)
            }
        }
    }
    
    func animateOutToReaction(value: String, targetView: UIView, hideNode: Bool, animateTargetContainer: UIView?, addStandaloneReactionAnimation: ((StandaloneReactionAnimation) -> Void)?, completion: @escaping () -> Void) {
        guard let reactionContextNode = self.reactionContextNode else {
            self.requestAnimateOut(.default, completion)
            return
        }

        var contentCompleted = false
        var reactionCompleted = false
        let intermediateCompletion: () -> Void = {
            if contentCompleted && reactionCompleted {
                completion()
            }
        }
        
        self.reactionContextNodeIsAnimatingOut = true
        reactionContextNode.willAnimateOutToReaction(value: value)
        
        self.requestAnimateOut(.default, {
            contentCompleted = true
            intermediateCompletion()
        })
        
        reactionContextNode.animateOutToReaction(value: value, targetView: targetView, hideNode: hideNode, animateTargetContainer: animateTargetContainer, addStandaloneReactionAnimation: addStandaloneReactionAnimation, completion: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.reactionContextNode?.removeFromSupernode()
            strongSelf.reactionContextNode = nil
            reactionCompleted = true
            intermediateCompletion()
        })
    }
    
    func cancelReactionAnimation() {
        self.reactionContextNode?.cancelReactionAnimation()
    }
    
    func addRelativeContentOffset(_ offset: CGPoint, transition: ContainedViewLayoutTransition) {
        if self.reactionContextNodeIsAnimatingOut, let reactionContextNode = self.reactionContextNode {
            reactionContextNode.bounds = reactionContextNode.bounds.offsetBy(dx: 0.0, dy: offset.y)
            transition.animateOffsetAdditive(node: reactionContextNode, offset: -offset.y)
        }
    }
}
