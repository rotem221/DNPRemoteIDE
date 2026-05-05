import AppKit

/// Gutter showing 1-based line numbers next to an `NSTextView`. Recomputes on text or frame changes.
final class LineNumberRulerView: NSRulerView {

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let textColor = NSColor.white.withAlphaComponent(0.42)
    private let bgColor   = NSColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1.0)
    private let separator = NSColor.white.withAlphaComponent(0.06)

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(invalidate(_:)),
                       name: NSText.didChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(invalidate(_:)),
                       name: NSView.frameDidChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(invalidate(_:)),
                       name: NSView.boundsDidChangeNotification,
                       object: scrollView?.contentView)
        scrollView?.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invalidate(_ note: Notification) { needsDisplay = true }

    override func invalidateHashMarks() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView,
              let layout = tv.layoutManager,
              let container = tv.textContainer else { return }

        // Background + right separator.
        bgColor.setFill()
        rect.fill()
        separator.setFill()
        NSRect(x: rect.maxX - 0.5, y: rect.minY, width: 0.5, height: rect.height).fill()

        let inset = tv.textContainerInset.height
        let visibleRect = scrollView?.contentView.bounds ?? rect
        let glyphRange = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange  = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let nsString   = tv.string as NSString

        // Compute starting line number.
        var lineNumber = 1 + countNewlines(in: nsString, before: charRange.location)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let rightEdge = rect.width - 8

        var index = charRange.location
        let end = NSMaxRange(charRange)
        while index < end {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            let glyphAt = layout.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0),
                                            actualCharacterRange: nil).location
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyphAt, effectiveRange: nil)
            let y = lineRect.minY + inset - visibleRect.origin.y
            let s = "\(lineNumber)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: rightEdge - size.width,
                               y: y + (lineRect.height - size.height) / 2),
                   withAttributes: attrs)
            lineNumber += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }    // safety
        }
    }

    private func countNewlines(in s: NSString, before location: Int) -> Int {
        var count = 0
        var i = 0
        while i < location {
            if s.character(at: i) == 0x0A { count += 1 }
            i += 1
        }
        return count
    }
}
