import UIKit

/// The on-screen pointer that the remote's touch surface moves.
final class CursorView: UIView {
    enum Kind: String {
        case arrow = "default"
        case pointer
        case text
    }

    static let accent = UIColor(red: 0.18, green: 0.77, blue: 0.71, alpha: 1)

    var kind: Kind = .arrow {
        didSet {
            guard kind != oldValue else { return }
            setNeedsDisplay()
            updateCenter()
        }
    }

    /// Where the cursor points, in the superview's coordinates.
    var position: CGPoint = .zero {
        didSet { updateCenter() }
    }

    /// The arrow points with its tip; the other shapes point with their middle.
    private var hotspot: CGPoint {
        kind == .arrow ? CGPoint(x: 6, y: 5) : CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func updateCenter() {
        let spot = hotspot
        center = CGPoint(x: position.x - spot.x + bounds.midX, y: position.y - spot.y + bounds.midY)
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ rect: CGRect) {
        switch kind {
        case .arrow:
            let path = UIBezierPath()
            let points: [(CGFloat, CGFloat)] = [(6, 5), (6, 43), (15, 34), (22, 50), (29, 47), (22, 31), (35, 31)]
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.0, y: point.1))
            }
            path.close()
            path.lineJoinStyle = .round
            UIColor.white.setFill()
            path.fill()
            UIColor.black.setStroke()
            path.lineWidth = 3
            path.stroke()

        case .pointer:
            let ring = UIBezierPath(ovalIn: bounds.insetBy(dx: 12, dy: 12))
            CursorView.accent.withAlphaComponent(0.9).setFill()
            ring.fill()
            UIColor.white.setStroke()
            ring.lineWidth = 4
            ring.stroke()

        case .text:
            let bar = UIBezierPath()
            let midX = bounds.midX
            bar.move(to: CGPoint(x: midX, y: 10))
            bar.addLine(to: CGPoint(x: midX, y: bounds.height - 10))
            bar.move(to: CGPoint(x: midX - 8, y: 10))
            bar.addLine(to: CGPoint(x: midX + 8, y: 10))
            bar.move(to: CGPoint(x: midX - 8, y: bounds.height - 10))
            bar.addLine(to: CGPoint(x: midX + 8, y: bounds.height - 10))
            bar.lineCapStyle = .round
            UIColor.black.setStroke()
            bar.lineWidth = 8
            bar.stroke()
            UIColor.white.setStroke()
            bar.lineWidth = 4
            bar.stroke()
        }
    }

    /// A quick squeeze so a click is visible from the couch.
    func pulse() {
        UIView.animate(withDuration: 0.08, animations: {
            self.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        }, completion: { _ in
            UIView.animate(withDuration: 0.14) {
                self.transform = .identity
            }
        })
    }
}

/// A short message at the bottom of the screen.
final class ToastView: UIView {
    private let label = UILabel()
    private var hideTimer: Timer?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = UIColor(white: 0.08, alpha: 0.92)
        layer.cornerRadius = 22
        layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
        layer.borderWidth = 1

        label.textColor = .white
        label.font = .systemFont(ofSize: 29, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 3
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ text: String, for duration: TimeInterval, in container: CGRect) {
        label.text = text
        let maxWidth = min(container.width - 240, 1400)
        let size = label.sizeThatFits(CGSize(width: maxWidth - 72, height: 400))
        let width = min(maxWidth, size.width + 72)
        let height = size.height + 40
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        center = CGPoint(x: container.midX, y: container.maxY - 90 - height / 2)
        label.frame = bounds.insetBy(dx: 36, dy: 20)

        hideTimer?.invalidate()
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                UIView.animate(withDuration: 0.35) { self?.alpha = 0 }
            }
        }
    }
}

/// Black bars around a video that has been zoomed to fill the screen.
final class LetterboxView: UIView {
    private let shape = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        shape.fillRule = .evenOdd
        shape.fillColor = UIColor.black.cgColor
        layer.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Covers everything except `hole`.
    func setHole(_ hole: CGRect) {
        let path = UIBezierPath(rect: bounds.insetBy(dx: -4, dy: -4))
        let visible = hole.intersection(bounds)
        if !visible.isNull, !visible.isEmpty {
            path.append(UIBezierPath(rect: visible))
        }
        shape.frame = bounds
        shape.path = path.cgPath
    }
}
