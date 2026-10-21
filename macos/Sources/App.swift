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

private let chatInk = Color(red: 0.12, green: 0.13, blue: 0.12)
private let chatGreen = Color(red: 0.59, green: 0.92, blue: 0.42)
private let actionGreen = Color(red: 0.13, green: 0.49, blue: 0.25)
private let chatPaper = Color(red: 0.93, green: 0.93, blue: 0.93)
private let jevPaper = Color(red: 0.87, green: 0.88, blue: 0.87)

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
            conversationHeader
            sourceControls
            Divider()
            conversation
            composeBar
        }
        .background(chatPaper)
        .foregroundStyle(chatInk)
        .tint(actionGreen)
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
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 18)).foregroundStyle(actionGreen)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.hasMessages ? model.title : "Jev 伴聊")
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(model.monitoring ? actionGreen : Color.gray.opacity(0.5)).frame(width: 4, height: 4)
                    Text(model.mode == .demo ? "虚构聊天 · 实际模型逐条分析" : model.monitoring ? "正在跟随当前微信会话" : "每条对方消息下，都有上下文")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { floating.toggle(); model.setFloating(floating) } label: {
                Image(systemName: floating ? "pin.fill" : "pin").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("窗口置顶")
            Button { model.showSettings = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium)).frame(width: 25, height: 28)
            }.buttonStyle(.plain).help("设置与本地记忆")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        .background(chatPaper)
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Picker("内容来源", selection: $model.mode) {
                    ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 200)
                Spacer(minLength: 0)
                if model.mode == .wechat {
                    Button(model.reading ? "读取中" : "刷新") { Task { await model.readNow() } }
                        .disabled(model.reading || model.busy)
                    Button(model.monitoring ? "暂停跟随" : "跟随") { model.requestMonitoring() }
                        .disabled(!model.hasMessages || (model.busy && !model.monitoring))
                } else if model.hasMessages {
                    Text("\(model.messages.count) 条文字").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.font(.system(size: 11)).controlSize(.small)
            if model.mode == .manual {
                DisclosureGroup("粘贴一段对话", isExpanded: $showPaste) {
                    VStack(alignment: .leading, spacing: 7) {
                        TextField("会话名称", text: $model.manualTitle).textFieldStyle(.roundedBorder)
                            .onChange(of: model.manualTitle) { _ in model.invalidate(clearCapture: true) }
                        TextEditor(text: $model.manualText).font(.system(size: 12)).frame(height: 76)
                            .padding(5).background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
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
                LazyVStack(alignment: .leading, spacing: 19) {
                    if let error = model.error { inlineNotice(error, warning: true) }
                    if model.hasMessages {
                        Text(model.mode == .demo ? "以下对话为虚构示例，灰卡使用真实模型结果" : "当前读取的对话")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 2)
                        ForEach(model.messages) { message in
                            messageRow(message).id(message.id)
                        }
                        if let a = model.analysis { replySuggestions(a) }
                        else if model.busy { thinkingHint }
                        else { Text("点下方按钮，逐条分析对方消息。")
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
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
        return HStack(alignment: .top, spacing: 9) {
            if outgoing { Spacer(minLength: 28) }
            else { avatar(outgoing: false, unknown: message.sender == "unknown") }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 6) {
                if message.sender == "unknown" {
                    Text("发送者未识别").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(message.text)
                    .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(outgoing ? chatGreen : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: outgoing ? .topTrailing : .topLeading) {
                        BubbleTip(pointsRight: outgoing).fill(outgoing ? chatGreen : Color.white)
                            .frame(width: 6, height: 10).offset(x: outgoing ? 5 : -5, y: 12)
                    }
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
                Text("Jev:").fontWeight(.medium)
                ProgressView().controlSize(.mini)
                Text("正在分析这条消息…").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 7)
                .background(jevPaper).clipShape(RoundedRectangle(cornerRadius: 3))
        } else if let error = model.analysisErrorsByMessageID[message.id] {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Jev: 本条分析未完成").font(.system(size: 11))
                    Button("重试") { analyzeMessage(message.id) }
                        .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(actionGreen)
                        .disabled(model.busy || model.reading)
                }
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).help(error)
            }.padding(.horizontal, 9).padding(.vertical, 7)
                .frame(maxWidth: 294, alignment: .leading)
                .background(jevPaper).clipShape(RoundedRectangle(cornerRadius: 3))
        } else if let analysis = model.analysesByMessageID[message.id] {
            jevAnnotation(analysis).frame(maxWidth: 294, alignment: .leading)
        } else {
            HStack(spacing: 7) {
                Text("Jev:").fontWeight(.medium)
                Text(message.sender == "unknown" ? "发送者未识别" : model.busy && model.analysisTotal > 1 ? "等待处理" : "待分析")
                    .foregroundStyle(.secondary)
                if !model.busy {
                    Button(message.sender == "unknown" ? "单条分析" : "分析这条") { analyzeMessage(message.id) }
                        .buttonStyle(.plain).foregroundStyle(actionGreen)
                        .disabled(model.reading)
                }
            }.font(.system(size: 10)).padding(.horizontal, 9).padding(.vertical, 6)
                .background(jevPaper.opacity(0.68)).clipShape(RoundedRectangle(cornerRadius: 3))
                .help(message.sender == "unknown" ? "发送者未知的消息不会加入批量分析" : "使用截至这条消息的上下文，不包含之后的对话")
        }
    }

    private func analyzeMessage(_ id: String) {
        selectedAnalysisMessageID = id
        model.requestAnalysis(through: id)
    }

    private func avatar(outgoing: Bool, unknown: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(outgoing ? Color(red: 0.35, green: 0.43, blue: 0.40) : Color(red: 0.77, green: 0.72, blue: 0.66))
            Image(systemName: unknown ? "questionmark" : outgoing ? "person.fill" : "person.crop.square.fill")
                .font(.system(size: outgoing ? 17 : 23, weight: .regular)).foregroundStyle(Color.white.opacity(0.92))
        }.frame(width: 31, height: 31).accessibilityLabel(unknown ? "未知发送者" : outgoing ? "我" : "对方")
    }

    private func jevAnnotation(_ a: AnalysisView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Jev:").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text("截至这条消息").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("当前可能诉求").font(.system(size: 11, weight: .medium))
                ForEach(topThree(a.needs)) { need in
                    probabilityLine(need.label, probability: need.probability)
                }
            }
            if a.settled >= 0.75 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前分歧是否可能已缓解？").font(.system(size: 11, weight: .medium))
                    yesNoLine(a.settled)
                }
            } else if let needsHistory = a.needsHistory {
                VStack(alignment: .leading, spacing: 3) {
                    Text("是否需要核对先前记录？").font(.system(size: 11, weight: .medium))
                    yesNoLine(needsHistory)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("下一步建议").font(.system(size: 11, weight: .medium))
                if !a.actions.isEmpty {
                    ForEach(topThree(a.actions)) { action in
                        probabilityLine(action.label, probability: action.probability)
                    }
                } else {
                    if let probability = a.actionProbability { probabilityLine(a.action, probability: probability) }
                    else { Text("－ \(a.action)").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            HStack(spacing: 5) {
                Text("对话紧张程度：").font(.system(size: 11))
                Text(a.tension.isFinite ? String(format: "%.1f / 10", a.tension) : "暂无结果")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(jevPaper)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .textSelection(.enabled)
    }

    private func topThree(_ values: [NeedView]) -> [NeedView] {
        Array(values.filter { $0.probability.isFinite }.sorted { lhs, rhs in
            if lhs.probability == rhs.probability { return lhs.id < rhs.id }
            return lhs.probability > rhs.probability
        }.prefix(3))
    }

    private func probabilityLine(_ label: String, probability: Double) -> some View {
        Text("－ \(label)：\(percent(probability))")
            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }

    private func yesNoLine(_ probability: Double) -> some View {
        HStack(spacing: 15) {
            Text("－ 是：\(percent(probability))")
            Text("否：\(percent(1 - probability))")
        }.font(.system(size: 11, design: .monospaced))
    }

    private func replySuggestions(_ a: AnalysisView) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.pencil").font(.system(size: 11))
                Text("回复建议").font(.system(size: 12, weight: .medium))
                Text("· 未发送").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(a.drafts.first?.kind == "model" ? "模型草稿" : "模板草稿").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ForEach(Array(a.drafts.enumerated()), id: \.element.id) { index, draft in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("建议 \(index + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.copyDraft(draft) } label: {
                            Label(model.copiedID == draft.id ? "已复制" : "复制", systemImage: model.copiedID == draft.id ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                        }.buttonStyle(.plain).foregroundStyle(actionGreen)
                    }
                    Text(draft.text).font(.system(size: 13)).lineSpacing(3)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.88))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.gray.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if !a.evidence.isEmpty {
                DisclosureGroup("参考的聊天原文（\(a.evidence.count)）", isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(a.evidence) { evidence in evidenceRow(evidence) }
                    }.padding(.top, 7)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(a.warnings, id: \.self) { inlineNotice($0, warning: true) }
            Text("\(a.model) · \(a.drafts.first?.kind == "model" ? a.draftModel : "本地模板")")
                .font(.system(size: 8)).foregroundStyle(.secondary).textSelection(.enabled)
            Text("复制后由你自行修改、发送。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
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
        VStack(spacing: 10) {
            Image(systemName: "text.bubble").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(model.mode == .wechat ? "打开一个微信聊天" : model.mode == .manual ? "粘贴你想分析的对话" : "正在准备示例")
                .font(.system(size: 14, weight: .medium))
            Text(model.mode == .wechat ? "点击下方“读取并逐条分析”，\nJev 卡会出现在每条对方消息下方。" : "每条对方气泡下面，\n都会保留这一刻的 Jev 分析。")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var composeBar: some View {
        VStack(spacing: 7) {
            Divider()
            HStack(spacing: 10) {
                if model.mode == .wechat {
                    Button { model.attachWindow() } label: {
                        Image(systemName: "rectangle.righthalf.inset.filled").font(.system(size: 17)).frame(width: 28, height: 30)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!model.hasMessages).help("贴靠微信")
                } else {
                    Image(systemName: "sparkles").font(.system(size: 17)).foregroundStyle(actionGreen).frame(width: 28)
                }
                Button { selectedAnalysisMessageID = nil; model.requestReadAndAnalyze() } label: {
                    HStack(spacing: 6) {
                        if model.busy || model.reading { ProgressView().controlSize(.small) }
                        Text(model.reading ? "正在读取…" : model.busy ? "已完成 \(model.analysisCompleted)/\(model.analysisTotal)" : model.mode == .wechat ? "读取并逐条分析" : model.mode == .manual ? "载入并逐条分析" : "逐条分析对方消息")
                            .font(.system(size: 13, weight: .medium))
                    }.frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(model.busy || model.reading ? Color.gray.opacity(0.14) : chatGreen)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .disabled(model.busy || model.reading)
                if model.busy {
                    Button("停止后续") { selectedAnalysisMessageID = nil; model.cancelAnalysis() }
                        .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.horizontal, 16)
            Text(model.status).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17)
            Text("概率为模型估计，多个诉求可同时成立；请结合实际语境判断。")
                .font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17)
        }.padding(.bottom, 10).background(Color(red: 0.96, green: 0.96, blue: 0.96))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置与本地记忆").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("完成") { model.showSettings = false }
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
                            Text("灰色 Jev 卡只对应真实分析过的消息，不补造历史分析；数值是模型判断，不能代表对方真实心理。")
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
            Text(evidence.timestamp).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(evidence.text).font(.system(size: 11)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func inlineNotice(_ text: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(warning ? Color.orange : Color.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "暂无结果" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}

private struct BubbleTip: Shape {
    let pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: pointsRight ? rect.minX : rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: pointsRight ? rect.maxX : rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: pointsRight ? rect.minX : rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
