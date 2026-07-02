# AI 翻译输入助手

在任意 macOS 程序中按 `Ctrl+Option+Cmd+E` → 弹出悬浮输入框 → 用现有中文输入法输入中文 → AI 译成英文 → 自动粘贴回原程序光标处。

## 特性

- 全局热键 `Ctrl+⌥+⌘+E` 唤起，菜单栏常驻（无 Dock 图标）。
- 悬浮输入框原生支持中文输入法组词（IME 友好）。
- 调用 MiniMax（OpenAI 兼容接口）做中→英翻译。
- 通过剪贴板 + 模拟 `Cmd+V` 注入文本，粘贴后恢复原剪贴板内容。
- 设置页可配置 API Key、Base URL、模型名。

## 构建

需要 Xcode 命令行工具与 Swift 5.9+。

```bash
./build.sh
```

产物为 `AIInput.app`。

## 首次使用

1. **写入 API Key**（GUI App 拿不到 shell 环境变量，故需写入文件）：

   ```bash
   mkdir -p ~/.aiinput
   printf '%s' "$MINIMAX_API_KEY" > ~/.aiinput/key   # 或直接把 key 粘进去
   chmod 600 ~/.aiinput/key
   ```

   App 读取顺序：`~/.aiinput/key` 文件 → 环境变量 `MINIMAX_API_KEY` → 设置页手填。

2. 双击 `AIInput.app` 运行，菜单栏出现书本图标。首次启动会提示需要「辅助功能」权限。
3. 到 **系统设置 → 隐私与安全性 → 辅助功能**，勾选 `AIInput`（全局热键与按键注入都依赖它）。授权后重启 App。**注意**：每次重新构建后签名变化，可能需要先关掉开关再重新打开。
4. 设置页默认值已正确，一般无需改动：
   - **Base URL**：`https://api.minimaxi.com/anthropic/v1`（MiniMax 的 Anthropic 兼容端点）
   - **模型**：`MiniMax-M3`
   - **API Key**：留空即用 `~/.aiinput/key`；也可在此手填，会同步写回文件。
5. 在 Notes / Safari 地址栏 / VS Code / 任意输入框里按 `Ctrl+⌥+⌘+E` → 输入中文 → `Cmd+Return`（或点「翻译」）→ 英文自动粘贴到光标处。

> 接口走 Anthropic Messages 格式：`POST {baseUrl}/messages`，请求头 `x-api-key` + `anthropic-version: 2023-06-01`，body 用 `system` + `messages`。

## 操作

| 操作 | 效果 |
|------|------|
| `Ctrl+⌥+⌘+E` | 唤起 / 关闭输入框 |
| `Return` | 组词时由输入法上屏；否则插入换行 |
| `Cmd+Return` | 提交翻译并粘贴 |
| 点「翻译」按钮 | 同上 |
| `Esc` | 关闭输入框 |

输入法正在组词时按 `Cmd+Return` 不会误提交（检测 markedText）。

## 已知限制

- 剪贴板恢复尽力而为：粘贴前会保存原剪贴板内容，粘贴后写回。复杂的多类型剪贴板内容（如文件引用、富文本多格式）可能不完整恢复。
- 快捷键 v1 固定为 `Ctrl+⌥+⌘+E`，设置页预留改键扩展。
- API Key 文件 `~/.aiinput/key` 仅当前用户可读（600），但仍是明文，请勿提交到版本库。

## 项目结构

```
Sources/AIInput/
├── main.swift              # 入口
├── AppDelegate.swift       # 菜单栏 status item、权限引导、注册热键
├── HotkeyManager.swift     # Carbon 全局热键
├── InputPanel.swift        # 悬浮 NSPanel + NSTextField（IME 友好）
├── TranslationService.swift# MiniMax OpenAI 兼容请求
├── Injector.swift          # 剪贴板替换 + CGEvent Cmd+V + 恢复
├── SettingsWindow.swift    # 设置窗口
└── Config.swift            # UserDefaults 配置读写
```
