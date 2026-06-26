import UIKit

protocol ScrollsToTop: AnyObject {
    func scrollToTop(animated: Bool)
}

extension UIScrollView {
    func scrollToTopRespectingAdjustedInset(animated: Bool) {
        let topOffset = CGPoint(x: -adjustedContentInset.left, y: -adjustedContentInset.top)
        setContentOffset(topOffset, animated: animated)
    }
}
