import Foundation

@MainActor
private final class SyntheticAnalysisRunner {
    var requests: [[String: Any]] = []
    var failOnceAt: Set<String> = []
    var deferResponses = false
    private var pending: CheckedContinuation<[String: Any], Error>?
    private var timeoutTask: Task<Void, Never>?

    static func response(_ anchor: String) -> [String: Any] {
        ["model": "synthetic-jev", "analysis": ["action": ["id": "clarify", "label": "卡片-\(anchor)",
                                                          "probabilities": ["clarify": 0.8]]],
         "drafts": [], "evidence": []]
    }

    func run(_ payload: [String: Any]) async throws -> [String: Any] {
        requests.append(payload)
        let anchor = (payload["messages"] as? [[String: Any]])?.last?["id"] as? String ?? "missing"
        if deferResponses {
            precondition(pending == nil, "A second backend request must not overlap the held request")
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    self?.resolve(.failure(BridgeError.message("合成后端等待超时")))
                }
            }
        }
        if failOnceAt.remove(anchor) != nil {
            throw BridgeError.message("合成单条失败-\(anchor)")
        }
        return Self.response(anchor)
    }

    func resolve(_ result: Result<[String: Any], Error>) {
        guard let continuation = pending else { return }
        pending = nil
        timeoutTask?.cancel(); timeoutTask = nil
        continuation.resume(with: result)
    }
}

@main
struct AppModelFixtures {
    @MainActor
    static func analysisFixture(_ marker: String = "旧卡片") -> AnalysisView {
        AnalysisView(needs: [], action: marker, tension: 4, settled: 0.1,
                     uncertainty: "合成状态", drafts: [], evidence: [], model: "fixture-jev",
                     draftModel: "fixture-draft", notice: "合成状态", warnings: [], actionProbability: 0.73)
    }

    static func message(_ id: String, _ text: String, sender: String = "other", timestamp: String? = nil) -> ReaderMessage {
        ReaderMessage(id: id, sender: sender, text: text, timestamp: timestamp, isOutgoing: sender == "self")
    }

    @MainActor
    static func manualFixture(_ messages: [ReaderMessage], id: String = "manual:fixture-a") -> AppModel {
        let model = AppModel()
        model.mode = .manual
        model.sourceChanged()
        model.acceptCapture(title: "合成测试", id: id, messages: messages, warnings: [], frame: nil)
        return model
    }

    @MainActor
    static func seedAnalysis(_ model: AppModel, anchor: String) {
        let result = analysisFixture()
        model.analysis = result
        model.analysesByMessageID[anchor] = result
        model.copiedID = "fixture-copy"
        model.searchResults = [EvidenceView(id: "fixture-evidence", text: "合成原文", sender: "other", timestamp: "合成时间")]
    }

    @MainActor
    static func checkCaptureCache() {
        let first = message("m1", "之前的安排是什么？")
        let second = message("m2", "我先核对一下。", sender: "self")
        let third = message("m3", "那周末的事情呢？")

        let unchanged = manualFixture([first, second])
        seedAnalysis(unchanged, anchor: second.id)
        unchanged.acceptCapture(title: "合成测试", id: "manual:fixture-a", messages: [first, second], warnings: [], frame: nil)
        precondition(unchanged.analysesByMessageID[second.id]?.action == "旧卡片", "Identical capture must retain its card")
        precondition(unchanged.analysis != nil, "Identical capture must retain the latest result")

        unchanged.acceptCapture(title: "合成测试", id: "manual:fixture-a", messages: [first, second, third], warnings: [], frame: nil)
        precondition(unchanged.analysesByMessageID[second.id]?.action == "旧卡片", "Appending messages in one conversation must retain earlier cards")
        precondition(unchanged.analysis == nil, "New latest text must not inherit the prior latest result")
        precondition(unchanged.searchResults.isEmpty && unchanged.copiedID == nil, "New capture clears stale transient UI state")

        let changedEarlier = manualFixture([first, second, third])
        seedAnalysis(changedEarlier, anchor: second.id)
        changedEarlier.acceptCapture(title: "合成测试", id: "manual:fixture-a",
                                     messages: [message("m1", "第一条原文已改变"), second, third], warnings: [], frame: nil)
        precondition(changedEarlier.analysesByMessageID[second.id] == nil, "A retained anchor must lose its card when its earlier context changes")

        let removedEarlier = manualFixture([first, second, third])
        seedAnalysis(removedEarlier, anchor: second.id)
        removedEarlier.acceptCapture(title: "合成测试", id: "manual:fixture-a", messages: [second, third], warnings: [], frame: nil)
        precondition(removedEarlier.analysesByMessageID[second.id] == nil, "Removing earlier context invalidates a retained anchor")

        let prepended = manualFixture([first, second])
        seedAnalysis(prepended, anchor: second.id)
        prepended.acceptCapture(title: "合成测试", id: "manual:fixture-a",
                                messages: [message("older", "新加载的更早原文"), first, second], warnings: [], frame: nil)
        precondition(prepended.analysesByMessageID.isEmpty, "New preceding history invalidates the earlier analysis context")

        let changedAnchor = manualFixture([first, second])
        seedAnalysis(changedAnchor, anchor: second.id)
        changedAnchor.acceptCapture(title: "合成测试", id: "manual:fixture-a",
                                   messages: [first, message(second.id, "这一条也改变了", sender: "self")], warnings: [], frame: nil)
        precondition(changedAnchor.analysesByMessageID.isEmpty, "Same ID with changed anchor text cannot retain a card")

        let changedLater = manualFixture([first, second, third])
        seedAnalysis(changedLater, anchor: second.id)
        changedLater.acceptCapture(title: "合成测试", id: "manual:fixture-a",
                                  messages: [first, second, message(third.id, "后面的新表达")], warnings: [], frame: nil)
        precondition(changedLater.analysesByMessageID[second.id] != nil, "Changing only later messages preserves the analyzed prefix")
        changedLater.acceptCapture(title: "合成测试", id: "manual:fixture-a", messages: [first], warnings: [], frame: nil)
        precondition(changedLater.analysesByMessageID.isEmpty, "Cards whose anchors leave the visible capture must be removed")

        let changedSpeaker = manualFixture([first, second])
        seedAnalysis(changedSpeaker, anchor: second.id)
        changedSpeaker.acceptCapture(title: "合成测试", id: "manual:fixture-a",
                                     messages: [message(first.id, first.text, sender: "self"), second], warnings: [], frame: nil)
        precondition(changedSpeaker.analysesByMessageID.isEmpty, "Correcting a preceding sender changes interpretation and invalidates old cards")

        let reordered = manualFixture([first, second, third])
        seedAnalysis(reordered, anchor: third.id)
        reordered.acceptCapture(title: "合成测试", id: "manual:fixture-a", messages: [second, first, third], warnings: [], frame: nil)
        precondition(reordered.analysesByMessageID.isEmpty, "Reordering the same message IDs invalidates an anchor's context")

        let crossChat = manualFixture([first, second])
        seedAnalysis(crossChat, anchor: second.id)
        crossChat.memoryAlias = "原会话的独立记忆"
        crossChat.saveHistory = true
        crossChat.monitoring = true
        crossChat.acceptCapture(title: "另一个合成会话", id: "manual:fixture-b", messages: [first, second], warnings: [], frame: nil)
        precondition(crossChat.analysesByMessageID.isEmpty && crossChat.analysis == nil, "Different conversations must not share cards even when every message ID matches")
        precondition(!crossChat.monitoring && crossChat.memoryAlias.isEmpty && !crossChat.saveHistory, "Conversation switch resets monitoring and memory target")

        let ambiguous = manualFixture([first, second], id: "wechat:ambiguous")
        ambiguous.mode = .wechat
        seedAnalysis(ambiguous, anchor: second.id)
        ambiguous.acceptCapture(title: "同名测试", id: "wechat:ambiguous", messages: [first, second],
                                warnings: ["会话列表中发现多个同名条目，无法安全区分。"], frame: nil)
        precondition(ambiguous.analysesByMessageID.isEmpty && ambiguous.analysis == nil, "Ambiguous conversation identity must clear cached cards")
        ambiguous.requestAnalysis(through: first.id)
        precondition(!ambiguous.showConsent && ambiguous.error != nil && !ambiguous.busy, "Ambiguous target stops before any analysis task is scheduled")
    }

    @MainActor
    static func checkScopeInvalidation() {
        let item = message("m1", "合成对话")
        let model = manualFixture([item])
        seedAnalysis(model, anchor: item.id)
        model.aliasChanged()
        precondition(model.analysesByMessageID.isEmpty && model.analysis == nil, "Memory alias change clears analysis cards")
        seedAnalysis(model, anchor: item.id)
        model.saveHistory = true
        model.memoryChanged()
        precondition(model.analysesByMessageID.isEmpty && model.analysis == nil, "Persistence scope change clears analysis cards")

        // providerChanged persists its two settings. Restore this fixture process's
        // previous values so the state check has no lasting preferences side effect.
        let defaults = UserDefaults.standard
        let oldURL = defaults.object(forKey: "routerURL")
        let oldModel = defaults.object(forKey: "routerModel")
        defer {
            if let oldURL { defaults.set(oldURL, forKey: "routerURL") } else { defaults.removeObject(forKey: "routerURL") }
            if let oldModel { defaults.set(oldModel, forKey: "routerModel") } else { defaults.removeObject(forKey: "routerModel") }
        }
        seedAnalysis(model, anchor: item.id)
        model.selectedModel = "fixture/changed-model"
        model.providerChanged()
        precondition(model.analysesByMessageID.isEmpty && model.analysis == nil, "Provider configuration change clears analysis cards")

        seedAnalysis(model, anchor: item.id)
        model.mode = .wechat
        model.sourceChanged()
        precondition(model.messages.isEmpty && model.analysesByMessageID.isEmpty && model.analysis == nil, "Changing input source clears captures and cards")
    }

    @MainActor
    static func checkPrefixAndProbability() {
        let first = message("m1", "第一条")
        let second = message("m2", "第二条")
        let third = message("m3", "不能进入前两条分析的未来消息")
        let all = [first, second, third]
        precondition(AppModel.analysisPrefix(messages: all, through: first.id) == [first])
        precondition(AppModel.analysisPrefix(messages: all, through: second.id) == [first, second], "Analyze-through must include the anchor and exclude all later messages")
        precondition(AppModel.analysisPrefix(messages: all, through: nil) == all)
        precondition(AppModel.analysisPrefix(messages: all, through: "missing") == nil, "Missing anchor must fail closed, not analyze the full conversation")
        precondition(AppModel.analysisPrefix(messages: [], through: nil)?.isEmpty == true)

        let model = manualFixture(all)
        let payload: [String: Any] = ["analysis": ["action": ["id": "clarify", "label": "确认所指",
                                                               "probabilities": ["clarify": 0.73, "pause": 0.27], "confidence": 0.91]]]
        let decoded = model.decodeAnalysis(payload)
        precondition(decoded.actionProbability == 0.73, "Action percentage comes from the selected option probability, not confidence")
        let missingSelected: [String: Any] = ["analysis": ["action": ["id": "clarify", "probabilities": ["pause": 1.0]]]]
        precondition(model.decodeAnalysis(missingSelected).actionProbability == nil, "Missing selected probability stays unknown")
        precondition(model.decodeAnalysis([:]).actionProbability == nil, "Missing probability must not fabricate zero")

        model.requestAnalysis(through: "not-visible")
        precondition(!model.showConsent && !model.busy, "Unknown anchor must stop before consent or backend")
        model.requestAnalysis(through: first.id)
        precondition(model.showConsent && !model.busy, "Real source prefix request waits for consent")
        model.cancelConsent()

        model.busy = true
        model.requestReadAndAnalyze()
        model.busy = false
        model.reading = true
        model.requestReadAndAnalyze()
        precondition(!model.showConsent, "Read-and-analyze does not enqueue work while another read or analysis is active")
        model.reading = false
    }

    @MainActor
    private static func batchFixture(_ messages: [ReaderMessage], runner: SyntheticAnalysisRunner,
                                     id: String = "manual:batch-fixture") -> AppModel {
        let model = AppModel(analysisRunner: { payload in try await runner.run(payload) })
        model.mode = .manual
        model.sourceChanged()
        model.acceptCapture(title: "批量合成会话", id: id, messages: messages, warnings: [], frame: nil)
        return model
    }

    @MainActor
    private static func waitUntil(_ label: String, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { fatalError("Timed out waiting for synthetic fixture: \(label)") }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @MainActor
    private static func authorizeAndStart(_ model: AppModel, through anchor: String? = nil) {
        model.requestAnalysis(through: anchor)
        precondition(model.showConsent && !model.busy, "Synthetic manual analysis first requires its captured consent scope")
        model.grantConsent()
        precondition(!model.showConsent, "Granting captured consent should enqueue the synthetic analysis")
    }

    @MainActor
    private static func requestIDs(_ request: [String: Any]) -> [String] {
        (request["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    @MainActor
    static func checkBatchPrefixesAndIncrementalCache() async {
        let first = message("batch-m1", "第一条对方原文")
        let reply = message("batch-m2", "我的回应", sender: "self")
        let second = message("batch-m3", "第二条对方原文")
        let unknown = message("batch-m4", "未确认发送者", sender: "unknown")
        let original = [first, reply, second, unknown]
        let runner = SyntheticAnalysisRunner()
        let model = batchFixture(original, runner: runner)
        precondition(AppModel.pendingAnchors(messages: original, cachedIDs: [], through: nil) == [first.id, second.id],
                     "Batch mode targets only other messages, preserving their order")
        precondition(AppModel.pendingAnchors(messages: original, cachedIDs: [first.id], through: nil) == [second.id])
        precondition(AppModel.pendingAnchors(messages: original, cachedIDs: [], through: reply.id).isEmpty,
                     "A self bubble must not become an explicit analysis target")

        authorizeAndStart(model)
        await waitUntil("initial two-card batch") { runner.requests.count == 2 && !model.busy }
        precondition(runner.requests.map(requestIDs) == [[first.id], [first.id, reply.id, second.id]],
                     "Every card receives exactly its own preceding prefix, including self context but excluding later unknown text")
        precondition(runner.requests.allSatisfy { $0["confirmed_cloud"] as? Bool == true })
        precondition(runner.requests.allSatisfy { $0["history_policy"] as? String == "none" && $0["draft_provider"] == nil },
                     "Earlier cards cannot reintroduce later text through saved history or generate a current-turn draft")
        precondition(Set(model.analysesByMessageID.keys) == Set([first.id, second.id]))
        precondition(model.analysisErrorsByMessageID.isEmpty && model.analysisCompleted == 2 && model.analysisTotal == 2)
        precondition(model.pendingAnalysisCount == 0)

        let appended = message("batch-m5", "新增对方原文")
        model.acceptCapture(title: "批量合成会话", id: "manual:batch-fixture", messages: original + [appended], warnings: [], frame: nil)
        precondition(Set(model.analysesByMessageID.keys) == Set([first.id, second.id]), "Appending text preserves compatible cached prefixes")
        precondition(model.pendingAnalysisCount == 1)
        model.requestAnalysis()
        precondition(!model.showConsent, "Same conversation and provider retain their granted processing scope")
        await waitUntil("one appended card") { runner.requests.count == 3 && !model.busy }
        precondition(requestIDs(runner.requests[2]) == (original + [appended]).map(\.id))
        precondition(model.analysisCompleted == 1 && model.analysisTotal == 1)
        precondition(model.analysesByMessageID[appended.id]?.action == "卡片-\(appended.id)")
        precondition(model.analysesByMessageID[first.id]?.action == "卡片-\(first.id)")
        await model.analyze()
        precondition(runner.requests.count == 3, "A fully cached batch must make no additional request")
    }

    @MainActor
    static func checkBatchFailureAndSingleRetry() async {
        let items = [message("retry-m1", "第一条"), message("retry-m2", "可重试原文"), message("retry-m3", "后续原文")]
        let runner = SyntheticAnalysisRunner()
        runner.failOnceAt = [items[1].id]
        let model = batchFixture(items, runner: runner)
        authorizeAndStart(model)
        await waitUntil("batch continues after one failed row") { runner.requests.count == 3 && !model.busy }
        precondition(Set(model.analysesByMessageID.keys) == Set([items[0].id, items[2].id]),
                     "A row-specific failure must preserve completed cards and allow later rows to finish")
        precondition(model.analysisErrorsByMessageID.keys.sorted() == [items[1].id])
        precondition(model.analysisCompleted == 3 && model.analysisTotal == 3 && model.pendingAnalysisCount == 1)

        model.requestAnalysis(through: items[1].id)
        await waitUntil("explicit failed-row retry") { runner.requests.count == 4 && !model.busy }
        precondition(requestIDs(runner.requests[3]) == [items[0].id, items[1].id], "Retry remains scoped to the failed anchor's prefix")
        precondition(model.analysisErrorsByMessageID.isEmpty && model.analysesByMessageID.count == 3)
        precondition(model.analysisCompleted == 1 && model.analysisTotal == 1)
        precondition(model.analysesByMessageID[items[0].id]?.action == "卡片-\(items[0].id)")
        precondition(model.analysesByMessageID[items[2].id]?.action == "卡片-\(items[2].id)")
    }

    @MainActor
    static func checkDelayedSourceSwitch() async {
        for returnsError in [false, true] {
            let runner = SyntheticAnalysisRunner()
            runner.deferResponses = true
            let oldItems = [message("old-m1", "旧来源第一条"), message("old-m2", "旧来源第二条")]
            let model = batchFixture(oldItems, runner: runner, id: "manual:delayed-old")
            authorizeAndStart(model)
            await waitUntil("held old-source request") { runner.requests.count == 1 && model.busy }

            // Changing modes itself does no AX read. Return to a new manual capture
            // before requesting anything, keeping this fixture entirely synthetic.
            model.mode = .wechat
            model.sourceChanged()
            model.mode = .manual
            model.sourceChanged()
            let newItem = message("new-m1", "新来源原文")
            model.acceptCapture(title: "新合成会话", id: "manual:delayed-new", messages: [newItem], warnings: [], frame: nil)
            let newStatus = model.status
            precondition(model.busy && !model.canAnalyze, "Source changes cannot free busy while the previous subprocess-equivalent is still running")
            model.requestAnalysis()
            precondition(!model.showConsent && runner.requests.count == 1, "A new run cannot overlap the still-held old request")

            if returnsError { runner.resolve(.failure(BridgeError.message("旧来源迟到错误"))) }
            else { runner.resolve(.success(SyntheticAnalysisRunner.response(oldItems[0].id))) }
            await waitUntil("held old request settles after source switch") { !model.busy }
            precondition(runner.requests.count == 1, "The old batch must not dispatch its second row")
            precondition(model.analysis == nil && model.analysesByMessageID.isEmpty && model.analysisErrorsByMessageID.isEmpty,
                         "Neither stale success nor stale per-row failure may enter the new conversation")
            precondition(model.error == nil && model.status == newStatus, "Late old-source completion must not overwrite new UI status or errors")
            precondition(model.analysisCompleted == 0 && model.analysisTotal == 0)

            runner.deferResponses = false
            authorizeAndStart(model)
            await waitUntil("new source becomes usable after old request settles") { runner.requests.count == 2 && !model.busy }
            precondition(Set(model.analysesByMessageID.keys) == Set([newItem.id]))
            precondition(runner.requests[0]["conversation_id"] as? String == "manual:delayed-old")
            precondition(runner.requests[1]["conversation_id"] as? String == "manual:delayed-new")
        }
    }

    @MainActor
    static func checkStopAfterCurrentRequest() async {
        let runner = SyntheticAnalysisRunner()
        runner.deferResponses = true
        let items = [message("cancel-m1", "已发出的第一条"), message("cancel-m2", "尚未发出的第二条")]
        let model = batchFixture(items, runner: runner)
        authorizeAndStart(model)
        await waitUntil("first row before stop") { runner.requests.count == 1 && model.busy }
        model.cancelAnalysis()
        precondition(model.busy && !model.canAnalyze, "Stopping later work must wait for the already-dispatched request")
        model.requestAnalysis()
        precondition(runner.requests.count == 1 && !model.showConsent)
        runner.resolve(.success(SyntheticAnalysisRunner.response(items[0].id)))
        await waitUntil("current response accepted while remaining batch stops") { !model.busy }
        precondition(runner.requests.count == 1, "Cancel must not send the next anchor")
        precondition(Set(model.analysesByMessageID.keys) == Set([items[0].id]), "The already-dispatched current card is intentionally retained")
        precondition(model.analysisCompleted == 1 && model.analysisTotal == 2 && model.pendingAnalysisCount == 1)
        precondition(model.analysisErrorsByMessageID.isEmpty && model.status.contains("已停止后续分析"))

        runner.deferResponses = false
        model.requestAnalysis()
        await waitUntil("resume processes only the remaining anchor") { runner.requests.count == 2 && !model.busy }
        precondition(requestIDs(runner.requests[1]) == items.map(\.id))
        precondition(model.analysesByMessageID.count == 2 && model.analysisCompleted == 1 && model.analysisTotal == 1)
    }

    @MainActor
    static func main() async {
        checkCaptureCache()
        checkScopeInvalidation()
        checkPrefixAndProbability()
        let model = AppModel()
        model.mode = .manual
        model.sourceChanged()
        model.manualTitle = "合成测试 A"
        model.manualText = "对方：你还记得之前说的事情吗？\n我：让我先核对。"
        model.importManual()
        precondition(model.messages.map(\.sender) == ["other", "self"])

        model.requestAnalysis()
        precondition(model.showConsent)
        let originalDescription = model.consentDescription
        model.selectedModel = "synthetic-changed-model"
        precondition(model.consentDescription == originalDescription, "Consent copy must describe its captured scope")
        model.grantConsent()
        precondition(!model.showConsent && model.error != nil && !model.busy)

        model.requestAnalysis()
        precondition(model.showConsent)
        model.manualText = "对方：这是另一段合成内容。"
        model.importManual()
        precondition(!model.showConsent, "Changed text must invalidate pending consent")
        model.grantConsent()
        precondition(!model.busy)

        model.monitoring = true
        model.aliasChanged()
        precondition(!model.monitoring, "Memory scope changes must stop monitoring")
        model.monitoring = true
        model.memoryChanged()
        precondition(!model.monitoring, "Persistence changes must stop monitoring")

        model.memoryAlias = "原始记忆"
        model.showForget = true
        model.memoryAlias = "另一份记忆"
        model.aliasChanged()
        await model.forgetCurrent()
        precondition(model.error?.contains("已变化") == true, "Deletion must bind to the confirmed memory target")

        await checkBatchPrefixesAndIncrementalCache()
        await checkBatchFailureAndSingleRetry()
        await checkDelayedSourceSwitch()
        await checkStopAfterCurrentRequest()

        // These paths stop before invoking the backend, AX, Keychain, or a network service.
        print("AppModel synthetic state fixtures passed: prefix-scoped card retention, cross-chat/source/config invalidation, analyze-through bounds, action probability decoding, role parsing, consent scope, monitoring invalidation, deletion target binding, per-other-message batch prefixes, cache append, partial failure/retry, delayed source success/error rejection, and stop-after-current request semantics.")
    }
}
