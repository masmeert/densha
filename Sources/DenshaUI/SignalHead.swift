import DenshaCore
import SwiftUI

enum SignalMetrics {
    static let lampDiameter: CGFloat = 5
    static let lampSpacing: CGFloat = 2
    static let housingPadding: CGFloat = 3
    static let housingCornerRadius: CGFloat = 3
    static let width = lampDiameter + housingPadding * 2
    static let height = lampDiameter * 3 + lampSpacing * 2 + housingPadding * 2
}

enum SignalAspect: Hashable {
    case danger
    case caution
    case proceed
    case dark

    init(state: ServiceState, health: HealthState) {
        switch state {
        case .running: self = health == .failing ? .caution : .proceed
        case .unhealthy: self = .caution
        case .starting, .stopping: self = .caution
        case .failed: self = .danger
        case .stopped, .exited: self = .dark
        }
    }

    init(worstOf services: [ServiceStatus]) {
        self =
            services
            .map { SignalAspect(state: $0.state, health: $0.health) }
            .max { $0.severity < $1.severity } ?? .dark
    }

    var color: Color {
        switch self {
        case .danger: .red
        case .caution: .orange
        case .proceed: .green
        case .dark: .clear
        }
    }

    var litLamp: Int? {
        switch self {
        case .danger: 0
        case .caution: 1
        case .proceed: 2
        case .dark: nil
        }
    }

    var severity: Int {
        switch self {
        case .danger: 3
        case .caution: 2
        case .proceed: 1
        case .dark: 0
        }
    }

    var description: String {
        switch self {
        case .danger: "danger"
        case .caution: "caution"
        case .proceed: "clear"
        case .dark: "unlit"
        }
    }
}

struct SignalHead: View {
    enum Orientation { case vertical, horizontal }

    let aspect: SignalAspect
    let orientation: Orientation
    let flashes: Bool
    let animate: Bool

    @State private var flashing = false

    init(
        aspect: SignalAspect, orientation: Orientation = .vertical, flashes: Bool = false,
        animate: Bool
    ) {
        self.aspect = aspect
        self.orientation = orientation
        self.flashes = flashes
        self.animate = animate
    }

    init(state: ServiceState, health: HealthState, animate: Bool) {
        self.init(
            aspect: SignalAspect(state: state, health: health),
            flashes: state == .starting || state == .stopping,
            animate: animate)
    }

    var body: some View {
        housing
            .padding(SignalMetrics.housingPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: SignalMetrics.housingCornerRadius, style: .continuous
                )
                .fill(Color.primary.opacity(0.07))
            )
            .frame(
                width: orientation == .vertical ? SignalMetrics.width : SignalMetrics.height,
                height: orientation == .vertical ? SignalMetrics.height : SignalMetrics.width
            )
            .animation(.easeOut(duration: 0.2), value: aspect)
            .onChange(of: flashes, initial: true) { _, isFlashing in
                guard animate else {
                    flashing = false
                    return
                }
                if isFlashing {
                    withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                        flashing = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { flashing = false }
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var housing: some View {
        switch orientation {
        case .vertical: VStack(spacing: SignalMetrics.lampSpacing) { lamps }
        case .horizontal: HStack(spacing: SignalMetrics.lampSpacing) { lamps }
        }
    }

    private var lamps: some View {
        ForEach(0..<3, id: \.self) { lamp in
            let lit = lamp == aspect.litLamp
            Circle()
                .fill(lit ? aspect.color : Color.primary.opacity(0.2))
                .frame(width: SignalMetrics.lampDiameter, height: SignalMetrics.lampDiameter)
                .shadow(color: lit ? aspect.color.opacity(0.5) : .clear, radius: 2.5)
                .opacity(lit && flashing ? 0.3 : 1)
        }
    }
}

struct UnsignalledMarker: View {
    let tint: Color

    var body: some View {
        Circle()
            .strokeBorder(tint, lineWidth: 1)
            .frame(width: SignalMetrics.lampDiameter, height: SignalMetrics.lampDiameter)
            .frame(width: SignalMetrics.width, height: SignalMetrics.height)
            .accessibilityHidden(true)
    }
}

#if DEBUG
    #Preview("Signal aspects") {
        VStack(spacing: 20) {
            HStack(spacing: 18) {
                ForEach(ServiceState.allCases, id: \.self) { state in
                    VStack(spacing: 8) {
                        SignalHead(state: state, health: .none, animate: true)
                        Text(state.rawValue).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 8) {
                    UnsignalledMarker(tint: .secondary.opacity(0.5))
                    Text("foreign").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                ForEach([SignalAspect.danger, .caution, .proceed, .dark], id: \.self) { aspect in
                    SignalHead(aspect: aspect, orientation: .horizontal, animate: false)
                }
            }
        }
        .padding()
    }
#endif
