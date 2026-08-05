import SwiftUI
import OpenCodeRemote

// MARK: - Sahara Warm Minimalism Color Palette

public enum SaharaColors {
    /// Warm alabaster background (#FAF5EE)
    public static let background = Color(red: 250/255, green: 245/255, blue: 238/255)
    /// Deep espresso text / foreground (#3A302A)
    public static let foreground = Color(red: 58/255, green: 48/255, blue: 42/255)
    /// On surface text (#3A302A)
    public static let onSurface = Color(red: 58/255, green: 48/255, blue: 42/255)
    
    /// Terracotta primary (#C2652A)
    public static let primary = Color(red: 194/255, green: 101/255, blue: 42/255)
    /// Accent color (alias for primary)
    public static let accent = primary
    /// White text on primary (#FFFFFF)
    public static let onPrimary = Color.white
    
    /// Soft peach highlight (#FBE8D8)
    public static let primaryFixed = Color(red: 251/255, green: 232/255, blue: 216/255)
    /// Dark brown text on soft peach (#401A08)
    public static let onPrimaryFixed = Color(red: 64/255, green: 26/255, blue: 8/255)
    /// Primary fixed dim (#F0A878)
    public static let primaryFixedDim = Color(red: 240/255, green: 168/255, blue: 120/255)
    
    /// Warm surface (#FAF5EE)
    public static let surface = Color(red: 250/255, green: 245/255, blue: 238/255)
    /// Surface bright (#FAF5EE)
    public static let surfaceBright = Color(red: 250/255, green: 245/255, blue: 238/255)
    
    /// Container level lowest (#FFFFFF)
    public static let surfaceContainerLowest = Color.white
    /// Container level low (#F6F0E8)
    public static let surfaceContainerLow = Color(red: 246/255, green: 240/255, blue: 232/255)
    /// Container level medium (#F2ECE4)
    public static let surfaceContainer = Color(red: 242/255, green: 236/255, blue: 228/255)
    /// Container level high (#ECE6DC)
    public static let surfaceContainerHigh = Color(red: 236/255, green: 230/255, blue: 220/255)
    /// Container level highest (#E6E0D6)
    public static let surfaceContainerHighest = Color(red: 230/255, green: 224/255, blue: 214/255)
    
    /// Card background (alias for surfaceContainerLow)
    public static let cardBackground = surfaceContainerLow
    
    /// Surface variant (#ECE6DC)
    public static let surfaceVariant = Color(red: 236/255, green: 230/255, blue: 220/255)
    /// On surface variant / muted text (#605850)
    public static let onSurfaceVariant = Color(red: 96/255, green: 88/255, blue: 80/255)
    
    /// Muted taupe secondary (#78706A)
    public static let secondary = Color(red: 120/255, green: 112/255, blue: 106/255)
    /// Secondary container (#EAE2DA)
    public static let secondaryContainer = Color(red: 234/255, green: 226/255, blue: 218/255)
    
    /// Crimson tertiary (#8C3C3C)
    public static let tertiary = Color(red: 140/255, green: 60/255, blue: 60/255)
    /// Tertiary fixed light red (#FCE0E0)
    public static let tertiaryFixed = Color(red: 252/255, green: 224/255, blue: 224/255)
    
    /// Border tint (#D8D0C8)
    public static let border = Color(red: 216/255, green: 208/255, blue: 200/255)
    /// Outline variant (#D8D0C8)
    public static let outlineVariant = Color(red: 216/255, green: 208/255, blue: 200/255)
    /// Outline (#9A9088)
    public static let outline = Color(red: 154/255, green: 144/255, blue: 136/255)
    
    /// Dark inverse surface for Terminal (#3A302A)
    public static let inverseSurface = Color(red: 58/255, green: 48/255, blue: 42/255)
    /// Text on inverse surface (#FAF5EE)
    public static let inverseOnSurface = Color(red: 250/255, green: 245/255, blue: 238/255)
    
    /// Error red (#C0392B)
    public static let error = Color(red: 192/255, green: 57/255, blue: 43/255)
}

// MARK: - Sahara Design Tokens (spacing / radius / elevation / status)
//
// Token unici per l'intera app: vietato inventare valori ad hoc nei view.
// Le scale rispecchiano il sistema: 4pt base, raggio contenuti 12, raggio
// superfici grandi 16, ombre soft su 3 livelli.

public enum SaharaSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum SaharaRadius {
    /// Piccoli elementi (chip, badge, toggle): 8
    public static let sm: CGFloat = 8
    /// Contenuti standard (card, input, bottoni): 12
    public static let md: CGFloat = 12
    /// Superfici grandi (sheet, drawer, console): 16
    public static let lg: CGFloat = 16
    /// Elementi pill-shaped (capsule, tab bar): 999
    public static let full: CGFloat = 999
}

public enum SaharaElevation {
    /// Elevazione 1: card statiche su background.
    public static let level1 = ShadowSpec(
        color: Color.black.opacity(0.06),
        radius: 6, x: 0, y: 2
    )
    /// Elevazione 2: card interattive, dock, header.
    public static let level2 = ShadowSpec(
        color: Color.black.opacity(0.09),
        radius: 12, x: 0, y: 4
    )
    /// Elevazione 3: overlay, sheet, modali.
    public static let level3 = ShadowSpec(
        color: Color.black.opacity(0.14),
        radius: 20, x: 0, y: 8
    )
}

public struct ShadowSpec {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

public enum SaharaStatusColor {
    /// Successo / online (#2E7D32)
    public static let success = Color(red: 46/255, green: 125/255, blue: 50/255)
    /// Warning / in attesa (#B26A00)
    public static let warning = Color(red: 178/255, green: 106/255, blue: 0/255)
    /// Info / attivo (alias primary)
    public static let info = SaharaColors.primary
    /// Errore (alias del token error)
    public static let error = SaharaColors.error
}

// MARK: - Shadow View Modifier

public extension View {
    /// Applica una delle elevazioni di sistema.
    func saharaShadow(_ spec: ShadowSpec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: spec.x, y: spec.y)
    }
}

// MARK: - Sahara Font Modifiers

public struct SaharaFont {
    /// Headline font (Serif / EB Garamond style)
    public static func headline(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    
    /// Body font (Sans-Serif / Manrope style)
    public static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    
    /// Label font (Sans-Serif / Manrope style)
    public static func label(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    
    /// Code / Mono font
    public static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - Material Symbol Icon Helper

public struct MaterialSymbolIcon: View {
    public let name: String
    public let size: CGFloat
    public let color: Color
    public let filled: Bool
    
    public init(_ name: String, size: CGFloat = 20, color: Color = SaharaColors.primary, filled: Bool = false) {
        self.name = name
        self.size = size
        self.color = color
        self.filled = filled
    }
    
    public var body: some View {
        Image(systemName: systemIconName(name))
            .font(.system(size: size, weight: filled ? .semibold : .regular))
            .foregroundColor(color)
    }
    
    private func systemIconName(_ materialName: String) -> String {
        switch materialName {
        case "folder_open": return "folder.badge.plus"
        case "folder": return "folder"
        case "more_horiz": return "ellipsis"
        case "history": return "clock.arrow.circlepath"
        case "bolt": return "bolt.fill"
        case "tune": return "slider.horizontal.3"
        case "cloud": return "cloud"
        case "menu": return "line.3.horizontal"
        case "smart_toy": return "cpu"
        case "terminal": return "terminal"
        case "psychology": return "brain"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "undo": return "arrow.uturn.backward"
        case "auto_awesome": return "sparkles"
        case "lightbulb": return "lightbulb"
        case "speed": return "gauge.with.dots.needle.bottom.50percent"
        case "expand_more": return "chevron.down"
        case "expand_less": return "chevron.up"
        case "add": return "plus"
        case "arrow_upward": return "arrow.up"
        case "arrow_back": return "arrow.left"
        case "content_copy": return "doc.on.doc"
        case "save": return "square.and.arrow.down"
        case "vibration": return "iphone.radiowaves.left.and.right"
        case "insights": return "chart.xyaxis.line"
        case "alternate_email": return "at"
        case "attach_file": return "paperclip"
        case "check": return "checkmark"
        case "settings": return "gear"
        case "dns": return "network"
        case "person": return "person.crop.circle"
        case "close": return "xmark"
        case "compress": return "arrow.down.right.and.arrow.up.left"
        case "error": return "exclamationmark.triangle.fill"
        case "help": return "questionmark.circle"
        case "info": return "info.circle"
        case "search": return "magnifyingglass"
        case "shield_person": return "person.badge.shield.checkmark"
        case "stop": return "stop.fill"
        case "wifi_off": return "wifi.slash"
        case "message": return "message"
        case "search_off": return "magnifyingglass"
        case "magnifyingglass": return "magnifyingglass"
        case "folder.open": return "folder"
        case "person.2": return "person.2"
        case "chevron_right": return "chevron.right"
        default: return "sparkle"
        }
    }
}
