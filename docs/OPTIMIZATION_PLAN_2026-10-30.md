# 优化计划（2026-10-30 至 2026-11-05）

审查基线是 `main` 上的 `33f670a`（已合并 PR #3「Clarify first-run credentials and clean-machine setup」）。PR #1、#2 是界面与发布流程，PR #3 已把缺失、空白、格式错误和 HTTP 401 的凭证提示分开，并写明干净机器上的工具链。本计划不重复那部分。

约束：每天只做小改动，保持现有分析、授权、会话隔离和「不自动发送微信」的行为。不引入依赖，不重构 SwiftUI / WPF。能在 Linux 上用现有测试项目验证的项优先。Day 1、Day 2 已完成；Day 3–7 只记录，尚未实现。

## Day 1 — 2026-10-30：本机历史库权限

**状态。** Done。已合并 [PR #4](https://github.com/jimmy1340/jev-companion/pull/4)。

**问题。** `macos/backend/engine.py` 的 `History` 用 `mkdir(mode=0o700)` 和事后 `chmod(0o600)` 保护 `history.sqlite3`。SQLite 自己以 `0644` 创建数据库和回滚 journal，再套进程 umask。umask `0022` 不会去掉 other 的读位，所以 journal 在 `INSERT` 期间是 `0644`，里面有聊天原文页。`mkdir(exist_ok=True)` 也不会把已经存在的 `0755` 目录收紧。目录一旦可被其他用户进入，提交前的 journal 就能被读到。另外，库文件拒绝符号链接，但 `-journal` / `-wal` / `-shm` 没有同样的检查，SQLite 会顺着链接把页写到别处。

**本次改动。**

- 写事务（`save`、`forget`）全程使用 umask `0077`，覆盖 journal 创建，结束后恢复原来的 umask。
- 目录本身不是符号链接时，保存和读取都把它收成 `0700`，并把普通数据库文件收成 `0600`。写路径会确认模式真的变成目标值。目录是符号链接时不 `chmod`，避免改到链接目标。
- 打开前拒绝符号链接、硬链接和非普通文件（含 fifo）。`-journal`、`-wal`、`-shm` 同样拒绝，因此不会把原文写入链接目标。
- 不改表结构、检索、云授权或分析 JSON。正常路径上的去重、id 冲突回滚和「未开启保存则不落盘」保持原样。

**涉及文件。**

- `macos/backend/engine.py`
- `macos/backend/tests/test_engine.py`
- `macos/backend/README.md`
- `docs/PRIVACY.md`
- `docs/VALIDATION.md`
- `CHANGELOG.md`
- `docs/OPTIMIZATION_PLAN_2026-10-30.md`

**验收。**

- `python3 -m unittest discover -s macos/backend/tests -v`：73 项通过（原先 67 项，新增 6 项）。
- umask `0` 时，真实历史目录为 `0700`，数据库和事务中的 journal 为 `0600`，返回后进程 umask 恢复。
- 预先建好的 `0755` 目录在 `save` 和 `stats` 之后变为 `0700`；第二次保存仍是去重（返回 0）。
- 数据库或 journal 的符号链接、硬链接、fifo 返回 `storage_error`，链接另一端的内容不变，错误文本不含聊天原文。
- 数据目录是符号链接时，链接目标的目录模式保持不变，库文件仍是 `0600`。
- 不在本次验收里：`bash macos/test.sh`、`bash macos/build.sh`（需要 macOS `swiftc`）、Windows 测试（本次未改 C#）、真实微信或在线模型。

**明确不做。** 不加密历史库，不拒绝「数据目录本身是符号链接」（用户可能把整个目录指到另一块盘），不用 `O_NOFOLLOW` 消除 lstat 与 open 之间的竞态。后两项见 Day 5。

## Day 2 — 2026-10-31：Windows 分析缓存键不要把两把密钥拼在一起

**状态。** Done。`PrefixKey` 对 `RouterKey` 和 `JevKey` 分别做 SHA-256，再写入缓存键，不再用 `\0` 把两把密钥拼成一个字符串。

**问题。** `windows/Core/Models.cs` 的 `Contract.PrefixKey` 在哈希前把 `RouterKey + "\0" + JevKey` 拼成一个字符串。`RouterKey="a\0b"`、`JevKey="c"` 与 `RouterKey="a"`、`JevKey="b\0c"` 得到同一缓存键，一张分析卡可能被另一组凭证复用。PR #3 的 `SecretIssue` 会拒绝不可打印字符，所以从设置对话框保存的密钥碰不到这条路径；`PrefixKey` 本身不强制该规则，内存中的 `Connection` 仍可能带入 `\0`。

**改动。** 两把密钥分别哈希（或按长度前缀编码字节）后再混入缓存键。同一前缀、标题、模型和凭证仍必须得到同一键；多出来的消息不能改变更早前缀的键；凭证、模型、标题变化必须改变键。不要把密钥原文写进异常或测试输出。

**涉及文件。** `windows/Core/Models.cs`，`windows/Tests/Program.cs`。

**验收。** 新增一对会在 `\0` 拼接下碰撞、在新算法下分开的用例。现有前缀相等性测试继续通过。Linux 或 Windows 上执行 `dotnet run --project windows/Tests/Jev.Tests.csproj -c Release`。不调用网络。

## Day 3 — 2026-11-01：本机 9Router 不走系统代理

**问题。** Python `router_http` 用 `http.client` 直连回环地址，不读 `HTTP_PROXY`。Windows `ModelClient` 的 `HttpClient` 默认使用系统代理，`http://127.0.0.1` 上的聊天和 `Bearer` 令牌可能被本机代理看到。TypeSafe 的远程 HTTPS 仍应允许代理，与 `typesafe_client.py` 一致。

**改动。** 回环请求使用 `UseProxy = false` 且 `AllowAutoRedirect = false` 的处理器；`https://api.typesafe.ai` 保持现有代理行为。给 Python 加一条回归：设置 `HTTP_PROXY` / `http_proxy` 后，`router_http` 仍然打到测试夹具，而不是代理地址。

**涉及文件。** `windows/Core/ModelClient.cs`，`windows/Tests/Program.cs`，`macos/backend/tests/test_router.py`。

**验收。** 现有 Windows 夹具仍证明密钥只出现在配置的 URI 上，401 响应体不进入错误文本。新增断言能区分「回环未使用代理」和「TypeSafe 仍可使用代理」。Python 套件继续全部通过。不访问真实 9Router 或 TypeSafe。

## Day 4 — 2026-11-02：历史检索按行缓存分词

**问题。** `ranked_history` 对最多 `MAX_HISTORY_SCAN`（5000）行各自调用 `tokens()`。同一次检索里重复计算，不改变排序规则也能去掉。

**改动。** 在单次 `ranked_history` 调用内按行文本缓存 token 集合。查询串本来就只分词一次。得分公式、字面量子串加分、`-index` 次序和 `recent_context` 补齐保持不变。不要为了提速截断消息文本。

**涉及文件。** `macos/backend/engine.py`，`macos/backend/tests/test_engine.py`。

**验收。** `test_single_character_literal_search` 和跨会话隔离测试结果不变。用固定的小语料比较优化前后的 id 顺序和 `retrieval` 标记。Python 套件全部通过。不做基准数字承诺。

## Day 5 — 2026-11-03：历史写入冲突与打开竞态

**问题。** `History.save` 先 `SELECT` 再 `INSERT`。两个进程同时写入时，唯一约束会抛 `sqlite3.IntegrityError`，`main` 把它收成笼统的 `storage_error`，而不是现有的 `message_id_conflict`。Day 1 在 lstat 和 `sqlite3.connect` 之间仍有替换文件的窗口。

**改动。** 在同一个写事务里捕获 `IntegrityError`，再读一次该行：内容一致则视为已存在，内容不一致则 `message_id_conflict`，并且整笔事务回滚（与现在的冲突测试一致）。若 Python 3.9 能用目录文件描述符或 `O_NOFOLLOW` 打开库文件且不改变普通文件行为，再收紧打开方式；做不到就在本计划里记一笔，不要用行为变化去换那一个竞态。

**涉及文件。** `macos/backend/engine.py`，`macos/backend/tests/test_engine.py`。

**验收。** 用替身连接让第二次插入抛出 `IntegrityError`，原文仍在，错误码为 `message_id_conflict`。现有去重和冲突回滚测试通过。不新增加密，不改 Swift 调用参数。

## Day 6 — 2026-11-04：Windows 模型响应不要把正文带进异常

**问题。** `ModelClient.Send` 直接 `JsonDocument.Parse`。解析失败时 `JsonException` 的消息可能含响应片段。界面上的 `Friendly` 会挡住 `JsonException`，但异常对象本身仍带着正文。Python `parse_model_drafts` 会拒绝除换行和制表符以外的控制字符；Windows `ParseRouter` 没有这一步，草稿可以带终端控制符进 WPF。

**改动。** 解析失败时抛出固定中文 `InvalidOperationException`，消息不含响应体和密钥。草稿字符串拒绝 `\n`、`\t` 以外的控制字符，长度规则不变。合法的 ` ```json ` 围栏仍可解析。

**涉及文件。** `windows/Core/ModelClient.cs`，`windows/Core/Models.cs`，`windows/Tests/Program.cs`。

**验收。** 夹具返回 `not-json` 加哨兵字符串时，异常消息不含哨兵。含 `\u001b` 的草稿被拒绝；现有围栏 JSON 和概率分布测试仍通过。`dotnet run --project windows/Tests/Jev.Tests.csproj -c Release`。

## Day 7 — 2026-11-05：CI 依赖钉死，不改产品行为

**问题。** `.github/workflows/ci.yml` 和 `release.yml` 使用浮动的 `actions/checkout@v4`、`setup-python@v5`、`setup-dotnet@v4`、`upload-artifact@v4`、`download-artifact@v4`。发布流程需要 `contents: write`，CI 已是 `contents: read`，这项不要放宽。

**改动。** 把上述 action 钉到提交 SHA，并在注释里保留版本号。给 CI 任务加上 `timeout-minutes`。在 `docs/VALIDATION.md` 补上这一周实际跑过的测试数量。不改构建脚本的产物内容。

**涉及文件。** `.github/workflows/ci.yml`，`.github/workflows/release.yml`，`docs/VALIDATION.md`。

**验收。** 工作流 YAML 可被解析。CI 权限仍是 `contents: read`，发布任务仍是 `contents: write`。不在这一天改 Python 或 C# 行为。

## 本周不排期

这些需要真机或会改变产品范围，不放进这 7 天：

- Windows UI Automation、窗口 OCR、遮挡、DPI 和选区复用（路线图里的 0.4.1 人工项）。
- 新版 macOS 微信 Accessibility 夹具。
- 历史库应用层加密。
- 自动发送微信、注入进程、解密微信数据库。
