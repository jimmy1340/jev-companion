# Jev 伴聊

在微信旁边使用的原生沟通助手。Jev 对已读取的文字给出结构化判断，可选的回复模型生成草稿，由使用者核对后自行发送。

[English](README.md) · [Mac 安装与配置](macos/README.md) · [Windows 使用说明](windows/README.md)

## 功能

- 读取微信当前窗口暴露的文字，也支持粘贴和内置虚构示例。
- 在独立窗口同步聊天气泡，在对应消息下显示 Jev 分析卡；每条卡只使用截至该消息的前文。
- 展示可能诉求、下一步动作概率和紧张程度。数值是模型对文字的估计，不能证明真实心理。
- 可经本机 9Router 或兼容服务生成两条回复草稿，仅提供复制。
- Mac 可选择将原文保存在本机 SQLite 中，检索按会话隔离；Windows 版暂不持久保存聊天。

项目不发送微信消息，不修改微信客户端，不解密聊天库，也不向微信进程注入代码。真实文字发送到模型前需要确认处理范围，详见[隐私说明](docs/PRIVACY.md)。

## 当前状态

这是个人原型的首次公开源码整理。仓库版本为 0.1.0，Mac 应用为 0.3.1，Windows 预览版为 0.4.1。各平台功能与验证范围不同。

Mac 原型有真实微信文字读取和虚构对话模型调用的历史验收记录；Windows 新增的窗口 OCR 路径仍待真机验收。自动测试和构建通过不等于所有微信版本均兼容，见[验证记录](docs/VALIDATION.md)。

## 构建

Mac 需要 macOS 13 以上、Apple Command Line Tools 和 Python 3.9 以上：

```sh
bash macos/test.sh
bash macos/build.sh
```

应用生成在 `dist/Jev伴聊.app`，仅作本机临时签名。当前构建不依赖 Codex、不安装到系统应用目录、不修改权限。按 [Mac 配置说明](macos/README.md)提供自己的 TypeSafe 凭证；回复模型可关闭。

Windows 需要 .NET SDK 10 构建，目标为 Windows 10 2004 以上及 Windows 11 x64：

```powershell
dotnet run --project windows/Tests/Jev.Tests.csproj -c Release
dotnet publish windows/App/Jev.Windows.csproj -c Release -r win-x64 --self-contained true -o dist/windows
```

发布目录内的单文件应用自带运行环境，连接配置由使用者填写。安装器构建方法与 OCR 限制见 [Windows 说明](windows/README.md)。

## 参与维护

欢迎提供微信版本适配反馈、Windows OCR 真机验证、配置改进和翻译。提交问题时请使用虚构对话，移除联系人、聊天、截图和密钥。见[贡献指南](CONTRIBUTING.md)及[后续计划](docs/ROADMAP.md)。

原创源码按 [MIT](LICENSE) 开源，第三方许可保留在 `windows/Notices/`。项目与腾讯、TypeSafe、OpenAI 无官方隶属关系。
