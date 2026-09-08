import AppKit

/// Menu-bar glyphs for each provider, rendered from the official brand marks as
/// *template* images so AppKit tints them to match the menu bar (black in light
/// mode, white in dark) without shipping any binary asset files.
///
/// The logos are stored as their vector outlines on a 24×24 grid (the source
/// SVG `viewBox`), pre-normalized to absolute `M`/`L`/`C`/`Z` commands — arcs
/// already flattened to cubic béziers — so the tiny parser below is all the
/// runtime needs. Source: Simple Icons (CC0).
extension ProviderKind {

    /// A cached template image for this provider, sized to the given point size.
    @MainActor
    func iconImage(pointSize: CGFloat) -> NSImage {
        let side = (pointSize + 1).rounded()
        let key = "\(rawValue)@\(Int(side))"
        if let cached = providerIconCache[key] { return cached }

        let outline = Self.outline(for: self)
        // The drawing handler may be invoked lazily by AppKit, so it stays
        // self-contained: it only reads the captured path string and draws.
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let path = bezierPath(fromNormalizedSVG: outline) else { return true }
            // Map the 0…24 SVG box onto the image and flip Y (SVG is y-down).
            let scale = side / 24.0
            path.transform(using: AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale,
                                                  tX: 0, tY: side))
            path.windingRule = .nonZero // reproduces the logos' interior holes
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true // tinted to the menu-bar appearance at draw time
        providerIconCache[key] = image
        return image
    }

    private static func outline(for kind: ProviderKind) -> String {
        switch kind {
        case .claude: return claudeOutline
        case .openai: return openAIOutline
        }
    }
}

/// Render cache, keyed by "provider@side". Main-actor only.
@MainActor private var providerIconCache: [String: NSImage] = [:]

/// Parse a path made of only absolute `M`/`L`/`C`/`Z` tokens (space-separated)
/// into an `NSBezierPath`. Returns nil if the string is malformed.
private func bezierPath(fromNormalizedSVG d: String) -> NSBezierPath? {
    let tokens = d.split(whereSeparator: { $0 == " " || $0 == "\n" })
    let path = NSBezierPath()
    var i = 0
    func coord() -> CGFloat? {
        guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
        i += 1
        return CGFloat(v)
    }
    while i < tokens.count {
        let cmd = tokens[i]; i += 1
        switch cmd {
        case "M":
            guard let x = coord(), let y = coord() else { return nil }
            path.move(to: CGPoint(x: x, y: y))
        case "L":
            guard let x = coord(), let y = coord() else { return nil }
            path.line(to: CGPoint(x: x, y: y))
        case "C":
            guard let x1 = coord(), let y1 = coord(),
                  let x2 = coord(), let y2 = coord(),
                  let x = coord(), let y = coord() else { return nil }
            path.curve(to: CGPoint(x: x, y: y),
                       controlPoint1: CGPoint(x: x1, y: y1),
                       controlPoint2: CGPoint(x: x2, y: y2))
        case "Z":
            path.close()
        default:
            return nil
        }
    }
    return path
}

// Vector outlines on a 24×24 grid. See the file header.
private let claudeOutline = "M 4.714 15.956 L 9.432 13.308 L 9.511 13.078 L 9.432 12.95 L 9.201 12.95 L 8.412 12.902 L 5.716 12.829 L 3.379 12.732 L 1.114 12.61 L 0.543 12.489 L 0.009 11.785 L 0.064 11.432 L 0.543 11.111 L 1.229 11.171 L 2.747 11.275 L 5.024 11.432 L 6.675 11.53 L 9.122 11.785 L 9.511 11.785 L 9.565 11.627 L 9.432 11.53 L 9.329 11.432 L 6.973 9.836 L 4.423 8.148 L 3.087 7.176 L 2.365 6.685 L 2.001 6.223 L 1.843 5.215 L 2.499 4.493 L 3.379 4.553 L 3.603 4.614 L 4.496 5.3 L 6.402 6.776 L 8.892 8.609 L 9.256 8.913 L 9.402 8.81 L 9.42 8.737 L 9.256 8.463 L 7.902 6.017 L 6.457 3.527 L 5.813 2.495 L 5.643 1.876 C 5.583 1.621 5.54 1.409 5.54 1.147 L 6.287 0.134 L 6.7 0 L 7.695 0.134 L 8.114 0.498 L 8.734 1.913 L 9.735 4.141 L 11.29 7.17 L 11.745 8.069 L 11.988 8.901 L 12.079 9.156 L 12.237 9.156 L 12.237 9.01 L 12.364 7.304 L 12.601 5.209 L 12.832 2.514 L 12.911 1.755 L 13.287 0.844 L 14.034 0.352 L 14.617 0.631 L 15.096 1.317 L 15.03 1.761 L 14.744 3.612 L 14.186 6.515 L 13.821 8.457 L 14.034 8.457 L 14.277 8.215 L 15.26 6.909 L 16.912 4.845 L 17.64 4.025 L 18.49 3.121 L 19.037 2.69 L 20.069 2.69 L 20.828 3.819 L 20.488 4.985 L 19.425 6.332 L 18.545 7.474 L 17.282 9.174 L 16.493 10.534 L 16.566 10.643 L 16.754 10.625 L 19.607 10.018 L 21.15 9.738 L 22.989 9.423 L 23.821 9.811 L 23.912 10.206 L 23.584 11.013 L 21.617 11.499 L 19.31 11.961 L 15.874 12.774 L 15.831 12.805 L 15.88 12.865 L 17.428 13.011 L 18.09 13.047 L 19.711 13.047 L 22.728 13.272 L 23.517 13.794 L 23.991 14.432 L 23.912 14.917 L 22.698 15.537 L 21.058 15.148 L 17.233 14.237 L 15.922 13.909 L 15.74 13.909 L 15.74 14.019 L 16.833 15.087 L 18.836 16.897 L 21.344 19.228 L 21.471 19.805 L 21.15 20.26 L 20.81 20.212 L 18.606 18.554 L 17.756 17.807 L 15.831 16.186 L 15.704 16.186 L 15.704 16.356 L 16.147 17.006 L 18.49 20.527 L 18.612 21.608 L 18.442 21.96 L 17.835 22.173 L 17.167 22.051 L 15.795 20.127 L 14.38 17.959 L 13.239 16.016 L 13.099 16.095 L 12.425 23.35 L 12.109 23.721 L 11.381 24 L 10.774 23.539 L 10.452 22.792 L 10.774 21.316 L 11.162 19.392 L 11.478 17.862 L 11.763 15.961 L 11.933 15.33 L 11.921 15.288 L 11.781 15.306 L 10.349 17.273 L 8.169 20.218 L 6.445 22.063 L 6.032 22.227 L 5.316 21.857 L 5.382 21.195 L 5.783 20.606 L 8.169 17.57 L 9.608 15.688 L 10.537 14.602 L 10.531 14.444 L 10.476 14.444 L 4.138 18.56 L 3.008 18.706 L 2.523 18.25 L 2.583 17.504 L 2.814 17.261 L 4.721 15.949 Z"

private let openAIOutline = "M 22.282 9.821 C 22.825 8.186 22.637 6.397 21.766 4.91 C 20.457 2.632 17.826 1.46 15.256 2.01 C 13.808 0.4 11.611 -0.317 9.492 0.131 C 7.373 0.579 5.653 2.123 4.981 4.182 C 3.293 4.528 1.836 5.585 0.983 7.082 C -0.34 9.357 -0.04 12.227 1.726 14.178 C 1.181 15.812 1.367 17.602 2.237 19.089 C 3.547 21.369 6.18 22.541 8.751 21.989 C 9.895 23.277 11.538 24.01 13.26 24 C 15.894 24.002 18.227 22.302 19.032 19.794 C 20.719 19.447 22.176 18.391 23.029 16.894 C 24.337 14.623 24.035 11.769 22.282 9.821 Z M 13.26 22.429 C 12.209 22.431 11.19 22.062 10.383 21.388 L 10.525 21.308 L 15.304 18.55 C 15.546 18.408 15.695 18.149 15.696 17.869 L 15.696 11.132 L 17.716 12.3 C 17.737 12.31 17.751 12.33 17.754 12.352 L 17.754 17.935 C 17.749 20.415 15.74 22.424 13.26 22.429 Z M 3.599 18.304 C 3.072 17.393 2.883 16.326 3.065 15.29 L 3.207 15.375 L 7.99 18.134 C 8.231 18.275 8.529 18.275 8.77 18.134 L 14.613 14.765 L 14.613 17.097 C 14.612 17.122 14.6 17.145 14.58 17.159 L 9.74 19.95 C 7.589 21.189 4.842 20.452 3.599 18.304 Z M 2.341 7.896 C 2.872 6.979 3.71 6.281 4.706 5.923 L 4.706 11.6 C 4.703 11.879 4.851 12.139 5.094 12.277 L 10.909 15.631 L 8.889 16.799 C 8.866 16.811 8.84 16.811 8.818 16.799 L 3.987 14.013 C 1.841 12.769 1.105 10.023 2.341 7.872 Z M 18.937 11.751 L 13.104 8.364 L 15.119 7.2 C 15.141 7.188 15.168 7.188 15.19 7.2 L 20.021 9.991 C 21.528 10.861 22.398 12.523 22.253 14.258 C 22.108 15.993 20.975 17.488 19.344 18.096 L 19.344 12.418 C 19.335 12.14 19.181 11.886 18.937 11.751 Z M 20.948 8.728 L 20.806 8.643 L 16.032 5.861 C 15.79 5.719 15.489 5.719 15.247 5.861 L 9.409 9.23 L 9.409 6.897 C 9.406 6.873 9.417 6.85 9.437 6.836 L 14.268 4.049 C 15.779 3.179 17.657 3.26 19.088 4.258 C 20.518 5.256 21.243 6.99 20.948 8.709 Z M 8.307 12.863 L 6.287 11.699 C 6.266 11.687 6.252 11.666 6.249 11.643 L 6.249 6.074 C 6.251 4.33 7.26 2.745 8.84 2.005 C 10.419 1.266 12.283 1.506 13.624 2.62 L 13.482 2.701 L 8.704 5.459 C 8.462 5.601 8.313 5.86 8.311 6.14 Z M 9.404 10.498 L 12.006 8.998 L 14.613 10.498 L 14.613 13.497 L 12.016 14.997 L 9.409 13.497 Z"
