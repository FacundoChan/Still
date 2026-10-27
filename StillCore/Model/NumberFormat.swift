import Foundation

extension FormatStyle where Self == FloatingPointFormatStyle<Double> {
    /// A number with exactly `digits` decimals in the style of the user's region, for messages: “1.5” or “1,5”.
    static func decimals(_ digits: Int) -> Self { .number.precision(.fractionLength(digits)) }
}
