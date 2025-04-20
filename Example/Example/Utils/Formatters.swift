import Foundation

struct Formatters {
    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
    
    static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        return formatter
    }()
    
    static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()
    
    static func formatBytes(_ bytes: Int64) -> String {
        return byteFormatter.string(fromByteCount: bytes)
    }
    
    static func formatBytes(_ bytes: UInt64) -> String {
        return byteFormatter.string(fromByteCount: Int64(bytes))
    }
    
    static func formatPercent(_ value: Double) -> String {
        return percentFormatter.string(from: NSNumber(value: value)) ?? "0%"
    }
    
    static func formatDecimal(_ value: Double) -> String {
        return decimalFormatter.string(from: NSNumber(value: value)) ?? "0.0"
    }
}
