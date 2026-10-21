import AppKit
import CryptoKit
import Foundation
import SwiftUI

enum InputMode: String, CaseIterable, Identifiable {
    case wechat = "微信", manual = "粘贴", demo = "示例"
    var id: String { rawValue }
    var source: String { self == .wechat ? "wechat" : self == .manual ? "manual" : "demo" }
}

struct NeedView: Identifiable { let id: String; let label: String; let probability: Double }
struct DraftView: Identifiable { let id: String; let text: String; let kind: String }
struct EvidenceView: Identifiable { let id: String; let text: String; let sender: String; let timestamp: String }
struct AnalysisView {
    var needs: [NeedView]; var action: String; var tension: Double
    var settled: Double; var uncertainty: String; var drafts: [DraftView]; var evidence: [EvidenceView]
    var model: String; var draftModel: String; var notice: String; var warnings: [String]
    var actionProbability: Double? = nil
    var actions: [NeedView] = []
    var needsHistory: Double? = nil
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

enum BackendClient {
    static func run(_ command: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await Task.detached(priority: .userInitiated) {
            guard let resource = Bundle.main.resourceURL else { throw BridgeError.message("找不到应用资源。") }
            let executable = resource.appendingPathComponent("Backend/engine.py")
            guard FileManager.default.fileExists(atPath: executable.path) else { throw BridgeError.message("分析模块缺失，请重新构建应用。") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [executable.path, command]
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONIOENCODING"] = "utf-8"
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 125, execute: timeout)
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
            let resultData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            guard let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                throw BridgeError.message("分析进程未返回有效结果，可能已超时。请手动重试。")
            }
            guard result["ok"] as? Bool == true else {
                let error = result["error"] as? [String: Any]
                throw BridgeError.message(error?["message"] as? String ?? "分析未完成，请重试。")
            }
            return result
        }.value
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: InputMode = .demo
    @Published var title = "准备好，认真听一句话。"
    @Published var messages: [ReaderMessage] = []
    @Published var warnings: [String] = []
    @Published var status = "加载虚构示例中…"
    @Published var error: String?
    @Published var busy = false
    @Published var reading = false
    @Published var monitoring = false
    @Published var saveHistory = false
    @Published var memoryAlias = ""
    @Published var manualText = ""
    @Published var manualTitle = "我的粘贴会话"
    @Published var analysis: AnalysisView?
    @Published var analysesByMessageID: [String: AnalysisView] = [:]
    @Published var analyzingMessageID: String?
    @Published var analysisErrorsByMessageID: [String: String] = [:]
    @Published var analysisCompleted = 0
    @Published var analysisTotal = 0
    @Published var searchQuery = ""
    @Published var searchResults: [EvidenceView] = []
    @Published var routerURL = UserDefaults.standard.string(forKey: "routerURL") ?? "http://127.0.0.1:20128/v1"
    @Published var selectedModel = UserDefaults.standard.string(forKey: "routerModel") ?? ""
    @Published var modelIDs: [String] = []
    @Published var useRouter = true
    @Published var routerUseKeychain = UserDefaults.standard.bool(forKey: "routerUseKeychain")
    @Published var showConsent = false
    @Published var showForget = false {
        didSet { if showForget { forgetTarget = effectiveID } }
    }
    @Published var showSettings = false
    @Published var modelStatus = "尚未读取模型列表"
    @Published var copiedID: String?
    @Published var permissionReady = false
    let routerCredentialService = "jev-companion-router"
    let routerCredentialAccount = NSUserName()

    private let reader = WeChatReader()
    private var conversationID = ""
    private var captureFingerprint = ""
    private var attemptedFingerprint = ""
    private var generation = UUID()
    private var consentScope: String?
    private var consentAction: (() -> Void)?
    private var pendingConsentScope: String?
    private var pendingConsentGeneration: UUID?
    private var pendingConsentDescription: String?
    private var forgetTarget: String?
    private var timer: Timer?
    private var demoRequest: [String: Any] = [:]
    private var windowFrame: CGRect?
    private var latestReadingTitle: String?
    private var lastAutomaticCall = Date.distantPast
    private var modelRefreshID = UUID()
    private var started = false
    private var analysisRunID = UUID()
    private var stopAfterCurrentAnalysis = false
    private let analysisRunner: ([String: Any]) async throws -> [String: Any]

    init(analysisRunner: @escaping ([String: Any]) async throws -> [String: Any] = {
        try await BackendClient.run("analyze", payload: $0)
    }) { self.analysisRunner = analysisRunner }

    var pendingAnalysisCount: Int {
        messages.filter { $0.sender == "other" && analysesByMessageID[$0.id] == nil }.count
    }

    func cancelAnalysis() {
        guard busy else { return }
        stopAfterCurrentAnalysis = true
        timer?.invalidate(); timer = nil; monitoring = false
        status = "正在停止后续分析 · 保留已完成的卡片"
    }

    var hasMessages: Bool { !messages.isEmpty }
    private var ambiguousConversation: Bool { mode == .wechat && warnings.contains { $0.hasPrefix("会话列表中发现多个同名条目") } }
    var requiresAlias: Bool { mode != .demo && memoryAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canAnalyze: Bool { hasMessages && !busy && !reading }
    var consentDescription: String {
        if let pending = pendingConsentDescription { return pending }
        return currentConsentDescription
    }
    private var currentConsentDescription: String {
        let upstream = useRouter ? "以及本机 9Router（\(selectedModel)）所连接的模型服务" : ""
        return "将「\(title)」已读取的 \(messages.count) 条文字按对方消息逐条分析，每张卡仅发送截至该条的上下文至 TypeSafe / Jev\(upstream)。最新一条的回复建议可参考此会话匹配的历史。授权只在本次运行、当前会话与当前模型配置下有效。\n\n消息不会由助手发送到微信。"
    }

    func start() {
        guard !started else { return }; started = true
        permissionReady = reader.accessibilityTrusted
        Task { await loadDemo(); await refreshModels() }
    }

    func invalidate(clearCapture: Bool = false) {
        stopMonitoring()
        generation = UUID(); analysis = nil; analysesByMessageID = [:]; searchResults = []; error = nil
        stopAfterCurrentAnalysis = true
        analyzingMessageID = nil; analysisErrorsByMessageID = [:]; analysisCompleted = 0; analysisTotal = 0
        attemptedFingerprint = ""; consentScope = nil; showConsent = false; consentAction = nil
        pendingConsentScope = nil; pendingConsentGeneration = nil; pendingConsentDescription = nil; copiedID = nil
        if clearCapture { messages = []; conversationID = ""; captureFingerprint = ""; warnings = []; windowFrame = nil }
    }

    func sourceChanged() {
        stopMonitoring(); invalidate(clearCapture: true)
        memoryAlias = ""; saveHistory = false
        if mode == .demo { Task { await loadDemo() } }
        else { title = mode == .wechat ? "打开一个微信聊天" : manualTitle; status = "内容只在点击读取后进入助手。" }
    }

    func providerChanged() {
        stopMonitoring()
        modelRefreshID = UUID()
        UserDefaults.standard.set(routerURL, forKey: "routerURL")
        UserDefaults.standard.set(selectedModel, forKey: "routerModel")
        UserDefaults.standard.set(routerUseKeychain, forKey: "routerUseKeychain")
        invalidate()
    }

    func aliasChanged() {
        invalidate()
    }

    func memoryChanged() { invalidate() }

    func loadDemo() async {
        let token = generation
        do {
            let result = try await BackendClient.run("demo")
            guard token == generation, mode == .demo, let request = result["request"] as? [String: Any] else { return }
            demoRequest = request
            let loaded = decodeMessages(request["messages"])
            acceptCapture(title: request["conversation_title"] as? String ?? "虚构示例", id: request["conversation_id"] as? String ?? "demo:dinner-v1", messages: loaded, warnings: ["这是一段虚构对话。分析时会真实调用 Jev 与选定的回复模型。"], frame: nil)
            status = "示例已就绪 · 点击分析体验真实结果"
        } catch { if token == generation, mode == .demo { self.error = error.localizedDescription } }
    }

    @discardableResult
    func readNow(automatic: Bool = false) async -> Bool {
        guard !reading else { return false }
        permissionReady = reader.accessibilityTrusted
        guard mode == .wechat else {
            if mode == .manual { importManual(); return hasMessages && error == nil }
            return false
        }
        let token = generation
        reading = true
        await Task.yield()
        defer { reading = false }
        guard token == generation, mode == .wechat, !automatic || monitoring else { return false }
        do {
            let snapshot = try reader.readCurrentConversation()
            let changedChat = !conversationID.isEmpty && conversationID != snapshot.conversationID
            if changedChat { stopMonitoring(); memoryAlias = ""; saveHistory = false }
            acceptCapture(title: snapshot.title, id: snapshot.conversationID, messages: Array(snapshot.messages.suffix(60)), warnings: snapshot.warnings, frame: snapshot.windowFrame)
            latestReadingTitle = snapshot.title
            if !automatic { status = "已读取 \(messages.count) 条文字 · 尚未发送到模型" }
            if automatic, monitoring, consentScope == scope, captureFingerprint != attemptedFingerprint, !busy,
               Date().timeIntervalSince(lastAutomaticCall) >= 15 {
                lastAutomaticCall = Date()
                enqueueAnalysis()
            }
            return true
        } catch {
            invalidate(clearCapture: true)
            stopMonitoring()
            self.error = error.localizedDescription
            status = "读取已暂停"
            return false
        }
    }

    func acceptCapture(title newTitle: String, id: String, messages newMessages: [ReaderMessage], warnings newWarnings: [String], frame: CGRect?) {
        let changedConversation = !conversationID.isEmpty && id != conversationID
        let normalized = newMessages.map { message in
            ReaderMessage(id: message.id, sender: ["self", "other", "unknown"].contains(message.sender) ? message.sender : message.isOutgoing ? "self" : "other", text: message.text, timestamp: message.timestamp, isOutgoing: message.isOutgoing)
        }
        let hash = fingerprint(id: id, messages: normalized)
        if hash != captureFingerprint {
            generation = UUID(); analysis = nil; searchResults = []; copiedID = nil
            if busy { stopAfterCurrentAnalysis = true }
            analysisErrorsByMessageID = [:]
            cancelConsent()
            if changedConversation {
                analysesByMessageID = [:]
                stopMonitoring(); consentScope = nil; memoryAlias = ""; saveHistory = false
                attemptedFingerprint = ""
            }
        }
        let oldMessages = messages
        analysesByMessageID = analysesByMessageID.filter { anchor, _ in
            guard let oldPrefix = Self.analysisPrefix(messages: oldMessages, through: anchor),
                  let newPrefix = Self.analysisPrefix(messages: normalized, through: anchor) else { return false }
            return oldPrefix == newPrefix
        }
        title = newTitle; conversationID = id; messages = normalized
        captureFingerprint = hash; warnings = newWarnings; windowFrame = frame; error = nil
        if ambiguousConversation {
            stopMonitoring(); generation = UUID(); analysis = nil; analysesByMessageID = [:]; consentScope = nil; cancelConsent()
        }
    }

    func importManual() {
        guard mode == .manual else { return }
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "请先粘贴对话，每行一条，例如「我：……」「对方：……」。"; return }
        let lines = Array(text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(60))
        var counts: [String: Int] = [:]
        let parsed = lines.map { line -> ReaderMessage in
            var sender = "unknown", body = line
            for prefix in ["我：", "我:", "我说:", "我说："] where line.hasPrefix(prefix) { sender = "self"; body = String(line.dropFirst(prefix.count)); break }
            if sender == "unknown" {
                for prefix in ["对方：", "对方:", "对方说：", "对方说:"] where line.hasPrefix(prefix) { sender = "other"; body = String(line.dropFirst(prefix.count)); break }
            }
            let key = sender + body; counts[key, default: 0] += 1
            return ReaderMessage(id: digest(key + String(counts[key]!)), sender: sender, text: String(body.prefix(4000)), timestamp: nil, isOutgoing: sender == "self")
        }
        let label = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        acceptCapture(title: label.isEmpty ? "粘贴会话" : label, id: "manual:" + digest(label), messages: parsed, warnings: ["仅使用你粘贴的文字；未标记发送者的行按未知处理。"], frame: nil)
        status = "已载入 \(messages.count) 条文字"
    }

    private var effectiveID: String {
        guard mode != .demo else { return conversationID }
        let alias = memoryAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        return alias.isEmpty ? conversationID : mode.source + ":" + digest(conversationID + "|" + alias)
    }
    private var scope: String { digest([mode.source, effectiveID, routerURL, selectedModel, routerCredentialService, routerCredentialAccount, String(useRouter), String(routerUseKeychain), String(saveHistory)].map { "\($0.utf8.count):\($0)" }.joined()) }

    private func enqueueAnalysis(through messageID: String? = nil) {
        let token = generation, requestedScope = scope
        Task { [weak self] in
            guard let self, token == self.generation, requestedScope == self.scope else { return }
            await self.analyze(through: messageID)
        }
    }

    private func prepareConsent(action: @escaping () -> Void) {
        pendingConsentScope = scope; pendingConsentGeneration = generation
        pendingConsentDescription = currentConsentDescription
        consentAction = action; showConsent = true
    }

    func requestReadAndAnalyze() {
        guard !busy, !reading else { return }
        let requestedMode = mode, requestedGeneration = generation
        Task { [weak self] in
            guard let self, self.generation == requestedGeneration, self.mode == requestedMode else { return }
            if self.mode != .demo {
                guard await self.readNow() else { return }
            }
            guard self.mode == requestedMode, self.hasMessages, self.error == nil else { return }
            self.requestAnalysis()
        }
    }

    func requestAnalysis(through messageID: String? = nil) {
        guard canAnalyze else { return }
        if let messageID, !messages.contains(where: { $0.id == messageID }) { return }
        let target = messageID
        guard !ambiguousConversation else { error = "发现同名会话，无法可靠区分。请把目标对话粘贴到独立命名的粘贴会话后分析。"; return }
        if mode == .demo || consentScope == scope { enqueueAnalysis(through: target); return }
        prepareConsent { [weak self] in self?.enqueueAnalysis(through: target) }
    }
    func grantConsent() {
        guard pendingConsentScope == scope, pendingConsentGeneration == generation, hasMessages, !reading else {
            cancelConsent(); error = "对话或设置已变化，请重新确认分析范围。"; return
        }
        consentScope = scope; let action = consentAction; cancelConsent(); action?()
    }
    func cancelConsent() {
        consentAction = nil; showConsent = false
        pendingConsentScope = nil; pendingConsentGeneration = nil; pendingConsentDescription = nil
    }

    func requestMonitoring() {
        if monitoring { stopMonitoring(); return }
        guard mode == .wechat, hasMessages, !busy else { return }
        guard !ambiguousConversation else { error = "发现同名会话，已暂停跟随。请使用独立命名的粘贴会话。"; return }
        if consentScope == scope { startMonitoring() }
        else { prepareConsent { [weak self] in self?.startMonitoring() } }
    }
    private func startMonitoring() {
        guard mode == .wechat, hasMessages, consentScope == scope, !ambiguousConversation else { return }
        monitoring = true; status = "跟随当前会话 · 每 3 秒检查，变化后分析"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, self.monitoring else { return }; await self.readNow(automatic: true) }
        }
        if attemptedFingerprint != captureFingerprint { enqueueAnalysis() }
    }
    func stopMonitoring() {
        if monitoring { generation = UUID() }
        timer?.invalidate(); timer = nil; monitoring = false
    }

    private func payload(inputMessages: [ReaderMessage]? = nil, includeDrafts: Bool = true) -> [String: Any] {
        var request: [String: Any]
        if mode == .demo {
            request = demoRequest
            if let inputMessages { request["messages"] = inputMessages.map { ["id": $0.id, "sender": $0.sender, "text": $0.text] } }
        }
        else {
            request = ["conversation_id": effectiveID, "conversation_title": title, "source": mode.source,
                       "messages": (inputMessages ?? messages).map { m -> [String: Any] in
                           var value: [String: Any] = ["id": m.id, "sender": m.sender, "text": m.text]
                           if let stamp = m.timestamp { value["timestamp"] = stamp }; return value
                       }, "save_history": saveHistory && !requiresAlias, "confirmed_cloud": consentScope == scope]
        }
        if !includeDrafts { request["history_policy"] = "none" }
        if useRouter && includeDrafts { request["draft_provider"] = routerConfiguration(includeModel: true) }
        return request
    }

    static func pendingAnchors(messages: [ReaderMessage], cachedIDs: Set<String>, through messageID: String?) -> [String] {
        if let messageID {
            return messages.contains(where: { $0.id == messageID && $0.sender != "self" }) ? [messageID] : []
        }
        return messages.filter { $0.sender == "other" && !cachedIDs.contains($0.id) }.map(\.id)
    }

    func analyze(through messageID: String? = nil) async {
        guard hasMessages, !busy else { return }
        if mode == .wechat {
            do {
                let current = try reader.readCurrentConversation()
                acceptCapture(title: current.title, id: current.conversationID,
                              messages: Array(current.messages.suffix(60)), warnings: current.warnings,
                              frame: current.windowFrame)
            } catch {
                invalidate(clearCapture: true); self.error = error.localizedDescription
                status = "读取已暂停"; return
            }
        }
        guard !ambiguousConversation else { error = "发现同名会话，未发送到模型。请使用独立命名的粘贴会话。"; return }
        guard mode == .demo || consentScope == scope else { error = "请先确认此会话的模型处理范围。"; return }
        if saveHistory && requiresAlias { error = "请为本机会话记忆填写独立名称，避免同名联系人混用。"; return }
        let anchors = Self.pendingAnchors(messages: messages, cachedIDs: Set(analysesByMessageID.keys), through: messageID)
        guard !anchors.isEmpty else {
            status = messageID == nil ? "当前对方消息均已有分析 · 新消息到来后可继续" : "这条消息不能分析，请重新选择。"
            return
        }
        busy = true; error = nil; stopAfterCurrentAnalysis = false
        analysisCompleted = 0; analysisTotal = anchors.count
        let runID = UUID(); analysisRunID = runID
        let token = generation, requestedID = conversationID, requestedScope = scope
        let capturedMessages = messages
        attemptedFingerprint = captureFingerprint
        lastAutomaticCall = Date()
        var completedCards = 0, failedCards = 0
        defer {
            if analysisRunID == runID { busy = false; analyzingMessageID = nil }
        }
        for anchorID in anchors {
            guard !stopAfterCurrentAnalysis, token == generation, requestedID == conversationID,
                  requestedScope == scope, analysisRunID == runID else { break }
            guard let prefix = Self.analysisPrefix(messages: capturedMessages, through: anchorID) else { continue }
            analyzingMessageID = anchorID
            analysisErrorsByMessageID.removeValue(forKey: anchorID)
            status = "Jev 正在逐条分析 · \(analysisCompleted + 1) / \(analysisTotal)"
            let isCurrentTurn = anchorID == capturedMessages.last?.id
            let request = payload(inputMessages: prefix, includeDrafts: isCurrentTurn)
            do {
                let result = try await analysisRunner(request)
                guard token == generation, requestedID == conversationID, requestedScope == scope, analysisRunID == runID else { return }
                if mode == .wechat {
                    let current = try reader.readCurrentConversation()
                    let currentMessages = Array(current.messages.suffix(60))
                    guard fingerprint(id: current.conversationID, messages: currentMessages) == captureFingerprint else {
                        acceptCapture(title: current.title, id: current.conversationID, messages: currentMessages,
                                      warnings: current.warnings, frame: current.windowFrame)
                        status = "对话已更新 · 保留仍匹配的卡片，可继续分析新消息"; return
                    }
                }
                let decoded = decodeAnalysis(result)
                analysesByMessageID[anchorID] = decoded
                if isCurrentTurn { analysis = decoded }
                completedCards += 1
            } catch {
                guard token == generation, requestedID == conversationID, requestedScope == scope, analysisRunID == runID else { return }
                analysisErrorsByMessageID[anchorID] = error.localizedDescription
                failedCards += 1
                // A shared provider failure should not fan out into another request for every row.
                if ["凭证", "调用器", "限流", "繁忙", "配置"].contains(where: { error.localizedDescription.contains($0) }) {
                    stopAfterCurrentAnalysis = true
                }
            }
            analysisCompleted += 1
        }
        guard token == generation, analysisRunID == runID else { return }
        if stopAfterCurrentAnalysis { status = "已停止后续分析 · 本轮保留 \(completedCards) 张卡片" }
        else if failedCards > 0 { status = "已生成 \(completedCards) 张卡片 · \(failedCards) 条未完成，可在消息下重试" }
        else { status = "分析完成 · 本轮 \(completedCards) 张 Jev 卡片" }
    }

    func routerConfiguration(includeModel: Bool) -> [String: Any] {
        var config: [String: Any] = ["base_url": routerURL]
        if includeModel { config["model"] = selectedModel }
        if routerUseKeychain {
            config["keychain_service"] = routerCredentialService
            config["keychain_account"] = routerCredentialAccount
        }
        return config
    }

    func refreshModels() async {
        let requestedURL = routerURL, refreshID = UUID()
        modelRefreshID = refreshID
        modelStatus = "正在读取 9Router 模型…"
        do {
            let result = try await BackendClient.run("models", payload: ["draft_provider": routerConfiguration(includeModel: false)])
            guard requestedURL == routerURL, modelRefreshID == refreshID else { return }
            modelIDs = (result["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
            modelStatus = "已发现 \(modelIDs.count) 个模型"
            if !modelIDs.contains(selectedModel), let first = modelIDs.first { selectedModel = first; providerChanged() }
        } catch { if requestedURL == routerURL, modelRefreshID == refreshID { modelStatus = error.localizedDescription } }
    }

    func searchMemory() async {
        guard !effectiveID.isEmpty, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let token = generation
        do {
            let result = try await BackendClient.run("search", payload: ["conversation_id": effectiveID, "query": searchQuery])
            guard token == generation else { return }
            searchResults = decodeEvidence(result["evidence"])
            if searchResults.isEmpty { status = "本工具尚未保存匹配原文；微信更早历史不会自动出现。" }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }

    func saveCurrentLocally() async {
        guard hasMessages, mode != .demo else { return }
        guard !requiresAlias else { error = "请先填写独立的记忆名称。"; return }
        let token = generation
        var request = payload(); request["save_history"] = true
        do {
            let result = try await BackendClient.run("import", payload: request)
            guard token == generation else { return }
            status = "已在本机保存 \(result["saved_messages"] as? Int ?? 0) 条新原文。"
        } catch { if token == generation { self.error = error.localizedDescription } }
    }

    func forgetCurrent() async {
        guard let id = forgetTarget, id == effectiveID, !id.isEmpty else {
            forgetTarget = nil; error = "当前记忆名称已变化，请重新确认要删除的记忆。"; return
        }
        forgetTarget = nil
        stopMonitoring(); invalidate()
        let token = generation
        do {
            let result = try await BackendClient.run("forget", payload: ["conversation_id": id, "confirmed": true])
            guard token == generation else { return }
            status = "已删除本工具保存的 \(result["deleted_messages"] as? Int ?? 0) 条原文。"
        } catch { if token == generation { self.error = error.localizedDescription } }
    }

    func copyDraft(_ draft: DraftView) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.text, forType: .string)
        copiedID = draft.id
    }

    func attachWindow() {
        guard let frame = windowFrame, let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "设置" }), let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = min(max(visible.minX, frame.maxX + 10), visible.maxX - window.frame.width)
        let top = (NSScreen.screens.first?.frame.maxY ?? visible.maxY) - frame.minY
        let y = min(max(visible.minY, top - window.frame.height), visible.maxY - window.frame.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func setFloating(_ value: Bool) { for window in NSApp.windows where window.isVisible { window.level = value ? .floating : .normal } }

    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func fingerprint(id: String, messages: [ReaderMessage]) -> String {
        let parts = [id] + messages.flatMap { message in
            [message.id, ["self", "other", "unknown"].contains(message.sender) ? message.sender : message.isOutgoing ? "self" : "other", message.text, message.timestamp ?? ""]
        }
        return digest(parts.map { "\($0.utf8.count):\($0)" }.joined())
    }
    private func decodeMessages(_ value: Any?) -> [ReaderMessage] {
        (value as? [[String: Any]] ?? []).enumerated().compactMap { i, row in
            guard let text = row["text"] as? String else { return nil }
            let sender = row["sender"] as? String ?? "unknown"
            return ReaderMessage(id: row["id"] as? String ?? "m\(i)", sender: sender, text: text, timestamp: row["timestamp"] as? String, isOutgoing: sender == "self")
        }
    }
    private func decodeEvidence(_ value: Any?) -> [EvidenceView] {
        (value as? [[String: Any]] ?? []).enumerated().map { i, row in EvidenceView(id: row["id"] as? String ?? "e\(i)", text: row["text"] as? String ?? "", sender: row["sender"] as? String ?? "unknown", timestamp: row["timestamp"] as? String ?? "已保存原文") }
    }
    static func analysisPrefix(messages: [ReaderMessage], through messageID: String?) -> [ReaderMessage]? {
        guard let messageID else { return messages }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        return Array(messages.prefix(through: index))
    }

    func decodeAnalysis(_ result: [String: Any]) -> AnalysisView {
        let a = result["analysis"] as? [String: Any] ?? [:]
        let needs = (a["needs"] as? [[String: Any]] ?? []).map { NeedView(id: $0["id"] as? String ?? UUID().uuidString, label: $0["label"] as? String ?? "", probability: $0["probability"] as? Double ?? 0) }
        let drafts = (result["drafts"] as? [[String: Any]] ?? []).map { DraftView(id: $0["id"] as? String ?? UUID().uuidString, text: $0["text"] as? String ?? "", kind: $0["kind"] as? String ?? "template") }
        let provider = result["draft_provider"] as? [String: Any] ?? [:]
        let action = a["action"] as? [String: Any] ?? [:]
        let probabilities = action["probabilities"] as? [String: Double] ?? [:]
        let actionProbability = (action["id"] as? String).flatMap { probabilities[$0] }
        let actions = (action["options"] as? [[String: Any]] ?? []).compactMap { row -> NeedView? in
            guard let id = row["id"] as? String, let label = row["label"] as? String,
                  let p = row["probability"] as? Double, p.isFinite, (0...1).contains(p) else { return nil }
            return NeedView(id: id, label: label, probability: p)
        }.sorted { $0.probability > $1.probability }
        let needsHistory = (a["needs_history_probability"] as? Double).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }

        return AnalysisView(needs: needs, action: action["label"] as? String ?? "先确认上下文", tension: a["tension"] as? Double ?? 0, settled: a["settled_probability"] as? Double ?? 0, uncertainty: a["uncertainty"] as? String ?? "", drafts: drafts, evidence: decodeEvidence(result["evidence"]), model: result["model"] as? String ?? "Jev", draftModel: provider["model"] as? String ?? "本地模板", notice: result["draft_notice"] as? String ?? "", warnings: (result["warnings"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }, actionProbability: actionProbability, actions: actions, needsHistory: needsHistory)
    }
}
