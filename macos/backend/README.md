# Jev 本机分析后端

仅使用 Python 3.9 标准库。CLI 从 stdin 接收 UTF-8 JSON，在 stdout 输出一个 JSON 对象。成功 exit 0，错误 exit 1；错误信息不包含云服务原始 stderr 或聊天原文。

```sh
/usr/bin/python3 backend/engine.py status
/usr/bin/python3 backend/engine.py demo
/usr/bin/python3 -m unittest discover -s backend/tests -v
```

分析示例（此命令只向 Jev 发送内置虚构聊天；会产生一次 API 调用）：

```sh
/usr/bin/python3 backend/engine.py demo | /usr/bin/python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["request"], ensure_ascii=False))' | /usr/bin/python3 backend/engine.py analyze
```

各命令支持 `--data-dir /绝对路径/目录`，默认 `~/Library/Application Support/JevWeChatAssistant/`。`--helper` 可指定受信任的本机 TypeSafe 调用器，默认使用随项目提供的 `typesafe_client.py`，可用 `JEV_TYPESAFE_HELPER` 覆盖。默认客户端读取 `TYPESAFE_API_KEY` 或专用 Keychain；分析引擎不存储或输出密钥，也不更改默认账号。

## 输入

`analyze` 和 `import`：

```json
{
  "conversation_id": "稳定且唯一的会话 ID",
  "conversation_title": "会话显示名",
  "messages": [
    {"id": "稳定消息 ID", "sender": "other", "text": "原文", "timestamp": "可选的原始时间文本"}
  ],
  "save_history": false,
  "source": "manual",
  "confirmed_cloud": true
}
```

- `sender`: `self`、`other`、`unknown`；不要依据消息内容猜测身份。
- `source`: `wechat`、`manual`、`demo`。
- 只有 `save_history=true` 才保存原文；`import` 不调用云服务。
- 除完整匹配内置演示外，分析必须 `confirmed_cloud=true`。会话当前文字和最多 6 条同会话历史候选会发给 TypeSafe。
- 输入上限 1 MB；每批 1–200 条；单条 6,000 字符；当前消息合计 60,000 字符。
- 未知字段不传给云服务。不得将来源的私有消息冒充内置演示。
- `analyze` 成功后才保存当前消息；服务失败没有伪造百分比或离线兜底结果。

`search`：`{"conversation_id":"…","query":"周末"}`。仅查询该会话，返回最多 6 条原文。

`forget`：`{"conversation_id":"…","confirmed":true}`。只删除本工具保存的这个会话；不接触微信数据库。

`status` / `stats` 不需要 stdin、不调用云服务；返回 `backend_ready`、`helper_available`、`credential_status="not_checked"`、`storage` 路径和历史数量。调用器存在不等于凭证有效。默认客户端的 TYPESAFE_API_KEY 与专用钥匙串配置见上级 README。

`demo` 不需要 stdin、不调用云服务，返回 `request` 和 `history`。对返回的 `request` 执行 `analyze`，才会发送一次真实 Jev 请求。

## 9Router 回复模型

分析请求可添加以下配置。Jev 完成判断后，后端请求所选模型生成两条草稿。模型列表通过本机接口实时发现，不固定模型白名单。

```json
{
  "draft_provider": {
    "base_url": "http://127.0.0.1:20128/v1",
    "model": "从实时模型列表选择的 ID"
  }
}
```

`models` 命令接收 `{"draft_provider":{"base_url":"http://127.0.0.1:20128/v1"}}`，返回 `models:[{"id":"…"}]`。此操作不发送聊天，模型列表可用不代表上游推理成功。

仅接受 `http` / `https` 和本机 `127.0.0.1`、`localhost`、`::1`，路径为 `/v1`。不会使用系统代理、跟随重定向或自动重试；推理 60 秒墙钟上限。默认不附带凭证。如路由器需要身份验证，可额外配置 `api_key_env` 引用已经存在的环境变量，或配置 `keychain_service` 和可选 `keychain_account` 引用 macOS 钥匙串。两种方式只选一种。拒绝配置中的明文 `api_key` / `token` / `authorization` / `headers`，不修改路由器认证。

9Router 可能继续把聊天发送到选定云端上游；它不等同于离线模型。真实聊天仍需 `confirmed_cloud=true`，界面授权应明确包含 TypeSafe/Jev、9Router 及其选定上游。

成功后 `drafts[].kind="model"`，并返回 `draft_provider:{kind:"9router",model,base_url,usage,elapsed_seconds,succeeded:true}`。候选严格校验为两条 JSON 文本、每条最多 160 字、引用 ID 必须存在。模型仍可能写错事实，必须由使用者核对后再发送。

当路由器不可用、身份验证失败、超时或返回格式不正确时，保留成功的 Jev 判断，返回 `draft_provider.succeeded=false` 和 `warnings:[{code,message}]`，明确显示模板草稿（`kind="template"`）。不会把模板称为模型生成。未配置 `draft_provider` 时只生成模板。

## 输出

成功分析包含 `analysis`、`drafts`、`evidence`、`usage`、`model`、`elapsed_seconds`、`cloud_sent`、`saved_messages`。

- `analysis.needs`: 4 项独立 Noul，不必相加为 1。
- `analysis.action`: Choice 的 `id`、`label`、`probabilities`、`confidence`。confidence 是分布集中程度，不是建议正确率。
- `analysis.tension`: 五级 Score 的原始 0–4 分乘以 2.5，显示为 0–10；不表示人身危险或关系质量。
- `analysis.needs_history_probability`、`settled_probability`: 独立 Noul。
- `drafts[].kind` 为 `template` 或 `model`；`basis` 是引用原文 ID。Jev 不生成文字。模板不虚构约定或行动；模型草稿仍需用户核对。
- `evidence[].retrieval`: `lexical_match` 表示关键词候选，`recent_context` 表示仅按近期顺序补充的背景，二者都不代表已验证相关。
- `usage` 只返回服务实际报告的 token 数；不预估账单。

错误格式：`{"ok":false,"error":{"code":"cloud_consent_required","message":"…"}}`。不要在后台自动重试 API 失败；用户可以手动重试。

## 历史边界

SQLite 只存已获本机保存授权的消息原文，不把预测写成事实。查询按 `conversation_id` 严格隔离；不能只用可能重名的联系人显示名作为可靠身份。稳定消息 ID 可以保留相同内容的真实重复消息，并去重重复读取。没有稳定 ID 或准确时间时，用原文指纹和每批出现序号去重；跨次捕获的完全相同消息无法可靠区分。

检索使用汉字双字组和英文单词重合度，扫描同会话最近 5,000 条已保存消息，并可补充近期原文。它不是微信全量历史搜索，尚未接入数据库解密、语义向量或云端记忆。跨天回忆必须先真实导入或保存过对应原文。

接口依据（2026-09-21 核对）：[API](https://docs.typesafe.ai/api)、[Noul](https://docs.typesafe.ai/primitives/noul)、[Choice](https://docs.typesafe.ai/primitives/choice)、[Score](https://docs.typesafe.ai/primitives/score)、[检索候选与重排](https://docs.typesafe.ai/cookbooks/rerank_typesafe)。
