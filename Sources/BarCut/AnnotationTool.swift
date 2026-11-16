import AppKit

enum AnnotationTool: Int, CaseIterable {
    case arrow, box, text, crop

    struct Details {
        let symbol: String
        let label: String
        let shortcut: String
        let tooltip: String
        let hint: String
    }

    static let details: [Details] = [
        .init(
            symbol: "arrow.up.right", label: "Arrow", shortcut: "1", tooltip: "Arrow (1)",
            hint: "Drag to draw an arrow. Type to label it. Return copies."),
        .init(
            symbol: "rectangle", label: "Box", shortcut: "2", tooltip: "Box (2)",
            hint: "Drag to draw a box. Type to add text. Return copies."),
        .init(
            symbol: "textformat", label: "Text", shortcut: "3", tooltip: "Text (3). Or just start typing.",
            hint: "Click to place text. Return copies."),
        .init(symbol: "crop", label: "Crop", shortcut: "4", tooltip: "Crop (4)", hint: "Drag to crop. Return copies."),
    ]
    var details: Details { Self.details[rawValue] }
}

enum AnnotationColor: String, CaseIterable {
    case red, yellow, green, blue, black

    var nsColor: NSColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .red: rgb = (255, 59, 48)
        case .yellow: rgb = (255, 204, 0)
        case .green: rgb = (52, 199, 89)
        case .blue: rgb = (0, 122, 255)
        case .black: rgb = (28, 28, 30)
        }
        return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
    }
    var textColor: NSColor { self == .yellow ? .init(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white }
}
