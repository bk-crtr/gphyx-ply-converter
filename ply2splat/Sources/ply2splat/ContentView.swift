import SwiftUI
import AppKit

// MARK: - Visual Effect
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Colors
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}

struct GPHYXColors {
    static let bg = Color(hex: "050505")
    static let card = Color(white: 1, opacity: 0.03)
    static let accent  = Color(hex: "406AFF")
    static let textMain = Color.white
}

struct DotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let dotSize: CGFloat = 0.5
            let spacing: CGFloat = 4.0
            let dotColor = Color.white.opacity(0.2)
            
            for x in stride(from: 0, to: size.width, by: spacing) {
                for y in stride(from: 0, to: size.height, by: spacing) {
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                }
            }
        }
    }
}

// MARK: - Components

struct GPHYXIconButton: View {
    let icon: String
    let action: () -> Void
    var isProminent: Bool = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(isProminent ? GPHYXColors.accent : GPHYXColors.card)
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

struct GPHYXSegmentedPicker: View {
    let options: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<options.count, id: \.self) { i in
                Button(action: { selection = i }) {
                    Text(options[i])
                        .font(.custom("Cairo", size: 11).weight(.bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selection == i ? GPHYXColors.accent : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.25))
        .cornerRadius(10)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.custom("Cairo", size: 10).weight(.black))
            .foregroundColor(.white.opacity(0.5))
            .tracking(1)
    }
}

struct FileRowCard: View {
    let label: String
    let value: String
    let placeholder: String
    let onPick: () -> Void
    var onReveal: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            HStack(spacing: 8) {
                Text(value.isEmpty ? placeholder : (URL(fileURLWithPath: value).lastPathComponent))
                    .font(.custom("Cairo", size: 13))
                    .foregroundColor(value.isEmpty ? .white.opacity(0.35) : .white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GPHYXIconButton(icon: "folder", action: onPick)
                if let reveal = onReveal {
                    GPHYXIconButton(icon: "arrow.up.right", action: reveal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(GPHYXColors.card)
            .cornerRadius(14)
        }
    }
}

// MARK: - Status Card (compact)
struct CompactStatusCard: View {
    let splatCount: Int
    let vram: Double
    let size: Double
    let fileSHDegree: Int
    let progress: Double
    let isConverting: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Progress Ring + Count
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 6)
                    .frame(width: 110, height: 110)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(GPHYXColors.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 110, height: 110)
                    .animation(.easeOut(duration: 0.3), value: progress)

                VStack(spacing: 2) {
                    Text(isConverting ? "\(Int(progress * 100))%" : formatCount(splatCount))
                        .font(.custom("Cairo", size: 24).weight(.black))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(isConverting ? "converting" : "splats")
                        .font(.custom("Cairo", size: 11).weight(.bold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            // Stats row
            HStack(spacing: 0) {
                statItem(label: "VRAM", value: String(format: "%.0f MB", vram))
                Divider().background(.white.opacity(0.15)).frame(height: 30)
                statItem(label: "SIZE", value: String(format: "%.1f MB", size))
                Divider().background(.white.opacity(0.15)).frame(height: 30)
                statItem(label: "SH DEGREE", value: "\(fileSHDegree)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(GPHYXColors.card)
            .cornerRadius(12)
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.custom("Cairo", size: 9).weight(.black)).foregroundColor(.white.opacity(0.45))
            Text(value).font(.custom("Cairo", size: 16).weight(.black)).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Main View
struct ContentView: View {
    @StateObject private var viewModel = ConversionViewModel()

    init() {
        if let fontURL = Bundle.main.url(forResource: "Cairo-VariableFont_slnt,wght", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }

    var body: some View {
        ZStack {
            GPHYXColors.bg.ignoresSafeArea()
            
            // Background Logo (behind grid)
            HStack(spacing: 0) {
                Spacer()
                VStack {
                    if let logoURL = Bundle.main.url(forResource: "GPHYX_LOGO_Vertical", withExtension: "png"),
                       let nsImg = NSImage(contentsOf: logoURL) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80)
                            .opacity(0.8)
                            .shadow(color: GPHYXColors.accent.opacity(0.3), radius: 20)
                            .offset(y: 120)
                    }
                }
                .frame(width: 300)
            }
            .ignoresSafeArea()
            
            DotGridBackground().ignoresSafeArea()
            
            HStack(alignment: .top, spacing: 0) {

                // ── Left panel ──────────────────────
                VStack(alignment: .leading, spacing: 20) {

                    // Header
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("GPHYX")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(GPHYXColors.accent)
                            Text("PLY2SPLAT")
                                .font(.custom("Cairo", size: 22).weight(.black))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "https://gphyx.lemonsqueezy.com/checkout/buy/42bb58be-a091-46a7-b938-81a79ef605d7")!)
                        }) {
                            Text("☕ Buy me a coffee")
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(GPHYXColors.accent)
                                .cornerRadius(8)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().background(Color.white.opacity(0.05))

                    // Source
                    FileRowCard(
                        label: "SOURCE FILE",
                        value: viewModel.inputPath,
                        placeholder: "Choose a PLY file...",
                        onPick: viewModel.selectInputFile
                    )

                    // Destination
                    FileRowCard(
                        label: "DESTINATION",
                        value: viewModel.outputDirectory,
                        placeholder: "Output folder…",
                        onPick: viewModel.selectOutputDirectory,
                        onReveal: viewModel.openOutputDirectory
                    )

                    // SH Degree
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "SH DEGREE")
                        GPHYXSegmentedPicker(
                            options: ["Auto", "0", "1", "2", "3"],
                            selection: $viewModel.shDegreeIndex
                        )
                    }

                    // Reduce Splats
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "REDUCE SPLATS")
                        GPHYXSegmentedPicker(
                            options: ["40%", "60%", "80%", "100%"],
                            selection: $viewModel.splatPercentIndex
                        )
                    }

                    Spacer()

                    // Action buttons
                    VStack(spacing: 10) {
                        Button(action: viewModel.startConversion) {
                            Text(viewModel.isConverting ? "CONVERTING…" : "START CONVERSION")
                                .font(.custom("Cairo", size: 15).weight(.black))
                                .tracking(1)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(viewModel.isConverting
                                              ? GPHYXColors.accent.opacity(0.5)
                                              : GPHYXColors.accent)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isConverting || viewModel.inputPath.isEmpty)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity)

                // ── Right panel ─────────────────────
                VStack(alignment: .center, spacing: 20) {
                    HStack(spacing: 12) {
                        SectionLabel(text: "SYSTEM STATUS")
                        Spacer()
                        Button(action: viewModel.copyLogsToClipboard) {
                            Text("COPY")
                                .font(.custom("Cairo", size: 10).weight(.black))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: viewModel.clearLogs) {
                            Text("CLEAR")
                                .font(.custom("Cairo", size: 10).weight(.black))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }

                    CompactStatusCard(
                        splatCount: viewModel.splatCount,
                        vram: viewModel.estimatedVRAM,
                        size: viewModel.fileSizeMB,
                        fileSHDegree: viewModel.fileSHDegree,
                        progress: viewModel.progress,
                        isConverting: viewModel.isConverting
                    )

                    // Log
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(viewModel.logMessages.map { $0.text }.joined(separator: "\n"))
                                .font(.custom("Cairo", size: 10))
                                .foregroundColor(.white.opacity(0.65))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                                .id("logBottom")
                        }
                        .onChange(of: viewModel.logMessages.count) { _ in
                            withAnimation {
                                proxy.scrollTo("logBottom", anchor: .bottom)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GPHYXColors.card)
                    .cornerRadius(14)
                }
                .padding(28)
                .frame(width: 300)
                .background(Color.black.opacity(0.18))
            }
        }
        .frame(minWidth: 750, minHeight: 500)
    }
}
