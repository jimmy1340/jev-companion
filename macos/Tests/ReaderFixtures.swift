import Foundation

/// Compile with WeChatReader.swift only. These synthetic trees never access WeChat or AX APIs.
@main
struct ReaderFixtures {
    static func main() throws {
        func bubble(_ text: String, id: String = "MMTextMessageCellView") -> WeChatAXNode {
            WeChatAXNode(role: "AXRow", children: [
                WeChatAXNode(role: "AXCell", children: [
                    WeChatAXNode(role: "AXCell", identifier: id, label: text,
                                 children: [WeChatAXNode(role: "AXStaticText", value: text)])
                ])
            ])
        }
        func root(_ messages: [WeChatAXNode], name: String = "示例联系人", sidebar: [WeChatAXNode] = []) -> WeChatAXNode {
            WeChatAXNode(role: "AXWindow", title: "微信 (聊天)", children: [
                WeChatAXNode(role: "AXTable", title: "会话", children: sidebar),
                WeChatAXNode(role: "AXTable", title: "消息", children: messages),
                WeChatAXNode(token: 9, role: "AXTextArea", title: name, value: "未发送草稿，不能作为消息或会话名")
            ])
        }
        let time = WeChatAXNode(role: "AXCell", identifier: "MMTimeStampCellView", label: "昨天 19:12")
        let fixture = root([
            time, bubble("示例联系人说:周末想出去吃饭"), bubble("我说:好"), bubble("我说:好"),
            bubble("示例联系人:发送了一个表情", id: "MMStickerMessageCellView"),
            bubble("示例联系人说:你来安排吧\n引用：周末想出去吃饭", id: "MMAppReferMessageCellView"),
            bubble("没有明确发送者，不能猜测")
        ])
        let parsed = try WeChatParser.parse(root: fixture, bundleID: "com.tencent.xinWeChat")
        precondition(parsed.title == "示例联系人")
        precondition(parsed.messages.count == 4, "Bubble descendants must not duplicate a message")
        precondition(parsed.messages[0].sender == "示例联系人" && !parsed.messages[0].isOutgoing)
        precondition(parsed.messages[1].isOutgoing && parsed.messages[2].isOutgoing)
        precondition(parsed.messages[1].id != parsed.messages[2].id, "Repeated bubbles must stay distinct")
        precondition(parsed.messages.allSatisfy { $0.timestamp == "昨天 19:12" })
        precondition(parsed.messages.last!.text.contains("引用："))
        precondition(parsed.warnings.contains(where: { $0.contains("已跳过 1 条") }))
        precondition(parsed.warnings.contains(where: { $0.contains("缺少可靠") }))
        let diagnostic = WeChatParser.diagnosticCounts(fixture)
        precondition(diagnostic.contains("messageTables=1") && diagnostic.contains("textCells=5"))
        precondition(!diagnostic.contains("示例联系人") && !diagnostic.contains("周末") && !diagnostic.contains("昨天"), "Diagnostics must contain counts only")
        let again = try WeChatParser.parse(root: fixture, bundleID: "com.tencent.xinWeChat")
        precondition(parsed.messages == again.messages, "Unchanged snapshots must have stable IDs")
        let other = try WeChatParser.parse(root: root([bubble("我说:好")], name: "另一个会话"), bundleID: "com.tencent.xinWeChat")
        precondition(parsed.conversationID != other.conversationID)
        precondition(!other.messages[0].id.contains("好"), "IDs contain no plaintext")

        let duplicates = root([bubble("我说:测试")], sidebar: [
            WeChatAXNode(identifier: "MMChatsTableCellView_0", label: "示例联系人,预览一,刚刚"),
            WeChatAXNode(identifier: "MMChatsTableCellView_0", label: "示例联系人,预览二,昨天")
        ])
        let duplicateResult = try WeChatParser.parse(root: duplicates, bundleID: "com.tencent.xinWeChat")
        precondition(duplicateResult.warnings.contains(where: { $0.contains("多个同名") }))

        let modern = WeChatAXNode(role: "AXWindow", title: "WeChat", children: [
            WeChatAXNode(token: 42, role: "AXStaticText", identifier: "current_chat_name_label", value: "Sample"),
            WeChatAXNode(role: "AXTextArea", identifier: "chat_input_field", title: "Message", value: "Draft"),
            WeChatAXNode(role: "AXList", identifier: "chat_message_list", children: [
                WeChatAXNode(role: "AXRow", label: "Sample says:Hello", children: [
                    WeChatAXNode(role: "AXStaticText", value: "Sample says:Hello")
                ]),
                WeChatAXNode(role: "AXRow", label: "Me says:Hi"),
                WeChatAXNode(role: "AXStaticText", value: "Unattributed text must be ignored")
            ])
        ])
        let modernResult = try WeChatParser.parse(root: modern, bundleID: "com.tencent.xinWeChat")
        precondition(modernResult.title == "Sample" && modernResult.titleToken == 42)
        precondition(modernResult.messages.count == 2 && modernResult.messages[1].isOutgoing)
        precondition(modernResult.messages.allSatisfy { $0.timestamp == nil })

        // Reproduce the observed 130-row sidebar starving messages under a finite
        // capture budget. Production and this fixture use the same scheduler.
        func captureSynthetic(_ tree: WeChatAXNode, budget: Int, rowLimit: Int = 120) throws
            -> (WeChatAXNode, WeChatAXNode, Int) {
            var nodes: [Int: WeChatAXNode] = [:]
            var edges: [Int: [Int]] = [:]
            var nextToken = 0
            func flatten(_ node: WeChatAXNode) -> Int {
                nextToken += 1
                let token = nextToken
                var value = node
                value.token = token
                value.children = []
                nodes[token] = value
                edges[token] = node.children.map(flatten)
                return token
            }
            let rootToken = flatten(tree)
            var reads = 0
            var omitted = 0
            let captured = WeChatCaptureTraversal.read(root: rootToken, shallow: { token, _ in
                guard reads < budget else { return nil }
                reads += 1
                return nodes[token]
            }, children: { edges[$0] ?? [] }, visibleRows: { token in
                Array((edges[token] ?? []).prefix(3))
            }, messageRowLimit: rowLimit, omittedMessageRows: { omitted += $0 })!

            // The former full-depth-first traversal fails for this same fixture.
            var oldReads = 0
            func oldWalk(_ token: Int) -> WeChatAXNode? {
                guard oldReads < budget, var value = nodes[token] else { return nil }
                oldReads += 1
                value.children = (edges[token] ?? []).compactMap(oldWalk)
                return value
            }
            return (captured, oldWalk(rootToken)!, omitted)
        }
        let largeSidebar = (0..<130).map { index in
            WeChatAXNode(role: "AXRow", children: [WeChatAXNode(role: "AXCell", children: [
                WeChatAXNode(role: "AXRow", identifier: "MMChatsTableCellView_0", label: "测试条目\(index),预览,时间")
            ])])
        }
        var largeFixture = root([time, bubble("示例联系人说:第一条"), bubble("我说:第二条")], sidebar: largeSidebar)
        largeFixture.children.insert(WeChatAXNode(role: "AXTable", title: "无关表格", children: largeSidebar), at: 1)
        let scheduled = try captureSynthetic(largeFixture, budget: 24)
        do {
            _ = try WeChatParser.parse(root: scheduled.1, bundleID: "test")
            preconditionFailure("The former DFS must reproduce sidebar starvation")
        } catch ReaderError.noMessages { }
        let scheduledResult = try WeChatParser.parse(root: scheduled.0, bundleID: "test")
        precondition(scheduledResult.title == "示例联系人")
        precondition(scheduledResult.messages.map(\.text) == ["第一条", "第二条"], "Messages must fit before sidebar work and preserve order")
        precondition(scheduled.0.first(where: { $0.title == "会话" })?.children.count == 3, "Only visible sidebar rows may be visited")
        precondition(scheduled.0.first(where: { $0.title == "无关表格" })?.children.isEmpty == true, "Unrelated tables must not be treated as an inbox")

        let longHistory = root([time] + (0..<6).map { bubble("示例联系人说:第\($0)条") })
        let bounded = try captureSynthetic(longHistory, budget: 1000, rowLimit: 4)
        let boundedResult = try WeChatParser.parse(root: bounded.0, bundleID: "test")
        precondition(bounded.2 == 3, "Omitted loaded rows must be reported")
        precondition(boundedResult.messages.map(\.text) == ["第2条", "第3条", "第4条", "第5条"], "Read the tail while retaining chronological order")

        precondition(WeChatParser.splitSpeaker("甲说:正文包含乙说:引用")?.1 == "正文包含乙说:引用")
        precondition(WeChatParser.splitSpeaker("甲说：正文")?.0 == "甲")
        precondition(WeChatParser.splitSpeaker("甲说：正文说:引用")?.0 == "甲")
        precondition(WeChatParser.splitSpeaker("没有标签") == nil)
        precondition(WeChatParser.titleText(WeChatAXNode(role: "AXTextArea", value: "不读取草稿")) == nil)
        do {
            _ = try WeChatParser.parse(root: root([bubble("图片", id: "MMImageMessageCellView")]), bundleID: "test")
            preconditionFailure("Media-only conversation should report no readable text")
        } catch ReaderError.noMessages { }
        print("PASS: reader fixtures (3.8 cells, 4.x list, titles, speakers, duplicates, timestamps, media, quotes, identity, private diagnostics, sidebar starvation, visible rows, bounded history order)")
    }
}
