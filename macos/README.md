# Jev 伴聊 macOS

Mac 原生独立窗口，使用 Accessibility 读取微信已暴露的文字，用 Jev 判断、可选的本机回复模型生成草稿。需要 macOS 13 以上、Apple Command Line Tools、Python 3.9 以上。

## 构建与启动

在仓库根目录执行：

```sh
bash macos/test.sh
bash macos/build.sh
```

默认构建缓存放在 `macos/.build/`，应用放在 `dist/Jev伴聊.app`。可用 `JEV_BUILD_DIR` 和 `JEV_OUTPUT_DIR` 指定构建位置。应用是本机临时签名，未做 Apple 公证。

干净的 Mac 上先执行 `xcode-select --install`。`bash macos/build.sh` 使用 `xcrun` 和 `/usr/bin/python3`；Python 低于 3.9 会在编译前退出。Homebrew 或 pyenv 里的解释器不会被应用调用。构建不需要微信、Codex 或已经写好的密钥。

## 第一次分析失败时

示例和粘贴在点击分析之前不会调用模型。失败原因会分开说明，界面不显示密钥本身：

- **尚未配置**：终端启动前设置 `TYPESAFE_API_KEY`。从 Finder 打开时，终端变量不会带过去，请改用下面的钥匙串条目。
- **变量已设置但为空**：不会改去读钥匙串。填入密钥，或取消该变量后再用钥匙串。
- **格式不正确**：密钥须是一行可打印字符，不要带空格、换行或两侧引号。
- **HTTP 401**：密钥已送出但被拒绝。请在 TypeSafe 核对这把密钥。应用不会改用其他工具保存的账号，也不会自动重试。

钥匙串账号必须是 `id -un` 的短用户名，不是「系统设置」里的显示名。服务名保持 `jev-companion-typesafe`，除非你同时设置了 `JEV_TYPESAFE_KEYCHAIN_SERVICE`。回复模型是可选项；不需要草稿时关闭「通过 9Router 生成回复」。`http://127.0.0.1:20128/v1` 指这台 Mac。

## TypeSafe 凭证

默认使用随项目提供的 `backend/typesafe_client.py`，直接访问 TypeSafe 官方 HTTPS API，不需要安装 Codex 或私人脚本。两种配置方式任选一种。

### 钥匙串

在 macOS“钥匙串访问”中新建通用密码：

- 名称／服务：`jev-companion-typesafe`
- 账号：当前 macOS 短用户名，可运行 `id -un` 查看。
- 密码：你自己的 TypeSafe API key。

密钥只保存在你的钥匙串，不写入仓库、配置 JSON 或聊天请求的正文。配置后可在 Finder 双击 `dist/Jev伴聊.app`。

### 环境变量

从终端启动程序时设置 `TYPESAFE_API_KEY`。以下示例以交互隐藏输入读取，不把密钥写入命令历史：

```sh
read -rs -p 'TypeSafe API key: ' TYPESAFE_API_KEY
printf '\n'
export TYPESAFE_API_KEY
./dist/Jev伴聊.app/Contents/MacOS/JevWeChatAssistant
unset TYPESAFE_API_KEY
```

以上读取语法用于 Bash，请先运行 `bash`。Finder 启动的程序通常不会继承终端变量，使用 Finder 时优先配置钥匙串。

高级配置：`JEV_TYPESAFE_KEYCHAIN_SERVICE`／`JEV_TYPESAFE_KEYCHAIN_ACCOUNT` 可改变凭证引用；`JEV_TYPESAFE_HELPER` 可指向现有可信调用器。外部调用器必须接受 `evaluate -`、从 stdin 读取请求、向 stdout 返回 TypeSafe 响应，并在失败时以非零状态退出。默认客户端不自动更换账号或重试，外部调用器须遵守同样约束。

## 可选回复模型

在“模型与连接”填写本机兼容 `/v1` 地址，默认是 `http://127.0.0.1:20128/v1`。刷新模型列表后选择模型。仅支持回环地址；模型服务可能继续转发到云端。

若服务无需认证，保持“使用钥匙串中的 9Router 凭证”关闭；若需要认证，在钥匙串创建名称为 `jev-companion-router`、账号为当前 macOS 短用户名的通用密码，并打开该选项。不会读取或迁移其他工具保存的账号。

关闭“通过 9Router 生成回复”可只使用 Jev 判断与明确标注的本地模板。模型目录可达不代表推理成功。

## 操作

1. “示例”加载虚构对话；点击分析才调用真实模型。
2. “粘贴”接受 `我：……`、`对方：……`，无需辅助功能权限。
3. “微信”读取当前已打开的聊天；首次在系统设置的辅助功能中允许本应用。
4. 核对文字和发送方，再确认云处理范围。逐条分析只带截至当前消息的前文。
5. 草稿只可复制，发送由你完成。跟随功能只作用于已授权的当前会话，切换会话或连接配置会暂停。

默认不保存聊天；启用本机会话记忆后，仅保存工具已读到的原文，按独立会话名隔离。删除只影响本工具的数据，不改微信。

## 兼容范围

原型主要针对 Mac 微信 3.8 的 Accessibility 结构，4.x 为保守兼容路径，不能保证所有版本。只读已暴露的文字，不处理语音、图片或未加载的全部历史。新构建的临时签名可能需要在辅助功能列表重新添加应用。

详见[架构](DESIGN.md)、[后端协议](backend/README.md)、[验证记录](../docs/VALIDATION.md)。
