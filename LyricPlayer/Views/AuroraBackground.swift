import SwiftUI
import AppKit

/// 背景：浅色（近白）中性底 + 跟随系统强调色的氛围光。
/// 克制、安静（不随音乐晃动）——动态和彩虹只属于边缘光晕。
struct AuroraBackground: View {
    var body: some View {
        // 空闲时氛围漂移降到 6fps（本来就是极缓慢的低频运动，肉眼无感）
        let model = PlayerModel.shared
        let idle = model.currentTrack == nil || !model.isPlaying
        TimelineView(.animation(minimumInterval: idle ? 1.0 / 6.0 : 1.0 / 12.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let accent = Color(nsColor: .controlAccentColor)

            ZStack {
                Color(red: 0.965, green: 0.963, blue: 0.972)   // 近白，微冷（Apple 浅灰系）

                // 系统强调色的氛围光：两大一小，极缓慢漂移
                RadialGradient(colors: [accent.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.85 + 0.03 * sin(t * 0.11),
                                                 y: 0.12 + 0.03 * sin(t * 0.09 + 1.7)),
                               startRadius: 0, endRadius: 640)
                RadialGradient(colors: [accent.opacity(0.07), .clear],
                               center: UnitPoint(x: 0.10 + 0.03 * sin(t * 0.08 + 3.1),
                                                 y: 0.90 + 0.02 * sin(t * 0.12 + 0.6)),
                               startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color.white.opacity(0.5), .clear],
                               center: UnitPoint(x: 0.45, y: 0.42),
                               startRadius: 0, endRadius: 900)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
    }
}

/// Siri / Apple Intelligence 边缘光晕 v3。
/// 结构移植自 alessiorubicini/AppleIntelligenceForSwiftUI 的 AIScreenGlow（MIT）：
/// - 颜色不是固定色盘，而是 7 个 HSB 动态色——色相/饱和度逐帧漂移（"活"的关键）；
/// - 渐变角度按 ±120° 摇摆而非匀速旋转；
/// - 三层描边（6/10/28~44 递进模糊），各自按不同频率呼吸透明度与模糊。
/// 在其基础上接入音乐：相位积分随鼓点加速（连续无瞬移），
/// 线宽/亮度吃阻尼余弦弹跳包络（果冻感回弹）。
struct EdgeGlow: View {
    let levelProvider: () -> Float
    let pulseProvider: () -> Float
    /// 视频播放时返回画面边缘的 8 个氛围色（顺时针）；nil = 彩虹模式。
    var ambientProvider: () -> [NSColor]? = { nil }
    @State private var dynamics = GlowDynamics()

    var body: some View {
        // 空闲（无曲目/暂停）降帧到 8fps：三层大 blur 描边是全应用最大的单项
        // GPU 开销，空闲时以 30fps 常跑等于白烧 1-3W 的持续功耗
        let model = PlayerModel.shared
        let idle = model.currentTrack == nil || !model.isPlaying
        TimelineView(.animation(minimumInterval: idle ? 1.0 / 8.0 : 1.0 / 30.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            dynamics.advance(to: now, level: CGFloat(levelProvider()), pulse: CGFloat(pulseProvider()),
                             ambient: ambientProvider())
            let phase = dynamics.gradientPhase
            let pop = dynamics.beatEnvelope            // 阻尼余弦：弹起→回弹→静止
            let lift = Double(max(0, pop))
            let level = Double(dynamics.displayLevel)

            return GeometryReader { geo in
                let size = geo.size
                // 贴合 macOS 窗口真实圆角（约 20pt）；按比例算会在角部划进内容（"漏光"）
                let cornerRadius: CGFloat = 20

                // 音乐：HSB 动态彩虹（原仓库配方）；视频：画面边缘氛围色（实时采样+缓动）
                let colors: [Color] = dynamics.hasAmbient
                    ? dynamics.ambientColors()
                    : (0..<7).map { i in
                        let base = Double(i) / 6.0
                        let hue = (base + sin(phase * 0.9 + base * .pi * 2) * 0.08 + 1)
                            .truncatingRemainder(dividingBy: 1)
                        let saturation = 0.8 + 0.15 * sin(phase * 0.7 + base * .pi)
                        return Color(hue: hue, saturation: saturation, brightness: 1.0)
                    }
                let gradient = AngularGradient(
                    gradient: Gradient(colors: colors + [colors[0]]),
                    center: .center,
                    angle: dynamics.hasAmbient ? .degrees(-90 + sin(phase * 0.5) * 6) : .degrees(sin(phase * 1.2) * 120 + 180)
                )

                // 逐层呼吸（频率互不相同）+ 音乐抬升；氛围（视频）模式整体更亮
                let ambientBoost = dynamics.hasAmbient ? 0.30 : 0.0
                let primaryOpacity = 0.5 + 0.15 * sin(phase * 1.1 + .pi / 4) + lift * 0.35 + level * 0.10 + ambientBoost
                let secondaryOpacity = 0.24 + 0.10 * sin(phase * 0.9 + .pi / 3) + lift * 0.30 + level * 0.08 + ambientBoost
                let tertiaryOpacity = 0.14 + 0.05 * sin(phase * 0.7) + lift * 0.22 + level * 0.06 + ambientBoost * 0.8
                let tertiaryBlur: CGFloat = 30 + CGFloat((sin(phase * 0.8) * 0.5 + 0.5) * 16)
                // 鼓点弹跳作用于线宽（负半周轻微收缩 = 果冻感）
                let squash = Double(pop) * 14

                ZStack {
                    // 亮核：贴边细线
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(gradient, lineWidth: max(2, 5 + squash * 0.4))
                        .blur(radius: 2)
                        .opacity(min(1, primaryOpacity))
                    // 中层辉光
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(gradient, lineWidth: max(6, 14 + squash * 1.2))
                        .blur(radius: 12)
                        .opacity(min(1, secondaryOpacity))
                    // 大范围溢光：向内洇开，是"光"而不是"框"
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(gradient, lineWidth: max(16, 38 + squash * 2.4))
                        .blur(radius: tertiaryBlur)
                        .opacity(min(1, tertiaryOpacity))
                }
                .frame(width: size.width, height: size.height)
                .drawingGroup()
                // 视频（深色画面）用加色混合：光叠在画面上发亮，而不是覆盖一圈塑料描边。
                // 必须放在 drawingGroup 之后——放里面会先在离屏的透明底上解算，
                // 落回视频画面时退化成普通 alpha 合成，加色叠亮实际不生效
                .blendMode(dynamics.hasAmbient ? .plusLighter : .normal)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// 光晕动力学：相位积分（音乐只加速、不瞬移）+ 全局阻尼余弦弹跳 +
/// 视频氛围色缓动（采样值为目标、指数逼近，颜色渐变不跳变）。
final class GlowDynamics {
    private(set) var gradientPhase: Double = 0
    private(set) var displayLevel: CGFloat = 0
    private(set) var displayPulse: CGFloat = 0
    private(set) var hasAmbient = false
    private var ambientCurrent: [SIMD3<Double>] = Array(repeating: SIMD3(0.5, 0.5, 0.5), count: 8)
    private var ambientTarget: [SIMD3<Double>] = Array(repeating: SIMD3(0.5, 0.5, 0.5), count: 8)
    private var beatAge: Double = 99
    private var lastRawPulse: CGFloat = 0
    private var lastTime: TimeInterval?

    func ambientColors() -> [Color] {
        ambientCurrent.enumerated().map { index, rgb in
            // 亮度归一化：把最亮分量抬到至少 0.75，弱光画面也有明确的氛围光
            let peak = max(rgb.x, max(rgb.y, rgb.z))
            let gain = peak > 0.02 ? max(1.0, 0.75 / peak) : 1.0
            // 亮度行波：一道微光沿边缘环行（相位随鼓点加速），机械感的解药
            let wave = 1.0 + 0.18 * sin(gradientPhase * 0.8 + Double(index) / 8.0 * 2 * .pi)
            return Color(red: min(1, rgb.x * gain * wave),
                         green: min(1, rgb.y * gain * wave),
                         blue: min(1, rgb.z * gain * wave))
        }
    }

    /// 阻尼余弦弹跳包络：起跳→回弹 2~3 次→静止，负半周是轻微压扁。
    var beatEnvelope: CGFloat {
        guard beatAge < 2.2 else { return 0 }
        return CGFloat(exp(-2.2 * beatAge) * cos(2 * .pi * 1.35 * beatAge))
    }

    func advance(to now: TimeInterval, level: CGFloat, pulse: CGFloat, ambient: [NSColor]?) {
        let dt = min(0.1, max(0, now - (lastTime ?? now)))
        lastTime = now
        guard dt > 0 else { return }

        // 氛围色：采样值作为目标，1.3/s 指数逼近——颜色流畅过渡、永不跳变
        if let ambient, ambient.count == 8 {
            hasAmbient = true
            for (i, c) in ambient.enumerated() {
                let rgb = c.usingColorSpace(.deviceRGB) ?? c
                ambientTarget[i] = SIMD3(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
            }
        } else {
            hasAmbient = false
        }
        for i in ambientCurrent.indices {
            ambientCurrent[i] += (ambientTarget[i] - ambientCurrent[i]) * min(1, dt * 1.3)
        }

        let rate = level > displayLevel ? 10.0 : 3.0
        displayLevel += (level - displayLevel) * min(1, CGFloat(dt) * rate)

        if pulse > lastRawPulse + 0.35 { beatAge = 0 }   // 鼓点上升沿
        lastRawPulse = pulse
        beatAge += dt

        if pulse > displayPulse {
            displayPulse = pulse
        } else {
            displayPulse += (pulse - displayPulse) * min(1, CGFloat(dt) * 9)
        }

        // 原仓库基础速度 0.25；响度托底、鼓点冲刺——只作用于相位速度，永远连续
        gradientPhase += dt * (0.25 + Double(displayLevel) * 0.5 + Double(displayPulse) * 1.6)
    }
}
