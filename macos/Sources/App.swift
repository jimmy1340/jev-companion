import AppKit
import SwiftUI

@main
struct JevCompanionApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Jev 伴聊") {
            CompanionView(model: model)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 560, idealHeight: 760)
                .onAppear { model.start() }
        }
        .defaultSize(width: 420, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// MARK: - Palette
// Quiet system-style surfaces that follow the Light / Dark appearance. One accent colour (system blue).

private func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private let chatInk = Color.primary
private let accentBlue = Color(red: 0.0, green: 0.478, blue: 1.0)
private let accentBlueDeep = Color(red: 0.0, green: 0.36, blue: 0.92)
private let bubbleOutgoing = Color(red: 0.04, green: 0.52, blue: 1.0)
private let bubbleOutgoingGrad = LinearGradient(
    colors: [Color(red: 0.08, green: 0.56, blue: 1.0), Color(red: 0.02, green: 0.46, blue: 0.96)],
    startPoint: .topLeading, endPoint: .bottomTrailing
)
private let bubbleIncoming = adaptive(NSColor(white: 0.92, alpha: 1), NSColor(white: 0.22, alpha: 1))
private let bubbleIncomingBorder = adaptive(NSColor(white: 0.88, alpha: 1), NSColor(white: 0.28, alpha: 1))
private let chatPaper = adaptive(NSColor(white: 0.965, alpha: 1), NSColor(white: 0.115, alpha: 1))
private let jevPaper = adaptive(NSColor.white, NSColor(white: 0.18, alpha: 1))
private let hairline = Color.primary.opacity(0.08)

// MARK: - Controls

private struct QuietIconButtonStyle: ButtonStyle {
    var tint: Color = .secondary
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        QuietIconLabel(configuration: configuration, tint: tint)
    }
}

private struct QuietIconLabel: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
            .onHover { hovering = $0 }
    }
}

private struct PillButtonStyle: ButtonStyle {
    var tint: Color = accentBlue
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PillLabel(configuration: configuration, tint: tint)
    }
}

private struct PillLabel: View {
    let configuration: ButtonStyleConfiguration
    var tint: Color = accentBlue
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(enabled ? tint : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill((enabled ? tint : Color.primary).opacity(configuration.isPressed ? 0.22 : 0.10)))
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PrimaryLabel(configuration: configuration)
    }
}

private struct PrimaryLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(enabled ? AnyShapeStyle(bubbleOutgoingGrad) : AnyShapeStyle(Color.primary.opacity(0.08))))
            .shadow(color: enabled ? accentBlue.opacity(configuration.isPressed ? 0.12 : 0.24) : Color.clear, radius: 4, y: 1.5)
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

private extension View {
    func jevSurface(radius: CGFloat = 14, fill: Color = jevPaper) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(hairline, lineWidth: 1))
    }
}

struct CompanionView: View {
    @ObservedObject var model: AppModel
    @State private var floating = true
    @State private var showPaste = true
    @State private var showMemory = false
    @State private var showModels = false
    @State private var showReadDetails = false
    @State private var showEvidence = false
    @State private var selectedAnalysisMessageID: String?
    private let bottomAnchor = "conversation-bottom"

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                conversationHeader
                sourceControls
            }.background(.bar)
            Divider()
            conversation
            composeBar
        }
        .background(chatPaper)
        .foregroundStyle(chatInk)
        .tint(accentBlue)
        .onAppear { model.setFloating(floating) }
        .onChange(of: model.mode) { _ in selectedAnalysisMessageID = nil; model.sourceChanged() }
        .sheet(isPresented: $model.showSettings) { settings }
        .alert("允许分析这个会话？", isPresented: $model.showConsent) {
            Button("取消", role: .cancel) { model.cancelConsent() }
            Button("允许并继续") { model.grantConsent() }
        } message: { Text(model.consentDescription) }
        .alert("删除本工具的会话记忆？", isPresented: $model.showForget) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await model.forgetCurrent() } }
        } message: { Text("只删除本工具为当前记忆名称保存的原文，不能撤销。微信中的聊天记录不受影响。") }
    }

    private var conversationHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.62, blue: 1.0), accentBlueDeep],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color.white)
            }
            .frame(width: 32, height: 32)
            .shadow(color: accentBlue.opacity(0.28), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasMessages ? model.title : "Jev 伴聊")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if model.monitoring {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 5, height: 5)
                            Text("跟随中").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.green)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    } else if model.mode == .demo {
                        HStack(spacing: 4) {
                            Circle().fill(accentBlue).frame(width: 5, height: 5)
                            Text("示例").font(.system(size: 10, weight: .medium)).foregroundStyle(accentBlue)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(accentBlue.opacity(0.10)))
                    } else {
                        Circle().fill(Color.secondary.opacity(0.45)).frame(width: 6, height: 6)
                    }
                    Text(model.mode == .demo ? "虚构聊天 · 实际模型逐条分析" : model.monitoring ? "正在跟随当前微信会话" : "每条对方消息下，都有上下文")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { floating.toggle(); model.setFloating(floating) } label: {
                Image(systemName: floating ? "pin.fill" : "pin").font(.system(size: 12, weight: .medium))
            }.buttonStyle(QuietIconButtonStyle(tint: floating ? accentBlue : Color.secondary)).help("窗口置顶 (⌘P)")
            Button { model.showSettings = true } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16, weight: .regular))
            }.buttonStyle(QuietIconButtonStyle()).help("设置与本地记忆")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Picker("内容来源", selection: $model.mode) {
                    ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
                Spacer(minLength: 0)
                if model.mode == .wechat {
                    Button(model.reading ? "读取中" : "刷新") { Task { await model.readNow() } }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(model.reading || model.busy)
                    Button(model.monitoring ? "暂停跟随" : "跟随") { model.requestMonitoring() }
                        .disabled(!model.hasMessages || (model.busy && !model.monitoring))
                } else if model.hasMessages {
                    Text("\(model.messages.count) 条文字").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.font(.system(size: 11)).controlSize(.small)
            if model.mode == .manual {
                DisclosureGroup("粘贴一段对话", isExpanded: $showPaste) {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("会话名称", text: $model.manualTitle).textFieldStyle(.roundedBorder)
                            .onChange(of: model.manualTitle) { _ in model.invalidate(clearCapture: true) }
                        TextEditor(text: $model.manualText).font(.system(size: 12)).frame(height: 76)
                            .scrollContentBackground(.hidden)
                            .padding(6).jevSurface(radius: 9, fill: Color(nsColor: .textBackgroundColor))
                            .onChange(of: model.manualText) { _ in model.invalidate(clearCapture: true) }
                        HStack {
                            Text("每行一条：我：… / 对方：…").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button("载入") { model.importManual(); showPaste = false }.controlSize(.small)
                        }
                    }.padding(.top, 6)
                }.font(.system(size: 11))
            }
            if model.mode == .wechat && !model.permissionReady {
                Text("首次读取：在系统设置 → 隐私与安全性 → 辅助功能中允许「Jev伴聊」。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let error = model.error { inlineNotice(error, warning: true) }
                    if model.hasMessages {
                        Text(model.mode == .demo ? "以下对话为虚构示例，分析卡使用真实模型结果" : "当前读取的对话")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 2)
                        ForEach(model.messages) { message in
                            messageRow(message).id(message.id)
                        }
                        if let a = model.analysis { replySuggestions(a) }
                        else if model.busy { thinkingHint }
                        else { Text("点下方按钮，逐条分析对方消息。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                    } else { emptyConversation }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }.padding(.horizontal, 16).padding(.vertical, 17)
            }
            .onChange(of: model.messages.first?.id) { firstID in
                selectedAnalysisMessageID = nil
                if let firstID { proxy.scrollTo(firstID, anchor: .top) }
            }
            .onChange(of: model.analysisCompleted) { _ in
                guard let target = selectedAnalysisMessageID, model.analysesByMessageID[target] != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                selectedAnalysisMessageID = nil
            }
            .onChange(of: model.analysesByMessageID.keys.sorted()) { _ in
                guard let target = selectedAnalysisMessageID, model.analysesByMessageID[target] != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                selectedAnalysisMessageID = nil
            }
        }
    }

    private func messageRow(_ message: ReaderMessage) -> some View {
        let outgoing = message.sender == "self"
        return HStack(alignment: .top, spacing: 8) {
            if outgoing { Spacer(minLength: 28) }
            else { avatar(outgoing: false, unknown: message.sender == "unknown") }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 6) {
                if message.sender == "unknown" {
                    Text("发送者未识别").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(message.text)
                    .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .foregroundStyle(outgoing ? Color.white : chatInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(outgoing ? AnyShapeStyle(bubbleOutgoingGrad) : AnyShapeStyle(bubbleIncoming),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(outgoing ? Color.clear : bubbleIncomingBorder.opacity(0.35), lineWidth: 0.5)
                    )
                    .shadow(color: outgoing ? accentBlue.opacity(0.18) : Color.black.opacity(0.03), radius: 2, y: 1)
                    .frame(maxWidth: 294, alignment: outgoing ? .trailing : .leading)
                if !outgoing { messageAnalysis(message) }
            }
            if outgoing { avatar(outgoing: true, unknown: false) }
            else { Spacer(minLength: 28) }
        }.frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    @ViewBuilder private func messageAnalysis(_ message: ReaderMessage) -> some View {
        if model.analyzingMessageID == message.id {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(accentBlue)
                Text("Jev").fontWeight(.semibold)
                ProgressView().controlSize(.mini)
                Text("正在分析这条消息…").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 11).padding(.vertical, 8)
                .jevSurface(radius: 12)
        } else if let error = model.analysisErrorsByMessageID[message.id] {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.orange)
                    Text("本条分析未完成").font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 4)
                    Button("重试") { analyzeMessage(message.id) }
                        .buttonStyle(PillButtonStyle())
                        .disabled(model.busy || model.reading)
                }
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).help(error)
            }.padding(.horizontal, 11).padding(.vertical, 8)
                .frame(maxWidth: 294, alignment: .leading)
                .jevSurface(radius: 12)
        } else if let analysis = model.analysesByMessageID[message.id] {
            jevAnnotation(analysis).frame(maxWidth: 294, alignment: .leading)
        } else {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(Color.secondary)
                Text("Jev").fontWeight(.semibold)
                Text(message.sender == "unknown" ? "发送者未识别" : model.busy && model.analysisTotal > 1 ? "等待处理" : "待分析")
                    .foregroundStyle(.secondary)
                if !model.busy {
                    Button(message.sender == "unknown" ? "单条分析" : "分析这条") { analyzeMessage(message.id) }
                        .buttonStyle(PillButtonStyle())
                        .disabled(model.reading)
                }
            }.font(.system(size: 11)).padding(.leading, 11).padding(.trailing, 6).padding(.vertical, 5)
                .jevSurface(radius: 14, fill: jevPaper.opacity(0.6))
                .help(message.sender == "unknown" ? "发送者未知的消息不会加入批量分析" : "使用截至这条消息的上下文，不包含之后的对话")
        }
    }

    private func analyzeMessage(_ id: String) {
        selectedAnalysisMessageID = id
        model.requestAnalysis(through: id)
    }

    private func avatar(outgoing: Bool, unknown: Bool) -> some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: outgoing
                    ? [Color(red: 0.45, green: 0.62, blue: 0.82), Color(red: 0.32, green: 0.47, blue: 0.70)]
                    : [Color(red: 0.72, green: 0.74, blue: 0.78), Color(red: 0.56, green: 0.58, blue: 0.63)],
                startPoint: .top, endPoint: .bottom))
            Image(systemName: unknown ? "questionmark" : "person.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.95))
        }.frame(width: 28, height: 28).accessibilityLabel(unknown ? "未知发送者" : outgoing ? "我" : "对方")
    }

    private func jevAnnotation(_ a: AnalysisView) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(accentBlue)
                Text("Jev 深度分析").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text("截至本条消息").font(.system(size: 9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("当前可能诉求", icon: "bubble.left.and.exclamationmark.bubble.right")
                ForEach(topThree(a.needs)) { need in
                    probabilityLine(need.label, probability: need.probability)
                }
            }
            if a.settled >= 0.75 {
                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("当前分歧是否可能已缓解？", icon: "arrow.triangle.merge")
                    yesNoLine(a.settled)
                }
            } else if let needsHistory = a.needsHistory {
                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("是否需要核对先前记录？", icon: "clock.arrow.circlepath")
                    yesNoLine(needsHistory)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("下一步建议", icon: "arrowshape.turn.up.right.fill")
                if !a.actions.isEmpty {
                    ForEach(topThree(a.actions)) { action in
                        probabilityLine(action.label, probability: action.probability)
                    }
                } else {
                    if let probability = a.actionProbability { probabilityLine(a.action, probability: probability) }
                    else { Text(a.action).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    sectionTitle("对话紧张程度", icon: "gauge.medium")
                    Spacer(minLength: 4)
                    tensionBadge(a.tension)
                }
                if a.tension.isFinite {
                    tensionBar(a.tension)
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jevSurface(radius: 14)
        .shadow(color: Color.black.opacity(0.04), radius: 4, y: 1)
        .textSelection(.enabled)
    }

    private func sectionTitle(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(accentBlue.opacity(0.85))
            }
            Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    private func tensionBadge(_ tension: Double) -> some View {
        let color: Color = tension < 3.0 ? Color(red: 0.15, green: 0.68, blue: 0.38) : tension < 6.5 ? Color.orange : Color(red: 0.92, green: 0.28, blue: 0.24)
        let desc: String = tension < 3.0 ? "平和" : tension < 6.5 ? "轻度分歧" : "较紧张"
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(tension.isFinite ? "\(desc) · \(String(format: "%.1f", tension))/10" : "暂无结果")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func tensionBar(_ tension: Double) -> some View {
        let color: Color = tension < 3.0 ? Color(red: 0.15, green: 0.68, blue: 0.38) : tension < 6.5 ? Color.orange : Color(red: 0.92, green: 0.28, blue: 0.24)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.opacity(0.85))
                    .frame(width: max(3, geometry.size.width * min(1, max(0, tension / 10.0))))
            }
        }.frame(height: 3)
    }

    private func topThree(_ values: [NeedView]) -> [NeedView] {
        Array(values.filter { $0.probability.isFinite }.sorted { lhs, rhs in
            if lhs.probability == rhs.probability { return lhs.id < rhs.id }
            return lhs.probability > rhs.probability
        }.prefix(3))
    }

    private func probabilityLine(_ label: String, probability: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(percent(probability)).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if probability.isFinite { probabilityBar(probability) }
        }
    }

    private func probabilityBar(_ probability: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(accentBlue.opacity(0.85))
                    .frame(width: max(3, geometry.size.width * min(1, max(0, probability))))
            }
        }.frame(height: 3)
    }

    private func yesNoLine(_ probability: Double) -> some View {
        HStack(spacing: 8) {
            choiceChip("是 \(percent(probability))", selected: probability >= 0.5)
            choiceChip("否 \(percent(1 - probability))", selected: probability < 0.5)
        }
    }

    private func choiceChip(_ text: String, selected: Bool) -> some View {
        Text(text).font(.system(size: 11, weight: selected ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(selected ? accentBlue : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(selected ? accentBlue.opacity(0.12) : Color.primary.opacity(0.05)))
    }

    private func replySuggestions(_ a: AnalysisView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.pencil").font(.system(size: 11)).foregroundStyle(accentBlue)
                Text("回复建议").font(.system(size: 13, weight: .semibold))
                Text("· 未发送").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(a.drafts.first?.kind == "model" ? "模型草稿" : "模板草稿").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(Array(a.drafts.enumerated()), id: \.element.id) { index, draft in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 4) {
                            Text("建议 \(index + 1)").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accentBlue)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(accentBlue.opacity(0.08)))
                        Spacer()
                        Button { model.copyDraft(draft) } label: {
                            Label(model.copiedID == draft.id ? "已复制" : "复制", systemImage: model.copiedID == draft.id ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(PillButtonStyle(tint: model.copiedID == draft.id ? Color.green : accentBlue))
                    }
                    Text(draft.text).font(.system(size: 13)).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .jevSurface(radius: 14)
            }
            if !a.evidence.isEmpty {
                DisclosureGroup("参考的聊天原文（\(a.evidence.count)）", isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(a.evidence) { evidence in evidenceRow(evidence) }
                    }.padding(.top, 7)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(a.warnings, id: \.self) { inlineNotice($0, warning: true) }
            Text("\(a.model) · \(a.drafts.first?.kind == "model" ? a.draftModel : "本地模板")")
                .font(.system(size: 9)).foregroundStyle(.secondary).textSelection(.enabled)
            Text("复制后由你自行修改、发送。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.top, 5)
    }

    private var thinkingHint: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text("正在逐条理解对话 · 已完成 \(model.analysisCompleted)/\(model.analysisTotal)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private var emptyConversation: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: [accentBlue.opacity(0.16), accentBlue.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 72, height: 72)
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(accentBlue)
            }
            VStack(spacing: 4) {
                Text(model.mode == .wechat ? "打开一个微信聊天" : model.mode == .manual ? "粘贴你想分析的对话" : "正在准备示例")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.mode == .wechat ? "点击下方「读取并逐条分析」，\n每条对方消息下方都会生成专属分析卡。" : "每条对方气泡下面，\n都会保留这一刻的 Jev 分析。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            HStack(spacing: 8) {
                featureBadge("只读不注入", icon: "shield.checkerboard")
                featureBadge("逐条上下文", icon: "arrow.down.forward.and.arrow.up.backward")
                featureBadge("人工确认发送", icon: "person.crop.circle.badge.checkmark")
            }.padding(.top, 4)
        }.frame(maxWidth: .infinity).padding(.vertical, 48)
    }

    private func featureBadge(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
    }

    private var composeBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if model.mode == .wechat {
                    Button { model.attachWindow() } label: {
                        Image(systemName: "rectangle.righthalf.inset.filled").font(.system(size: 15))
                    }.buttonStyle(QuietIconButtonStyle()).disabled(!model.hasMessages).help("贴靠微信")
                } else {
                    Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(accentBlue).frame(width: 28)
                }
                Button { selectedAnalysisMessageID = nil; model.requestReadAndAnalyze() } label: {
                    HStack(spacing: 6) {
                        if model.busy || model.reading { ProgressView().controlSize(.small) }
                        Text(model.reading ? "正在读取…" : model.busy ? "已完成 \(model.analysisCompleted)/\(model.analysisTotal)" : model.mode == .wechat ? "读取并逐条分析" : model.mode == .manual ? "载入并逐条分析" : "逐条分析对方消息")
                            .font(.system(size: 13, weight: .medium))
                    }.frame(maxWidth: .infinity).frame(height: 36)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.busy || model.reading)
                if model.busy {
                    Button("停止后续") { selectedAnalysisMessageID = nil; model.cancelAnalysis() }
                        .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }.padding(.horizontal, 16)
            Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17)
            Text("概率为模型估计，多个诉求可同时成立；请结合实际语境判断。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17)
        }.padding(.top, 10).padding(.bottom, 12).background(.bar)
            .overlay(alignment: .top) { Divider() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置与本地记忆").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("完成") { model.showSettings = false }.keyboardShortcut(.defaultAction)
            }.padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DisclosureGroup("模型与连接", isExpanded: $showModels) {
                        VStack(alignment: .leading, spacing: 11) {
                            Toggle("使用钥匙串中的 9Router 凭证", isOn: $model.routerUseKeychain)
                                .onChange(of: model.routerUseKeychain) { _ in model.providerChanged() }
                            Toggle("通过 9Router 生成回复", isOn: $model.useRouter)
                                .onChange(of: model.useRouter) { _ in model.providerChanged() }
                            TextField("本机 9Router Base URL", text: $model.routerURL).textFieldStyle(.roundedBorder)
                                .onChange(of: model.routerURL) { _ in model.providerChanged() }
                            HStack {
                                Text(model.modelStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer()
                                Button("刷新") { Task { await model.refreshModels() } }.controlSize(.small)
                            }
                            if !model.modelIDs.isEmpty {
                                Picker("回复模型", selection: $model.selectedModel) {
                                    ForEach(model.modelIDs, id: \.self) { Text($0).tag($0) }
                                }.onChange(of: model.selectedModel) { _ in model.providerChanged() }
                            }
                            Text("Jev 使用 TYPESAFE_API_KEY 或 Jev 专用钥匙串；9Router 使用 jev-companion-router 条目，应用不保存明文密钥。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text("分析会把所选文字发送至 Jev 和选定模型的云服务。首次使用真实会话时会确认处理范围。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }
                    if model.mode != .demo { memorySettings }
                    DisclosureGroup("读取范围与说明", isExpanded: $showReadDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.warnings, id: \.self) { Text($0) }
                            Text("辅助功能：系统设置 → 隐私与安全性 → 辅助功能 → Jev伴聊。")
                            Text("Jev 分析卡只对应真实分析过的消息，不补造历史分析；数值是模型判断，不能代表对方真实心理。")
                            Text("助手不自动发送微信消息。")
                        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 9)
                    }
                    Text("Jev 伴聊 · 0.3.1").font(.system(size: 10)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(.bottom, 5)
            }
        }.padding(20).frame(width: 370).frame(minHeight: 235, maxHeight: 610)
    }

    private var memorySettings: some View {
        DisclosureGroup("本机会话记忆", isExpanded: $showMemory) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("独立记忆名称，例如：小林／朋友", text: $model.memoryAlias).textFieldStyle(.roundedBorder)
                    .onChange(of: model.memoryAlias) { _ in model.aliasChanged() }
                Text("只检索本工具已经保存的原文。同名联系人请使用不同名称。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Toggle("分析后保存原文到本机", isOn: $model.saveHistory)
                    .onChange(of: model.saveHistory) { _ in model.memoryChanged() }
                HStack {
                    Button("仅保存原文") { Task { await model.saveCurrentLocally() } }
                        .disabled(!model.hasMessages || model.requiresAlias || model.busy)
                    Spacer()
                    Button("删除此记忆", role: .destructive) { model.showForget = true }
                        .disabled(!model.hasMessages || model.requiresAlias || model.busy)
                }.controlSize(.small)
                HStack {
                    TextField("搜索已保存的原文", text: $model.searchQuery).textFieldStyle(.roundedBorder)
                    Button("查找") { Task { await model.searchMemory() } }.disabled(model.requiresAlias)
                }
                ForEach(model.searchResults) { evidence in evidenceRow(evidence) }
            }.padding(.top, 10)
        }
    }

    private func evidenceRow(_ evidence: EvidenceView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(evidence.timestamp).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(evidence.text).font(.system(size: 11)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func inlineNotice(_ text: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(warning ? Color.orange : Color.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "暂无结果" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}
