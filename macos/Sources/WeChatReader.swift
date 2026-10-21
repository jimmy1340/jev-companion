import AppKit
import ApplicationServices
import CryptoKit
import Foundation

struct ReaderMessage: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let sender: String
    let text: String
    let timestamp: String?
    let isOutgoing: Bool
}

struct WeChatSnapshot: Codable, Sendable {
    let title: String
    let conversationID: String
    let messages: [ReaderMessage]
    let capturedAt: Date
    let warnings: [String]
    /// Accessibility coordinates: origin at the upper left of the main display.
    let windowFrame: CGRect?
}

enum ReaderError: LocalizedError {
    case permissionDenied, appNotRunning, noWindow, noConversation, noMessages
    case conversationChanged, readFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "尚未获得辅助功能权限。请在系统设置中为这个助手开启权限，再点读取；助手不会自动修改权限。"
        case .appNotRunning: return "没有找到正在运行的微信。请打开并登录微信。"
        case .noWindow: return "没有找到微信聊天窗口。请保持微信已登录且聊天窗口未最小化。"
        case .noConversation: return "未能可靠识别当前会话。请在微信打开一个聊天后重试。"
        case .noMessages: return "当前会话没有可读取的文字消息。图片、语音和未加载的历史不会被转换成文字。"
        case .conversationChanged: return "读取期间会话发生变化，已丢弃这次结果。请停留在目标聊天后重试。"
        case .readFailed: return "微信暂未响应辅助功能读取。请确认聊天窗口可用后重试。"
        }
    }
}

private struct ReaderDiagnosticFailure: LocalizedError {
    let cause: ReaderError
    let diagnostic: String
    var errorDescription: String? {
        "\(cause.errorDescription ?? "微信读取失败。")\n读取诊断（不含聊天内容）：\(diagnostic)"
    }
}

/// No AX mutation, keyboard event, activation, scrolling, or permission prompt is used here.
@MainActor
final class WeChatReader {
    static let bundleIdentifiers = ["com.tencent.xinWeChat"]
    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    private(set) var lastReadDiagnostics = ""

    func readCurrentConversation() throws -> WeChatSnapshot {
        lastReadDiagnostics = ""
        guard accessibilityTrusted else { throw ReaderError.permissionDenied }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            Self.bundleIdentifiers.contains($0.bundleIdentifier ?? "") && !$0.isTerminated
        }) else { throw ReaderError.appNotRunning }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let windows = AXRead.elements(application, kAXWindowsAttribute) else {
            throw ReaderError.readFailed
        }
        let candidates = windows.filter { window in
            !AXRead.bool(window, kAXMinimizedAttribute)
                && AXRead.string(window, kAXRoleAttribute) == kAXWindowRole
        }
        // Prefer the known chat window, then the main window. Never raise it.
        guard let window = candidates.first(where: {
            let title = AXRead.string($0, kAXTitleAttribute)
            return title.contains("聊天") || title.lowercased().contains("chats")
        }) ?? candidates.first(where: { AXRead.bool($0, kAXMainAttribute) }) else {
            let windowDetails = windows.prefix(8).enumerated().map {
                AXRead.windowDiagnostics($0.element, index: $0.offset)
            }.joined(separator: " | ")
            lastReadDiagnostics = "stage=window_selection appPID=\(app.processIdentifier) windows=\(windows.count) candidates=\(candidates.count) \(windowDetails)"
            throw ReaderDiagnosticFailure(cause: .noWindow, diagnostic: lastReadDiagnostics)
        }

        let capture = AXTreeCapture()
        guard let root = capture.read(window) else {
            lastReadDiagnostics = capture.diagnostics(root: nil, stage: "capture_root")
            throw ReaderDiagnosticFailure(cause: .readFailed, diagnostic: lastReadDiagnostics)
        }
        let parsed: WeChatParser.Result
        do {
            parsed = try WeChatParser.parse(root: root, bundleID: app.bundleIdentifier ?? Self.bundleIdentifiers[0])
        } catch let error as ReaderError {
            let stage: String
            switch error {
            case .noMessages:
                stage = root.first(where: WeChatParser.isMessageList) == nil ? "message_table_missing" : "message_parse_empty"
            case .noConversation: stage = "conversation_title_missing"
            default: stage = "parse_failed"
            }
            lastReadDiagnostics = capture.diagnostics(root: root, stage: stage)
            throw ReaderDiagnosticFailure(cause: error, diagnostic: lastReadDiagnostics)
        }
        // Re-read the title anchor so a switch during traversal cannot silently mix chats.
        guard let anchor = capture.elementsByToken[parsed.titleToken] else {
            throw ReaderError.readFailed
        }
        let currentAnchor = AXRead.shallowNode(anchor, token: parsed.titleToken)
        guard WeChatParser.titleText(currentAnchor) == parsed.title else {
            throw ReaderError.conversationChanged
        }
        var warnings = parsed.warnings
        if capture.truncated { warnings.append("界面树达到读取上限，只包含本次成功读取的部分消息。") }
        if capture.failedReads { warnings.append("部分界面元素暂时不可读，消息可能不完整。") }
        if capture.omittedMessageRows > 0 { warnings.append("本次只读取消息表末尾 120 个已加载行，更早的已加载行未扫描。") }
        return WeChatSnapshot(
            title: parsed.title,
            conversationID: parsed.conversationID,
            messages: parsed.messages,
            capturedAt: Date(),
            warnings: warnings,
            windowFrame: AXRead.frame(window)
        )
    }
}

// A plain value tree keeps parsing testable without a running application or AX permission.
struct WeChatAXNode {
    var token: Int = 0
    var role: String = ""
    var identifier: String = ""
    var title: String = ""
    var value: String = ""
    var label: String = ""
    var selected: Bool = false
    var children: [WeChatAXNode] = []

    var strings: [String] { [label, title, value].filter { !$0.isEmpty } }
    func first(where predicate: (WeChatAXNode) -> Bool) -> WeChatAXNode? {
        if predicate(self) { return self }
        for child in children { if let result = child.first(where: predicate) { return result } }
        return nil
    }
    func all(where predicate: (WeChatAXNode) -> Bool) -> [WeChatAXNode] {
        (predicate(self) ? [self] : []) + children.flatMap { $0.all(where: predicate) }
    }
}

enum WeChatParser {
    struct Result {
        let title: String
        let titleToken: Int
        let conversationID: String
        let messages: [ReaderMessage]
        let warnings: [String]
    }

    static func parse(root: WeChatAXNode, bundleID: String) throws -> Result {
        guard let messageList = root.first(where: isMessageList) else { throw ReaderError.noMessages }

        // Input values are drafts, not titles: titleText deliberately never reads them.
        let controls = outsideMessages(root)
        let input = controls.first(where: {
            ($0.role == "AXTextArea" || $0.identifier == "chat_input_field") && titleText($0) != nil
        })
        let heading = controls.first(where: {
            ["current_chat_name_label", "big_title_line_h_view"].contains($0.identifier) && titleText($0) != nil
        })
        guard let titleAnchor = heading ?? input, let title = titleText(titleAnchor) else {
            throw ReaderError.noConversation
        }
        // A display name is not a WeChat account ID. Persisted memory must use a user-confirmed alias.
        let context = root.title.lowercased().contains("聊天") ? "main-chat-window" : "chat-window"
        let conversationID = digest([bundleID, context, title])
        var events: [MessageEvent] = []
        var mediaCount = 0
        var unknownCount = 0
        collect(messageList, modern: messageList.identifier == "chat_message_list", events: &events,
                mediaCount: &mediaCount, unknownCount: &unknownCount)

        var timestamp: String?
        var occurrences: [String: Int] = [:]
        var messages: [ReaderMessage] = []
        var quotedCount = 0
        for event in events {
            switch event {
            case .timestamp(let value): timestamp = value
            case .message(let sender, let text, let quoted):
                let outgoing = ["我", "Me", "me", "You", "you"].contains(sender)
                let key = digest([sender, text, timestamp ?? ""])
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1
                // Distinct identical bubbles are retained. IDs are observation IDs, not server message IDs.
                messages.append(ReaderMessage(id: digest([conversationID, key, String(occurrence)]), sender: sender,
                                              text: text, timestamp: timestamp, isOutgoing: outgoing))
                if quoted { quotedCount += 1 }
            }
        }
        guard !messages.isEmpty else { throw ReaderError.noMessages }
        var warnings = [
            "仅包含微信当前界面暴露的文字；不是完整聊天历史。时间沿用最近一个可见时间标记，未经补全。",
            "会话按窗口和显示名称识别，无法区分同名联系人或确认微信账号；持久记忆请绑定独立别名。",
            "同名检查仅覆盖本次可见且成功读取的会话条目，不能排除其他同名联系人。",
            "消息 ID 用于当前片段比对；滚动、时间标记变化或重复短句可能影响去重。"
        ]
        if mediaCount > 0 { warnings.append("已跳过 \(mediaCount) 条图片、语音、表情或其他不支持的消息。") }
        if unknownCount > 0 { warnings.append("有 \(unknownCount) 个消息元素缺少可靠的发送者标签，已跳过。") }
        if quotedCount > 0 { warnings.append("引用消息保留界面原文，未推断引用与正文的结构。") }
        let sidebarNames = root.all(where: { $0.identifier.hasPrefix("MMChatsTableCellView") }).compactMap { row in
            row.strings.first?.split(separator: ",", maxSplits: 1).first.map(String.init)
        }
        if sidebarNames.filter({ clean($0) == title }).count > 1 {
            warnings.append("当前可见会话列表中发现多个同名条目；请为本次会话选择独立记忆别名，避免混合记录。")
        }
        if messageList.identifier == "chat_message_list" {
            warnings.append("当前使用微信 4.x 结构兼容模式，只接收带明确发送者标签的文字。")
        }
        return Result(title: title, titleToken: titleAnchor.token, conversationID: conversationID,
                      messages: messages, warnings: warnings)
    }

    static func titleText(_ node: WeChatAXNode) -> String? {
        let isInput = node.role == "AXTextArea" || node.identifier == "chat_input_field"
        let candidates = isInput ? [node.title, node.label] : [node.value, node.title, node.label]
        let generic = ["微信", "WeChat", "消息", "Messages", "输入", "输入消息", "Message", "Type a message", "聊天输入框"]
        return candidates.map(clean).first(where: { !$0.isEmpty && !generic.contains($0) })
    }

    static func isMessageList(_ node: WeChatAXNode) -> Bool {
        node.identifier == "chat_message_list"
            || (node.role == "AXTable" && node.strings.contains(where: { ["消息", "Messages"].contains($0) }))
    }

    /// Counts only; never return titles, labels, values, IDs, or their hashes.
    static func diagnosticCounts(_ root: WeChatAXNode) -> String {
        let nodes = root.all(where: { _ in true })
        let tables = nodes.filter { $0.role == "AXTable" || $0.role == "AXList" }
        let text = nodes.filter {
            $0.identifier.hasPrefix("MMTextMessageCellView") || $0.identifier.hasPrefix("MMAppReferMessageCellView")
        }
        let messageTables = tables.filter(isMessageList).count
        let sidebarRows = nodes.filter { $0.identifier.hasPrefix("MMChatsTableCellView") }.count
        let inputTitles = nodes.filter {
            ($0.role == "AXTextArea" || $0.identifier == "chat_input_field") && titleText($0) != nil
        }.count
        let descriptionSpeakers = text.filter { splitSpeaker($0.label) != nil }.count
        let titleSpeakers = text.filter { splitSpeaker($0.title) != nil }.count
        let valueSpeakers = text.filter { splitSpeaker($0.value) != nil }.count
        return "tables=\(tables.count) messageTables=\(messageTables) textCells=\(text.count) sidebarRows=\(sidebarRows) inputTitles=\(inputTitles) speakerDescription=\(descriptionSpeakers) speakerTitle=\(titleSpeakers) speakerValue=\(valueSpeakers)"
    }

    private static func outsideMessages(_ node: WeChatAXNode) -> [WeChatAXNode] {
        if isMessageList(node) { return [] }
        return [node] + node.children.flatMap(outsideMessages)
    }

    private enum MessageEvent {
        case timestamp(String)
        case message(String, String, Bool)
    }

    private static func collect(_ node: WeChatAXNode, modern: Bool, events: inout [MessageEvent],
                                mediaCount: inout Int, unknownCount: inout Int) {
        if node.identifier.hasPrefix("MMTimeStampCellView") {
            if let text = readableTexts(node).first { events.append(.timestamp(text)) }
            return
        }
        let quoted = node.identifier.hasPrefix("MMAppReferMessageCellView")
        let knownText = node.identifier.hasPrefix("MMTextMessageCellView") || quoted
        let isMedia = node.identifier.hasPrefix("MM") && node.identifier.contains("MessageCellView") && !knownText
        if isMedia { mediaCount += 1; return }
        if knownText {
            let candidates = readableTexts(node)
            if let message = candidates.compactMap(splitSpeaker).first {
                events.append(.message(message.0, message.1, quoted))
            } else { unknownCount += 1 }
            return
        }
        // The compatibility path requires an explicit speaker prefix; never guess direction from position.
        if modern, node.role == "AXCell" || node.role == "AXRow" || node.role == "AXStaticText" || node.role == "AXTextArea" {
            if let message = node.strings.compactMap(splitSpeaker).first {
                events.append(.message(message.0, message.1, false))
                return
            }
        }
        for child in node.children {
            collect(child, modern: modern, events: &events, mediaCount: &mediaCount, unknownCount: &unknownCount)
        }
    }

    private static func readableTexts(_ node: WeChatAXNode) -> [String] {
        // Deduplicate alternate attributes within one bubble, never between bubbles.
        var seen = Set<String>()
        return (node.strings + node.children.flatMap(readableTexts)).map(clean).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    static func splitSpeaker(_ label: String) -> (String, String)? {
        guard let range = ["说:", "说：", " says:", " says："].compactMap({ label.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let sender = clean(String(label[..<range.lowerBound]))
        let body = clean(String(label[range.upperBound...]))
        guard !sender.isEmpty, sender.count <= 100, !sender.contains("\n"), !body.isEmpty else { return nil }
        return (sender, body)
    }

    static func clean(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func digest(_ parts: [String]) -> String {
        // Length-prefix encoding avoids ambiguous boundaries when text contains separators.
        let bytes = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Shared by native AX capture and budget-starvation fixtures. Discover controls
/// first, then messages, and finally the visible sidebar; never expand a full inbox.
enum WeChatCaptureTraversal {
    static func read<Element>(root: Element,
                              shallow: (Element, Int) -> WeChatAXNode?,
                              children: (Element) -> [Element],
                              visibleRows: (Element) -> [Element],
                              messageRowLimit: Int = 120,
                              omittedMessageRows: (Int) -> Void = { _ in }) -> WeChatAXNode? {
        var deferred: [(element: Element, token: Int, depth: Int, isMessages: Bool, isSidebar: Bool)] = []
        func walk(_ element: Element, depth: Int, deferTables: Bool) -> WeChatAXNode? {
            guard var node = shallow(element, depth) else { return nil }
            node.children = []
            let isMessages = WeChatParser.isMessageList(node)
            if deferTables && (node.role == "AXTable" || node.role == "AXList" || isMessages) {
                let isSidebar = node.role == "AXTable" && node.strings.contains(where: { ["会话", "Chats", "Conversations"].contains($0) })
                deferred.append((element, node.token, depth, isMessages, isSidebar))
                return node
            }
            node.children = children(element).compactMap { walk($0, depth: depth + 1, deferTables: deferTables) }
            return node
        }
        func replacing(_ node: WeChatAXNode, token: Int, with replacement: [WeChatAXNode]) -> WeChatAXNode {
            var result = node
            if result.token == token { result.children = replacement }
            else { result.children = result.children.map { replacing($0, token: token, with: replacement) } }
            return result
        }
        guard var result = walk(root, depth: 0, deferTables: true) else { return nil }
        // The original child order inside each message table is retained.
        for table in deferred.filter({ $0.isMessages }) {
            let loadedRows = children(table.element)
            let limit = max(1, messageRowLimit)
            omittedMessageRows(max(0, loadedRows.count - limit))
            let rows = loadedRows.suffix(limit).compactMap { walk($0, depth: table.depth + 1, deferTables: false) }
            result = replacing(result, token: table.token, with: rows)
        }
        for table in deferred.filter({ $0.isSidebar && !$0.isMessages }) {
            // No fallback to AXChildren: AXVisibleRows may be unsupported, and
            // scanning the full sidebar would recreate the observed starvation.
            let rows = visibleRows(table.element).compactMap { walk($0, depth: table.depth + 1, deferTables: false) }
            result = replacing(result, token: table.token, with: rows)
        }
        return result
    }
}

private enum AXRead {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        value(element, attribute) as? Bool ?? false
    }
    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }
    static func windowDiagnostics(_ element: AXUIElement, index: Int) -> String {
        func attribute(_ name: String) -> (CFTypeRef?, AXError) {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return (result, error)
        }
        let role = attribute(kAXRoleAttribute)
        let title = attribute(kAXTitleAttribute)
        let main = attribute(kAXMainAttribute)
        let minimized = attribute(kAXMinimizedAttribute)
        let roleText = role.0 as? String ?? ""
        let titleText = title.0 as? String ?? ""
        let titleMatches = titleText.contains("聊天") || titleText.lowercased().contains("chats")
        let mainValue = (main.0 as? Bool).map { $0 ? "1" : "0" } ?? "unknown"
        let minimizedValue = (minimized.0 as? Bool).map { $0 ? "1" : "0" } ?? "unknown"
        // Only known-role comparisons, lengths, flags and AX result codes are returned.
        return "w\(index):roleIsAXWindow=\(roleText == kAXWindowRole ? 1 : 0),roleLength=\(roleText.count),titleLength=\(titleText.count),titleHasChat=\(titleMatches ? 1 : 0),main=\(mainValue),minimized=\(minimizedValue),roleAX=\(role.1.rawValue),titleAX=\(title.1.rawValue),mainAX=\(main.1.rawValue),minimizedAX=\(minimized.1.rawValue)"
    }
    static func shallowNode(_ element: AXUIElement, token: Int) -> WeChatAXNode {
        let role = string(element, kAXRoleAttribute)
        return WeChatAXNode(token: token, role: role, identifier: string(element, kAXIdentifierAttribute),
                           title: string(element, kAXTitleAttribute),
                           value: role == kAXTextAreaRole || role == kAXTextFieldRole ? "" : string(element, kAXValueAttribute),
                           label: string(element, kAXDescriptionAttribute), selected: bool(element, kAXSelectedAttribute))
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

@MainActor
private final class AXTreeCapture {
    var elementsByToken: [Int: AXUIElement] = [:]
    var truncated = false
    var failedReads = false
    var omittedMessageRows = 0
    private var visited: [CFHashCode: [AXUIElement]] = [:]
    private let startedAt = Date()
    private var truncationReasons = Set<String>()
    private var maxDepth = 0
    private var count = 0

    func read(_ element: AXUIElement) -> WeChatAXNode? {
        WeChatCaptureTraversal.read(root: element,
            shallow: { self.readMetadata($0, depth: $1) },
            children: { AXRead.elements($0, kAXChildrenAttribute) ?? [] },
            visibleRows: { AXRead.elements($0, kAXVisibleRowsAttribute) ?? [] },
            omittedMessageRows: { self.omittedMessageRows += $0 })
    }

    private func readMetadata(_ element: AXUIElement, depth: Int) -> WeChatAXNode? {
        guard depth <= 20, count < 2500, Date().timeIntervalSince(startedAt) < 4 else {
            truncated = true
            if depth > 20 { truncationReasons.insert("depth") }
            if count >= 2500 { truncationReasons.insert("nodes") }
            if Date().timeIntervalSince(startedAt) >= 4 { truncationReasons.insert("deadline") }
            return nil
        }
        maxDepth = max(maxDepth, depth)
        let hash = CFHash(element)
        if visited[hash, default: []].contains(where: { CFEqual($0, element) }) { return nil }
        visited[hash, default: []].append(element)
        count += 1
        let token = count
        elementsByToken[token] = element
        let node = AXRead.shallowNode(element, token: token)
        guard !node.role.isEmpty else { failedReads = true; return nil }
        return node
    }

    func diagnostics(root: WeChatAXNode?, stage: String) -> String {
        let captureMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        var fields = "stage=\(stage) nodes=\(count) elapsedMs=\(captureMilliseconds) depth=\(maxDepth) truncated=\(truncated ? 1 : 0) limit=\(truncationReasons.sorted().joined(separator: "+")) failedRead=\(failedReads ? 1 : 0) omittedMessageRows=\(omittedMessageRows)"
        guard let root else { return fields }
        fields += " " + WeChatParser.diagnosticCounts(root)
        // Diagnose whether CUA's labels came from AXHelp. Probe after capture so
        // extra attribute reads do not consume the existing traversal deadline.
        let probes = root.all(where: {
            $0.role == "AXTable" || $0.role == "AXList" || $0.identifier.hasPrefix("MMTextMessageCellView")
        }).prefix(16)
        var helpNonempty = 0
        var helpMessageTables = 0
        var helpSpeakers = 0
        for node in probes {
            guard let element = elementsByToken[node.token] else { continue }
            let help = AXRead.string(element, kAXHelpAttribute)
            if !help.isEmpty { helpNonempty += 1 }
            if ["消息", "Messages"].contains(help) { helpMessageTables += 1 }
            if WeChatParser.splitSpeaker(help) != nil { helpSpeakers += 1 }
        }
        fields += " helpProbes=\(probes.count) helpNonempty=\(helpNonempty) helpMessageTables=\(helpMessageTables) helpSpeakers=\(helpSpeakers)"
        return fields
    }
}
