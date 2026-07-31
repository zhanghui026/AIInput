# AIInput

macOS 菜单栏 AI 写作助手：在任意 App 中按 `Ctrl+Option+Cmd+E`，即可翻译、润色、处理划词内容，或把英文网页正文翻译成中文并生成摘要。

## 特性

- 全局热键 `Ctrl+⌥+⌘+E` 唤起，菜单栏常驻（无 Dock 图标）。
- 支持中译英、英译中、同语言润色，以及 11 种写作语气：忠实、简洁、专业、自然（去 AI 味）、友好、正式、口语、直接、自信/说服、学术、客观（去人称）。
- 在其他 App 选中文本后唤起，可自动识别中英文并立即翻译；可编辑输入框会直接替换选区，不可编辑页面会进入预览，可复制结果。
- 输入英文网页链接，可提取静态正文、分块翻译为中文，并可选生成中文摘要；明文 `http://` 链接会先升级为 HTTPS。
- macOS 26 使用原生 Liquid Glass；macOS 13–15 自动回退到系统模糊材质。
- 悬浮面板会根据鼠标所在显示器、Dock、菜单栏和预览高度自动选择上下方并保持完全可见，也支持全屏 App 与 Stage Manager。
- 悬浮输入框原生支持中文输入法组词（IME 友好）。
- 调用 MiniMax（Anthropic Messages 兼容接口）；普通翻译/润色会直接粘贴，网页结果或无可编辑目标时会留在面板中预览和复制。
- 通过剪贴板 + 模拟 `Cmd+V` 注入文本，粘贴后恢复原剪贴板内容。
- 设置页可配置 API Key、Base URL、模型名。

## 构建

运行时最低支持 macOS 13。编译原生 Liquid Glass 代码需要 Xcode 26+；使用旧 SDK 无法识别 `NSGlassEffectView`。

```bash
swift test
AIINPUT_SIGN_IDENTITY="<证书 SHA-1>" ./build.sh
```

产物为已完整签名并验证的 `AIInput.app`。为让辅助功能权限在重新构建后保持稳定且不被其他本机程序仿冒，构建脚本要求显式固定签名证书（建议填证书 SHA-1）：

```bash
security find-identity -v -p codesigning
AIINPUT_SIGN_IDENTITY="<证书 SHA-1>" ./build.sh
```

没有开发证书时，只能明确启用可被同机程序仿冒的本地 ad-hoc 模式；它适合开发验证，不可分发：

```bash
AIINPUT_ALLOW_UNSAFE_ADHOC=1 ./build.sh
```

可用 `./build.sh --check-stable-dr`（配合上面任一环境变量）连续构建两次并验证代码身份稳定。Codex App 的 “Run (local development)” 动作会明确使用本地 ad-hoc 模式。

## 首次使用

1. **写入 API Key**（GUI App 拿不到 shell 环境变量，故需写入文件）：

   ```bash
   mkdir -p ~/.aiinput
   printf '%s' "$MINIMAX_API_KEY" > ~/.aiinput/key   # 或直接把 key 粘进去
   chmod 600 ~/.aiinput/key
   ```

   App 读取顺序：`~/.aiinput/key` 文件 → 环境变量 `MINIMAX_API_KEY` → 设置页手填。

2. 双击 `AIInput.app` 运行，菜单栏出现书本图标。
3. 到 **系统设置 → 隐私与安全性 → 辅助功能**，勾选 `AIInput`（读取当前输入位置和自动粘贴需要它；全局热键不依赖此权限）。授权后回到 App，菜单中的权限状态会自动刷新。
4. 设置页默认值已正确，一般无需改动：
   - **Base URL**：`https://api.minimaxi.com/anthropic/v1`（MiniMax 的 Anthropic 兼容端点）
   - **模型**：`MiniMax-M3`
   - **API Key**：留空即用 `~/.aiinput/key`；也可在此手填，会同步写回文件。
5. 在 Notes / Safari / VS Code / 任意输入框里按 `Ctrl+⌥+⌘+E`，选择模式与语气，输入内容后按 `Cmd+Return`。普通翻译/润色会直接粘贴；网页结果或无可编辑目标时会进入预览，`⇧⌘C` 可复制。

如果从旧的未正确签名版本升级，需在辅助功能列表中移除旧 `AIInput` 条目、运行新版并授权一次。此后始终使用同一 `AIINPUT_SIGN_IDENTITY`，重新构建不应重复索权。本地 ad-hoc 模式的 requirement 也保持稳定，但不具备证书身份的安全性。

> 接口走 Anthropic Messages 格式：`POST {baseUrl}/messages`，请求头 `x-api-key` + `anthropic-version: 2023-06-01`，body 用 `system` + `messages`。

## 操作

| 操作 | 效果 |
|------|------|
| `Ctrl+⌥+⌘+E` | 唤起 / 关闭面板 |
| `Return` | 组词时由输入法上屏；否则插入换行 |
| `Cmd+Return` | 翻译 / 润色后直接粘贴；分析网页；预览态粘贴或复制 |
| `⇧⌘C` | 预览态：仅复制结果并关闭 |
| `Esc` | 关闭面板（处理中＝取消请求） |
| `↑` | 输入框为空时恢复上次原文 |
| 拖动面板空白处 | 移动面板 |
| 点击面板外 | 自动关闭 |

修改原文或切换模式/语气会自动作废旧结果并取消进行中的请求；输入法正在组词时按 `Cmd+Return` 不会误提交（检测 marked text）。底栏会显示目标应用和实际动作。

## 已知限制

- 剪贴板恢复尽力而为：粘贴前会保存原剪贴板内容，粘贴后写回。复杂的多类型剪贴板内容（如文件引用、富文本多格式）可能不完整恢复。
- 网页模式处理服务端已渲染、无需登录且支持 HTTPS 的文章；纯 JavaScript 页面、登录墙和反爬页面可能无法提取正文。
- 网页抓取会拒绝本机、局域网、链路本地地址和不安全重定向，复验实际连接地址，并在流式下载超过 5 MiB 时停止。
- 本机开发用 ad-hoc requirement 只解决身份稳定，不提供正式分发的证书信任或防冒用能力，必须显式启用。
- 快捷键 v1 固定为 `Ctrl+⌥+⌘+E`，设置页预留改键扩展。
- API Key 文件 `~/.aiinput/key` 仅当前用户可读（600），但仍是明文，请勿提交到版本库。

## 项目结构

```
Sources/AIInput/
├── main.swift              # 入口
├── AppDelegate.swift       # 菜单栏 status item、权限引导、注册热键
├── AccessibilityPermissionManager.swift
├── HotkeyManager.swift     # Carbon 全局热键
├── InputPanel.swift        # Liquid Glass 悬浮 NSPanel + NSTextView
├── PanelPlacement.swift    # 多显示器可见区域定位
├── TransformationModels.swift
├── TransformationPrompt.swift
├── TranslationService.swift# Anthropic Messages 兼容请求
├── WebPageService.swift    # 网页抓取、正文抽取和分块
├── Injector.swift          # 剪贴板替换 + CGEvent Cmd+V + 恢复
├── SettingsWindow.swift    # 设置窗口
└── Config.swift            # UserDefaults 配置读写
```
