import SwiftUI
import AppKit

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

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Dashboard Components

struct GPHYXColors {
    static let bg = Color(hex: "0D0D0D")
    static let card = Color(hex: "1A1A1A")
    static let accent = Color(hex: "E64A19") // Muted Electric Orange (10% less bright)
    static let accentBlue = Color.blue
    static let textMain = Color.white
    static let textSec = Color.white.opacity(0.8)
}

struct GPHYXButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Cairo", size: 16).weight(.bold))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(isProminent ? GPHYXColors.accent : GPHYXColors.card)
            )
            .foregroundColor(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct GPHYXEqualizerView: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(GPHYXColors.accent)
                    .frame(width: 8, height: CGFloat([30, 50, 40, 60][i]))
            }
        }
        .padding(8)
        .background(GPHYXColors.card)
        .cornerRadius(12)
    }
}

struct GPHYXRoundButton: View {
    let icon: String
    let action: () -> Void
    var isOn: Bool = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(GPHYXColors.card)
                    .shadow(color: isOn ? GPHYXColors.accent.opacity(0.6) : Color.white.opacity(0.3), 
                            radius: isOn ? 15 : 8, x: 0, y: 3)
                    .overlay(
                        Circle().stroke(isOn ? GPHYXColors.accent.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(isOn ? GPHYXColors.accent : .white.opacity(0.7))
            }
            .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
    }
}

struct GPHYXStatusCardRefined: View {
    let value: String
    let label: String
    var progress: Double = 0.0
    var isConverting: Bool = false
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(GPHYXColors.accent)
            
            VStack(spacing: 8) {
                ZStack {
                    // Empty Dots (Faint White)
                    DashedCircleStatic(count: 32)
                        .foregroundColor(Color.white.opacity(0.3))
                    
                    // Filled Dots based on progress (Bright White)
                    DashedCircleStatic(count: 32, limit: Int(progress * 32))
                        .foregroundColor(Color.white)
                    
                    VStack {
                        Text(isConverting ? "\(Int(progress * 100))%" : value)
                            .font(.custom("Cairo", size: 42).weight(.black))
                            .minimumScaleFactor(0.3)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .foregroundColor(.white)
                        Text(isConverting ? "converting..." : label)
                            .font(.custom("Cairo", size: 14).weight(.bold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .frame(width: 140, height: 140)
            }
        }
        .frame(width: 220, height: 220)
    }
}

struct DashedCircleStatic: View {
    let count: Int
    var limit: Int = 32
    
    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width/2, y: geo.size.height/2)
            let radius = min(geo.size.width, geo.size.height)/2
            
            ForEach(0..<32, id: \.self) { i in
                Circle()
                    .frame(width: 4, height: 4)
                    .position(x: center.x + radius * cos(CGFloat(i) * (2 * .pi / 32) - .pi/2),
                              y: center.y + radius * sin(CGFloat(i) * (2 * .pi / 32) - .pi/2))
                    .opacity(i < limit ? 1.0 : 0.3)
            }
        }
    }
}

struct GPHYXSegmentedPicker: View {
    let options: [String]
    @Binding var selection: Int
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<options.count, id: \.self) { i in
                Button(action: { selection = i }) {
                    Text(options[i])
                        .font(.custom("Cairo", size: 12).weight(.bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection == i ? GPHYXColors.accentBlue : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.2))
        .cornerRadius(10)
    }
}

struct StatLabel: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.custom("Cairo", size: 10).weight(.black)).foregroundColor(.white)
            Text(value).font(.custom("Cairo", size: 18).weight(.black)).foregroundColor(GPHYXColors.textMain)
        }
    }
}

// MARK: - Main Application

struct ContentView: View {
    @StateObject private var viewModel = ConversionViewModel()
    @State private var isTargeted = false
    
    init() {
        if let fontURL = Bundle.main.url(forResource: "Cairo-VariableFont_slnt,wght", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }
    
    var body: some View {
        ZStack {
            GPHYXColors.bg.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Top Bar
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPHYX").font(.system(size: 14, weight: .black)).foregroundColor(GPHYXColors.accent)
                        Text("PLY Utility").font(.custom("Cairo", size: 24).weight(.black)).foregroundColor(.white)
                    }
                    Spacer()
                    Button("Buy me a coffee") {}.buttonStyle(GPHYXButtonStyle())
                }
                .padding(32)
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Main Sections Row
                        HStack(alignment: .top, spacing: 24) {
                            // Left Column: Inputs
                            VStack(alignment: .leading, spacing: 20) {
                                Text("FILES")
                                    .font(.custom("Cairo", size: 14).weight(.black))
                                    .foregroundColor(.white)
                                
                                // Source File Card
                                HomeCard(title: "SOURCE PLY") {
                                    HStack {
                                        Text(viewModel.inputPath.isEmpty ? "Drag & drop file..." : URL(fileURLWithPath: viewModel.inputPath).lastPathComponent)
                                            .font(.custom("Cairo", size: 14))
                                            .foregroundColor(.white)
                                        Spacer()
                                        GPHYXRoundButton(icon: "folder", action: viewModel.selectInputFile)
                                    }
                                }
                                
                                // Destination Card
                                HomeCard(title: "DESTINATION") {
                                    HStack(spacing: 12) {
                                        Text(viewModel.outputDirectory.isEmpty ? "No folder set" : viewModel.outputDirectory)
                                            .font(.custom("Cairo", size: 12))
                                            .lineLimit(1)
                                            .foregroundColor(.white)
                                        Spacer()
                                        GPHYXRoundButton(icon: "plus", action: viewModel.selectOutputDirectory)
                                        GPHYXRoundButton(icon: "arrow.up.right", action: viewModel.openOutputDirectory)
                                    }
                                }
                                
                                // Preset Block
                                Button(action: viewModel.applyWebReadyPreset) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text("Web Ready Preset").font(.custom("Cairo", size: 14).weight(.black))
                                            Text("Optimized for web players").font(.caption).foregroundColor(.white)
                                        }
                                        Spacer()
                                        GPHYXEqualizerView()
                                    }
                                    .padding()
                                    .background(GPHYXColors.accent)
                                    .foregroundColor(.white)
                                    .cornerRadius(20)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // Right Column: Status Card
                            VStack(spacing: 20) {
                                Text("SYSTEM STATUS")
                                    .font(.custom("Cairo", size: 14).weight(.black))
                                    .foregroundColor(.white)
                                
                                GPHYXStatusCardRefined(
                                    value: viewModel.splatCount > 0 ? viewModel.splatCount.formatted() : "0", 
                                    label: "total splats",
                                    progress: viewModel.progress,
                                    isConverting: viewModel.isConverting
                                )
                                
                                HStack {
                                    StatLabel(title: "VRAM", value: String(format: "%.0f MB", viewModel.estimatedVRAM))
                                    Spacer()
                                    StatLabel(title: "SIZE", value: String(format: "%.1f MB", viewModel.fileSizeMB))
                                }
                                .padding()
                                .background(GPHYXColors.card)
                                .cornerRadius(20)
                            }
                        }
                        
                        // Settings Section
                        VStack(alignment: .leading, spacing: 20) {
                            Text("CONVERSION SETTINGS")
                                .font(.custom("Cairo", size: 14).weight(.black))
                                .foregroundColor(.white)
                            
                            HStack(spacing: 32) {
                                Toggle(".splat", isOn: $viewModel.exportSplat)
                                Toggle(".ksplat", isOn: $viewModel.exportKSplat)
                                Toggle(".spz", isOn: $viewModel.exportSPZ)
                            }
                            .toggleStyle(GPHYXToggleStyle())
                            
                            HStack(spacing: 24) {
                                VStack(alignment: .leading) {
                                    Text("COMPRESSION").font(.custom("Cairo", size: 12).weight(.bold)).foregroundColor(.white)
                                    GPHYXSegmentedPicker(options: ["None", "Float16", "Uint8"], selection: $viewModel.compressionLevel)
                                        .frame(width: 300)
                                }
                                
                                Spacer()
                                
                                GPHYXRoundButton(icon: "power", action: { viewModel.useMetal.toggle() }, isOn: viewModel.useMetal)
                                Text("METAL").font(.custom("Cairo", size: 12).weight(.black)).foregroundColor(.white)
                            }
                        }
                        .padding(32)
                        .background(GPHYXColors.card)
                        .cornerRadius(32)
                        
                        // Action Footer
                        VStack(spacing: 16) {
                            Button(action: viewModel.startConversion) {
                                Text(viewModel.isConverting ? "CONVERTING..." : "START CONVERSION")
                                    .tracking(2)
                            }
                            .buttonStyle(GPHYXButtonStyle(isProminent: true))
                            .disabled(viewModel.isConverting || viewModel.inputPath.isEmpty)
                        }
                        .padding(.top, 20)
                    }
                    .padding(32)
                }
            }
        }
        .frame(minWidth: 850, minHeight: 800)
    }
}

struct HomeCard<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.custom("Cairo", size: 10).weight(.black)).foregroundColor(.white)
            content
                .padding()
                .background(GPHYXColors.card)
                .cornerRadius(20)
        }
    }
}

struct GPHYXToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                Circle()
                    .fill(configuration.isOn ? GPHYXColors.accentBlue : Color.white.opacity(0.1))
                    .frame(width: 12, height: 12)
                configuration.label
                    .font(.custom("Cairo", size: 14).weight(.bold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
    }
}
