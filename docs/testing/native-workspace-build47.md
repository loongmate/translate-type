# 原生编辑器与问问 AI · build 47

日期：2026-11-18。按照已确认的 [HTML 设计稿](../../design/redesign.html) 实现原生 AppKit 窗口，未将输入控件替换成网页。

## 界面与行为

- 两个窗口共用浅灰白 / 淡紫色、轻量按钮、细分隔线及系统图标。默认跟随系统外观；月亮按钮可切换两个窗口的浅色 / 深色外观，选择保存在本应用偏好中。
- 临时编辑器采用文件工具栏、原生行号与语法着色、编辑 / 预览分栏、底部格式与输入语言状态。保留原有自动识别、Markdown / HTML / JSON / 纯文本、查找替换、打开、另存与自动恢复稿。
- Markdown 继续使用项目自带的完整 GFM 渲染组件，HTML 保持 CSP 和 WebKit 脚本 / 导航限制；预览随窗口外观更新。
- 问问 AI 采用会话侧栏、原生可选消息流、底部持续输入框。工具调用按真实调用 ID 分组，默认折叠；可展开查看状态、参数与结果。AI 回答支持标题、列表、强调、代码样式，以及复制 / 插入。
- 新建对话先停止旧请求和命令，再保留旧会话；切换恢复消息、工具历史、模型来源、工作目录、下一条草稿及参考文字。侧栏显示本次进程使用中的最近会话，最多 8 个，不承诺退出进程后恢复全部历史。会话列表可滚动。
- 输入法选词未完成时禁止新建、切换、执行和插入；原文 / 结果 / 参考文字继续使用现有 Rime 与撤销机制。切换对话清理跨会话的撤销记录，避免撤销恢复其他会话的文字。
- 没有原输入框时仍可提问和复制；插入按钮仅在原有目标校验通过时可用。工具日志、用户消息和未完成回答不能作为结果上屏。

## 验证

本机：Apple Silicon / macOS 27.2.1。本机构建为 arm64，应用版本 0.1.0，build 47。

| 检查 | 结果 |
| --- | --- |
| `FANGCUN_EDITOR_TEST=WorkspaceDesignTests ./scripts/editor-test.sh` | 19 项通过：布局、行号、深色预览、工具折叠与选区隔离、会话草稿 / 目录 / 模型来源恢复、最小窗口、拼音保护和取消隔离 |
| `FANGCUN_EDITOR_TEST=ScratchpadTests ./scripts/editor-test.sh` | 41 项通过：真实 WebKit 预览、中文输入、撤销、格式、安全限制及保存恢复 |
| `FANGCUN_EDITOR_TEST=AIActionTests ./scripts/editor-test.sh` | 44 项通过：问答、改文字、参考资料、选区、复制与插入 |
| `FANGCUN_EDITOR_TEST=AgentTests ./scripts/editor-test.sh` | 40 项通过：流式输出、真实临时目录中的工具执行、停止及原生消息流集成 |
| `./scripts/build.sh` | arm64 构建与本地临时签名验证通过；产物 `build/FangCun.app` |
| `git diff --check` | 通过 |

以上 144 项检查通过。可用 `FANGCUN_EDITOR_TEST=WorkspaceDesignTests ./scripts/editor-test.sh --preview` 打开独立验收程序，菜单快捷键 ⌘1 / ⌘2 切换两个窗口；验收使用临时草稿和示例消息，不覆盖原生应用数据。

另外通过原生 UI 自动化实际点击会话侧栏、工具展开 / 收起、两个窗口切换和外观按钮，确认会话草稿恢复及深色 WebKit 预览。截图为验收程序的真实窗口：

- [临时编辑器 · 浅色](../../design/previews/native-editor-build47.jpg)
- [问问 AI · 浅色](../../design/previews/native-ai-build47.jpg)
- [临时编辑器 · 深色](../../design/previews/native-editor-dark-build47.jpg)
- [问问 AI · 深色](../../design/previews/native-ai-dark-build47.jpg)

## 系统集成测试限制

旧 `EditorTests` 在初始化 `TTInputController` 时，由本机 InputMethodKit 抛出 `unexpected client proxy of class EditorTests.TextClient`，尚未进入编辑器流程。另建仅包含 AppKit、InputMethodKit 与原有 `TextClient` 的最小程序，直接初始化系统 `IMKInputController`，可复现同一异常，不依赖本轮窗口实现。因此不把这组检查标为通过，也不将其当成实际输入法输入失败。

本轮未替换系统中已安装的输入法；现有 44 项 AI 检查覆盖通过原有 `DraftDestination` 向文本客户端插入选中结果。安装后的真实宿主应用输入会话仍需现场验收。构建产物使用本地临时签名，没有重新发布或公证。
