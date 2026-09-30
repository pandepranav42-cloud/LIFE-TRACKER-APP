import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Theme: "Study Space" — warm cream, soft latte, cocoa accent
//
// One palette for the whole app. Every token has a light and a dark value and
// switches automatically with the system appearance (or the Appearance choice
// in Settings). Nothing in the app should hard-code a background colour —
// use these tokens so light/dark always stays in sync.

enum Palette {
    /// Page background.
    static let surface    = dynamic("FFFDF8", "171513")
    /// Sidebar background.
    static let sidebar    = dynamic("F7F0E4", "1C1916")
    /// Cards, fields, sheets.
    static let elevated   = dynamic("FFFFFF", "221E1A")
    /// Soft cream callout / header strip.
    static let callout    = dynamic("F7EFDC", "2E281F")
    /// Hairline borders and dividers.
    static let hairline   = dynamic("EDE3D1", "3A322A")
    /// Very light fill (empty bars, hover, weekends).
    static let subtleFill = dynamic("F4ECDD", "2A241E")
    /// Secondary text.
    static let mutedText  = dynamic("9A8573", "A8957F")
    /// Primary accent — cocoa brown (light) / latte (dark).
    static let accent     = dynamic("8A6446", "D8B48E")
    /// Foreground on top of `accent`.
    static let onAccent   = dynamic("FFFFFF", "1E1A16")
    /// Schedule tasks (kept visually separate from habits in Progress).
    static let schedule   = dynamic("7F9AB5", "9DB6CE")
    /// Tan used for the clock / calendar pills.
    static let tan        = dynamic("C4A27F", "6E5640")

    // MARK: Dynamic colour helper

    static func dynamic(_ light: String, _ dark: String) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? platformColor(dark) : platformColor(light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? platformColor(dark) : platformColor(light)
        })
        #endif
    }

    #if os(macOS)
    static func platformColor(_ hex: String) -> NSColor {
        let (r, g, b) = rgb(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    #else
    static func platformColor(_ hex: String) -> UIColor {
        let (r, g, b) = rgb(hex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
    #endif

    private static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }
}

// MARK: - Typography

extension Font {
    /// Monospaced "notebook" face used for titles and headings across the app.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Appearance setting

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the Appearance setting to the whole app.
///
/// SwiftUI's `.preferredColorScheme(nil)` doesn't reliably hand control back
/// to the system after a forced Light/Dark (the window stays stuck in the last
/// forced mode). So we set the appearance at the app / window level instead:
/// `nil` there truly means "follow the system".
enum AppearanceController {
    static func apply(_ mode: AppearanceMode) {
        #if os(macOS)
        switch mode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        #else
        let style: UIUserInterfaceStyle
        switch mode {
        case .system: style = .unspecified
        case .light:  style = .light
        case .dark:   style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
        #endif
    }
}

/// Keeps the app's appearance in sync with the saved setting.
struct AppearanceSync: ViewModifier {
    @AppStorage("appearance") private var appearanceRaw: String = AppearanceMode.system.rawValue

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: appearanceRaw) { _, _ in apply() }
    }

    private func apply() {
        let mode = AppearanceMode(rawValue: appearanceRaw) ?? .system
        // Next runloop so the window exists on first launch.
        DispatchQueue.main.async { AppearanceController.apply(mode) }
    }
}

// MARK: - Responsive layout
//
// The detail area publishes its current width into the environment so every
// page can adapt — Mac window resizing, iPad full screen, Split View and
// Slide Over all go through the same path.

private struct LayoutWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1000
}

extension EnvironmentValues {
    var layoutWidth: CGFloat {
        get { self[LayoutWidthKey.self] }
        set { self[LayoutWidthKey.self] = newValue }
    }
}

enum AppLayout {
    /// Phone-sized column (iPad Slide Over, narrow Split View, small Mac window).
    static func isCompact(_ width: CGFloat) -> Bool { width < 600 }
    static func pagePadding(_ width: CGFloat) -> CGFloat {
        width < 600 ? 18 : (width < 900 ? 28 : 40)
    }
}

/// Standard page wrapper: responsive side padding, readable max width, centred.
struct PageContainer: ViewModifier {
    @Environment(\.layoutWidth) private var width
    var maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppLayout.pagePadding(width))
            .padding(.vertical, AppLayout.isCompact(width) ? 20 : 32)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    func pageContainer(maxWidth: CGFloat = 900) -> some View { modifier(PageContainer(maxWidth: maxWidth)) }

    /// Grouped form that sits on the warm page background.
    func themedForm() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Palette.surface)
    }

    /// Fixed sheet size on the Mac; on iPad the system sizes sheets itself.
    @ViewBuilder
    func sheetFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width, height: height)
        #else
        self.frame(minWidth: 320, idealWidth: width, minHeight: 300)
            .background(Palette.surface)
        #endif
    }

    /// Minimum window size on the Mac only (iPad must fit any multitasking size).
    @ViewBuilder
    func macMinSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }

    /// Removes the Mac window toolbar's own white/grey strip and divider so
    /// the sidebar's cream and the page background run right up to the top
    /// of the window — including in full screen, where macOS otherwise draws
    /// an opaque toolbar band with a hairline under it.
    @ViewBuilder
    func blendedToolbar() -> some View {
        #if os(macOS)
        self.toolbarBackground(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }

    /// Popover that stays a popover on iPad even in compact width.
    @ViewBuilder
    func compactPopoverAdaptation() -> some View {
        #if os(iOS)
        self.presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }
}

// MARK: - Platform bridges (Mac ↔ iPad)

#if os(macOS)
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}
#else
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}
#endif

enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    static func pastedString() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return UIPasteboard.general.string
        #endif
    }
}

// MARK: - Sharing
//
// Opens the system share sheet for one or more files: AirDrop, Messages, Mail,
// WhatsApp, Notes, Save to Files — whatever the device has installed. Used by
// the share button on study materials and by the portal's downloads.
//
// It's deliberately imperative rather than a `ShareLink`: the file's bytes are
// only written to disk at the moment you press share, not every time a card
// draws on screen.

enum ShareTools {
    @MainActor
    static func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        #if os(macOS)
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let view = window?.contentView else { return }
        var anchor = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        if let point = NSApp.currentEvent?.locationInWindow {
            let local = view.convert(point, from: nil)
            anchor = CGRect(x: local.x, y: local.y, width: 1, height: 1)
        }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        guard var top = window?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX,
                                        y: top.view.bounds.maxY - 80,
                                        width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
        #endif
    }
}

// MARK: - Cards

struct HairlineCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(Palette.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 6, y: 2)
    }
}

extension View {
    func hairlineCard() -> some View { modifier(HairlineCard()) }
}

extension Color {
    /// Builds a Color from a 6-digit hex string like "8AA6C9". Falls back to gray.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        guard s.count == 6 else { self = .gray; return }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

/// Soft, warm swatches people pick from when creating categories, marks,
/// schedule items and journal colours.
enum CategoryColorSwatches {
    static let hexValues = [
        "E8C9A8", // latte
        "D9B38C", // caramel
        "E6B8B0", // rose
        "F0D9A8", // honey
        "B9C7A5", // matcha
        "A9C9C9", // seafoam
        "A9BCCB", // dusty blue
        "C8B6D6", // lavender
        "D6A5A0", // berry
        "BFB2A3", // stone
    ]
}

/// A small colored-circle trigger that opens a swatch grid. Uses a popover
/// rather than a Menu because native menu items drop custom coloured shapes.
struct ColorSwatchButton: View {
    @Binding var selection: String
    var size: CGFloat = 20
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            Circle()
                .fill(Color(hex: selection))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5), spacing: 8) {
                ForEach(CategoryColorSwatches.hexValues, id: \.self) { hex in
                    Button {
                        selection = hex
                        showingPicker = false
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().strokeBorder(hex == selection ? Palette.accent : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .compactPopoverAdaptation()
        }
    }
}

/// Section title in the notebook style: "-habits", italic mono, cocoa.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.lowercased())
                .font(.mono(14, .bold))
                .italic()
                .foregroundStyle(Palette.accent)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.mono(11))
                    .foregroundStyle(Palette.mutedText)
            }
        }
    }
}

/// Page title used at the top of each section (monospaced, soft).
struct PageTitle: View {
    let title: String
    var subtitle: String? = nil
    @Environment(\.layoutWidth) private var width

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Palette.accent)
                    .frame(width: 3, height: AppLayout.isCompact(width) ? 22 : 28)
                Text(title)
                    .font(.mono(AppLayout.isCompact(width) ? 22 : 28, .bold))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.mono(12))
                    .foregroundStyle(Palette.mutedText)
                    .padding(.leading, 15)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Labeled text field for grouped Forms.
///
/// macOS right-aligns plain `TextField`s inside a `.grouped` Form, and a
/// right-aligned field doesn't draw trailing spaces until the next character
/// is typed. This keeps the label on the left but types left-to-right.
struct FormTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var axis: Axis

    init(_ title: String, text: Binding<String>, prompt: String? = nil, axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.axis = axis
    }

    var body: some View {
        LabeledContent {
            TextField(title, text: $text, prompt: Text(prompt ?? title), axis: axis)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
        }
    }
}

/// The LifeTracker app logo (from Assets → AppLogo), as a soft rounded tile.
struct AppLogo: View {
    var size: CGFloat = 88
    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: size * 0.12, y: size * 0.05)
            .accessibilityLabel("LifeTracker")
    }
}

extension CharacterSet {
    /// Everything a URL may legally contain — used to clean up pasted links
    /// without mangling ones that are already encoded.
    static let urlAllowedForLinks: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.formUnion(.urlPathAllowed)
        set.formUnion(.urlHostAllowed)
        set.formUnion(.urlFragmentAllowed)
        set.formUnion(CharacterSet(charactersIn: "#%[]"))
        return set
    }()
}
