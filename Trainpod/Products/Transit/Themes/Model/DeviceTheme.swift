import Foundation
import SwiftUI
import UIKit

struct DeviceTheme: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var background: String
    var primaryText: String
    var detail: String
    var secondaryText: String
    var arrivalBadge: String
    var arrivalBadgeText: String

    var colors: [String] { [background, primaryText, detail, secondaryText, arrivalBadge, arrivalBadgeText] }
    var fingerprint: String {
        var hash: UInt32 = 2166136261
        for hex in colors {
            let rgb = UInt32(hex.dropFirst(), radix: 16)!
            for shift in [16, 8, 0] {
                hash = (hash ^ ((rgb >> shift) & 255)) &* 16777619
            }
        }
        return String(format: "%08X", hash)
    }

    static func color(_ hex: String) -> Color {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255, opacity: 1)
    }

    static let customStorageKey = "deviceTheme.custom.v1"
    func asCustom() -> DeviceTheme {
        DeviceTheme(id: "custom", name: "Custom", background: background,
                    primaryText: primaryText, detail: detail, secondaryText: secondaryText,
                    arrivalBadge: arrivalBadge, arrivalBadgeText: arrivalBadgeText)
    }
    static func loadCustom() -> DeviceTheme {
        if let data = UserDefaults.standard.data(forKey: customStorageKey),
           let saved = try? JSONDecoder().decode(DeviceTheme.self, from: data),
           saved.colors.allSatisfy({ value in
               let bytes = Array(value.utf8)
               return bytes.count == 7 && bytes.first == 35 && bytes.dropFirst().allSatisfy {
                   (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
               }
           }) { return saved.asCustom() }
        return presets[2].asCustom()
    }
    static func hex(_ color: Color) -> String? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = UIColor(color).cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        let rgb = components.prefix(3).map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2])
    }

    static let presets: [DeviceTheme] = [
        DeviceTheme(id: "light_pink", name: "Light Pink",
            background: "#F3C9D8", primaryText: "#641E39", detail: "#FFE7F0", secondaryText: "#9A4968", arrivalBadge: "#7A294B", arrivalBadgeText: "#FFE7F0"),
        DeviceTheme(id: "lilac", name: "Lilac",
            background: "#DCCAF3", primaryText: "#4A1F72", detail: "#F3E7FF", secondaryText: "#7A4FA0", arrivalBadge: "#5D2D88", arrivalBadgeText: "#F6EFFF"),
        DeviceTheme(id: "book_tan", name: "Book / Tan",
            background: "#E8C894", primaryText: "#221A12", detail: "#F7E2BA", secondaryText: "#7D5C37", arrivalBadge: "#3A2A1C", arrivalBadgeText: "#FFE8BD"),
        DeviceTheme(id: "light_blue", name: "Light Blue",
            background: "#C8E8F4", primaryText: "#123E68", detail: "#E0FBF8", secondaryText: "#467A97", arrivalBadge: "#1E5A7C", arrivalBadgeText: "#E8FAFF"),
        DeviceTheme(id: "mint_forest", name: "Mint / Forest",
            background: "#C7E8D3", primaryText: "#174A35", detail: "#E6F8EC", secondaryText: "#4B8068", arrivalBadge: "#246046", arrivalBadgeText: "#ECFFF2"),
        DeviceTheme(id: "vapor_wave", name: "Vapor Wave",
            background: "#F3B7E7", primaryText: "#4B1C6B", detail: "#C8FFF6", secondaryText: "#8E4FA4", arrivalBadge: "#67278C", arrivalBadgeText: "#FFF0FD"),
        DeviceTheme(id: "dark_mode", name: "Dark Mode",
            background: "#111318", primaryText: "#F3E9D2", detail: "#28313D", secondaryText: "#A5A2A0", arrivalBadge: "#F0D8B8", arrivalBadgeText: "#1A1D23"),
        DeviceTheme(id: "neo_teal", name: "Neo Teal",
            background: "#BFF5EE", primaryText: "#083C4A", detail: "#E9FFFC", secondaryText: "#2F7280", arrivalBadge: "#0E5A6C", arrivalBadgeText: "#E9FFFD"),
        DeviceTheme(id: "cobalt_ice", name: "Cobalt Ice",
            background: "#D1E3FF", primaryText: "#0F2D63", detail: "#F1F7FF", secondaryText: "#4F6FAE", arrivalBadge: "#1B438A", arrivalBadgeText: "#F3F8FF"),
        DeviceTheme(id: "neon_mint", name: "Neon Mint",
            background: "#C8F4D1", primaryText: "#0F422D", detail: "#EDFFF1", secondaryText: "#3E8667", arrivalBadge: "#156A45", arrivalBadgeText: "#F0FFF4"),
        DeviceTheme(id: "plum_glow", name: "Plum Glow",
            background: "#E8C8FA", primaryText: "#43155F", detail: "#FAEDFF", secondaryText: "#7D49A1", arrivalBadge: "#5B247D", arrivalBadgeText: "#FFF0FF")
    ]
}
