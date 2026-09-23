# AIInput

macOS 菜单栏 AI 写作助手：在任意 App 中按 `Ctrl+Option+Cmd+E`，即可翻译或润色选中文字、剪贴板里的文字，或直接输入的内容。

## 特性

- 全局热键 `Ctrl+⌥+⌘+E` 唤起，菜单栏常驻（无 Dock 图标）。
- **结果优先的面板**：原文收成一行引用，结果用大号衬线字体（New York，中文为宋体）逐字流式出现，可以直接修改后再粘贴。
- **翻译 ⇄ 润色** 一键切换（`⇥`）：翻译自动识别中↔英方向（点方向可固定）；润色时左右对照，左边原文、右边结果。
- **常用语气 chips**：忠实、简洁、专业、自然、友好，`⌘1`–`⌘5` 切换，其余语气在「更多」里；出结果后换语气会立即重写。
- **版本**：每次重来、换语气或微调都会保留旧结果，`⌘[` / `⌘]` 在版本间切换，粘贴的是当前看到的那一版。
- **多语气对比**（`⌘K`，仅翻译）：同一段译文按多个语气同时生成，分「常用 / 职场 / 日常 / 书面」四组，每组 2×2 卡片；`⌘←` / `⌘→` 换组，`⌘1`–`⌘4` 选中，`⌘⏎` 直接用选中的替换，再按 `⌘K` 把它带回单个视图。已生成的不会重复请求。
- **修订痕迹**（润色）：删掉的红色删除线、新增的绿色底色，并显示「N 处修改」；`⌘D` 切到干净文字直接编辑，粘贴的始终是干净文字。
- **一键微调**（`⌘L`）：「更短 / 更正式 / 更口语」或自己写一句要求，基于当前结果改写，生成新版本。
- **面板位置**：贴在选中文字或光标下方、不遮挡原文；取不到文字位置时（多数 Electron App）出现在屏幕上方居中。拖动过面板后会按显示器记住位置，菜单栏「重置面板位置」可恢复。
- 原文来源：先取当前 App 的选中文字（读不到时模拟一次 `⌘C` 并立即恢复剪贴板，Electron/网页同样适用），确认后 `⌘⏎` 替换选区；没有选区时用剪贴板里的文字——上次唤起后新复制的会自动开始处理，旧内容只预填并全选，直接打字即可覆盖。密码管理器标记为敏感的剪贴板内容不会读取。
- 未授予辅助功能权限时仍可用剪贴板工作：复制原文 → 唤起 → `⌘⏎` 复制结果，再手动粘贴。
- 设置里的「个人要求 / 术语表」会注入每次请求，例如固定术语译法、拼写习惯。
- 限流/过载（429、5xx、529）和瞬时网络错误在出字前自动重试；错误以可读文字显示在结果区。
- 点击面板外只是隐藏：10 分钟内再次唤起会恢复原文、结果和进行中的请求；`Esc` 才会取消并清空。
- macOS 26 使用原生 Liquid Glass；macOS 13–15 自动回退到系统模糊材质。面板高度随内容伸缩，并根据鼠标所在显示器保持完全可见。
- 调用 MiniMax（Anthropic Messages 兼容接口，流式）；无可编辑目标时只提供复制。

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

打包 DMG（产物在 `dist/`，含拖拽到「应用程序」的快捷方式）：

```bash
AIINPUT_SIGN_IDENTITY="<证书 SHA-1>" ./script/package_dmg.sh
```

没有证书时可用 `AIINPUT_ALLOW_UNSAFE_ADHOC=1 ./script/package_dmg.sh`，但该 DMG 未签名公证，只适合本机安装。

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
5. 在 Notes / Safari / VS Code / 任意输入框里按 `Ctrl+⌥+⌘+E`，输入内容后按 `Cmd+Return`。结果流式出现在预览区，确认后再按 `Cmd+Return` 粘贴；`⌘R` 重来，`⇧⌘C` 复制。

**首次运行（包括从 DMG 安装到「应用程序」后）需要授权一次辅助功能**；之后用同一方式重新构建不会丢失授权。未授权时面板底栏会提示，此时只能用剪贴板作为原文、结果需手动粘贴。同一时间只会保留最新启动的一个 AIInput 实例。

如果从旧的未正确签名版本升级，需在辅助功能列表中移除旧 `AIInput` 条目、运行新版并授权一次。此后始终使用同一 `AIINPUT_SIGN_IDENTITY`，重新构建不应重复索权。本地 ad-hoc 模式的 requirement 也保持稳定，但不具备证书身份的安全性。

> 接口走 Anthropic Messages 格式：`POST {baseUrl}/messages`，请求头 `x-api-key` + `anthropic-version: 2023-06-01`，body 用 `system` + `messages`。

## 操作

| 操作 | 效果 |
|------|------|
| `Ctrl+⌥+⌘+E` | 唤起 / 隐藏面板（隐藏会保留现场） |
| `⌘⏎` | 编辑原文时：翻译 / 润色；有结果时：替换选区或粘贴（无可编辑目标时复制）；失败时：重试 |
| `⇥` | 切换翻译 / 润色 |
| `⌘1`–`⌘5` | 切换常用语气（已有结果时立即重写） |
| `⌘R` | 用当前原文和选项重新生成 |
| `⌘[` / `⌘]` | 切换到上一版 / 下一版结果 |
| `⌘K` | 翻译时：切换单个 / 多语气视图（回到单个时带回选中的卡片） |
| `⌘←` / `⌘→`、`⌘1`–`⌘4` | 多语气视图：切换分组、选中卡片 |
| `⌘D` | 润色结果：显示 / 隐藏修订痕迹 |
| `⌘L` | 有结果时：微调（更短 / 更正式 / 更口语 / 自定义一句话，回车执行，Esc 返回） |
| `⇧⌘C` | 复制结果并关闭 |
| `Esc` | 取消进行中的请求并关闭，下次从空白开始 |
| `↑` | 原文为空时恢复上次原文 |
| 点击原文引用 | 展开编辑原文（修改后旧结果作废） |
| 点击面板外 | 隐藏面板，10 分钟内再唤起可恢复 |

输入法正在组词时按 `⌘⏎` 不会误提交（检测 marked text）。

## 已知限制

- 剪贴板恢复尽力而为：粘贴前会保存原剪贴板内容，粘贴后写回。复杂的多类型剪贴板内容（如文件引用、富文本多格式）可能不完整恢复。
- 本机开发用 ad-hoc requirement 只解决身份稳定，不提供正式分发的证书信任或防冒用能力，必须显式启用。
- 模型可能把原文中“看起来像指令”的句子省略而不是翻译（不会执行它）。
- 没有选区时，少数 App 的 `⌘C` 会复制整行（如 VS Code），此时会把当前行当作选中文字。
- 快捷键 v1 固定为 `Ctrl+⌥+⌘+E`，设置页预留改键扩展。
- API Key 文件 `~/.aiinput/key` 仅当前用户可读（600），但仍是明文，请勿提交到版本库。

## 项目结构

```
Sources/AIInput/
├── main.swift              # 入口
├── AppDelegate.swift       # 菜单栏 status item、权限引导、注册热键
├── AccessibilityPermissionManager.swift
├── SelectionReader.swift   # 辅助功能读取焦点元素与选区状态
├── Clipboard.swift         # 剪贴板快照/读取、⌘C 取选中文字
├── HotkeyManager.swift     # Carbon 全局热键
├── InputPanel.swift        # 悬浮面板外壳：目标解析、读取原文、窗口摆放、粘贴/复制
├── PanelModel.swift        # 面板状态机（阶段、版本、语气、模式），可单测
├── PanelView.swift         # SwiftUI 面板界面与字体
├── ToneBoard.swift         # 多语气分组与并行生成（⌘K）
├── ToneBoardView.swift     # 多语气视图：分组标签 + 2×2 卡片
├── TextDiff.swift          # 润色修订痕迹的逐词对比
├── GrowingTextView.swift   # 自动增高、输入法友好的 NSTextView 包装
├── PanelPlacement.swift    # 多显示器可见区域定位
├── TransformationModels.swift
├── TransformationPrompt.swift
├── TranslationService.swift# Anthropic Messages 兼容请求（流式 + 重试）
├── SSEParser.swift         # 流式响应解析
├── Injector.swift          # 剪贴板替换 + CGEvent Cmd+V + 恢复
├── SettingsWindow.swift    # 设置窗口
└── Config.swift            # UserDefaults 配置读写
```
