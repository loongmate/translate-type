# build 24：系统输入菜单的中英文图标

## 行为

普通应用输入框中，方寸的中文输入显示原有「方」图标，英文直输显示同样样式的「英」图标。Shift、候选窗语言按钮和输入法菜单使用同一份输入状态，刷新时同步系统模式。切换到其他输入法再选择方寸的常规入口，恢复中文和「方」。

保留既有 bundle ID 和 `.Hans` 模式，新增同一 bundle 下的内部 `.English` 模式。英文模式 `tsInputModeIsVisibleKey=false`，不出现在用户可选输入源列表。通过 SDK 中 `IMKTextInput.selectMode(_:)` 切换它，处理 `IMKStateSetting.setValue(_:forTag:client:)` 接收的模式回调；不增加 NSStatusItem，不重写图标文件，不修改其他输入法或系统输入菜单设置。

实际探针确认：通过 IMK 客户端切换，系统当前输入源和对应的图标 URL 都随之变化。曾在首次注册时观察到 TIS 的启用状态尚未刷新，单独使用 `TISSelectInputSource` 返回成功却没有切换，因此不以函数返回值代替实际模式验收。安装流程启用内部英文模式，其 UI 可见性仍由模式声明控制。更新安装时如原本为内部英文模式，会恢复到正常方寸中文入口，可继续用 Shift 切换。

临时编辑区各文本字段有独立语言状态，仍以字段自身的语言按钮和候选窗为准；此处系统图标表示普通宿主输入会话的模式。

## 验证方法与边界

- `./scripts/controller-test.sh`：真实 Rime、IMK 控制器和 NSTextView，检查切换输入、请求正确的原生图标模式、回调不会递归、模式往返保留中文草稿，以及先收到模式再激活的控制器仍响应拼音方案变化。
- `./scripts/editor-test.sh`：回归临时编辑区、保留草稿和异步宿主上屏。
- `FANGCUN_EDITOR_TEST=AIActionTests ./scripts/editor-test.sh`：回归改文字、问 AI 和局部结果上屏。
- `swift Tests/IconProbe.swift`：读取系统实际注册的中文/英文图标 URL，并用 AppKit 渲染、检查内容非空，输出本地 `.build/system-menu-icon.png` 和 `.build/system-menu-english.png`。
- `./scripts/mode-icon-test.sh`：启动自己的原生文本窗口，向该窗口的 NSTextInputContext 传入 Shift 的 flagsChanged；通过已安装输入法的跨进程连接，检查系统实际选中的 `.Hans → .English → .Hans` 及三次对应图标 URL。只操作测试窗口，完成后恢复此前输入源。

模式探针能验证原生输入会话和系统图标联动，不是物理键盘端到端打字验收。曾在一次临时探针中尝试通过同样方式合成字母事件，AppKit 直接插入了字母而没有拼音转换，因此没有用这条路径声称验证了真实中文打字。文本与草稿保护以控制器和编辑区回归为依据。

图标资源为 16 pt 模板 PDF，系统可按菜单栏明暗外观着色；安装器保持单一 FangCun.app 安装。

## 本轮结果（2026-10-11）

| 检查 | 结果 |
| --- | --- |
| 控制器、模式回调及草稿保护 | 40 / 40 |
| 编辑区与宿主交接 | 129 / 129 |
| AI 动作与问答 | 50 / 50 |
| 上述自动回归合计 | 219 / 219 |
| 已安装输入法的跨进程模式/图标切换 | 方 → 英 → 方，三次模式及图标 URL 均匹配 |
| 系统图标资源 | 父输入法、中文、英文三项加载与可见内容检查通过 |
| 构建 | Apple Silicon / Intel 均通过 |

最初一次正式图标探针未获得焦点，明确返回 SKIP。探针增加一次重新聚焦自己的测试窗口后通过；仍在失焦时停止，不向用户其他窗口投递事件。测试前的输入偏好已恢复。

最终 build 24 已安装并启动。再次安装后的探针曾遇到首次 Shift 未返回已处理，随后几次运行未取得前台焦点（active=false、key=false），明确记录为失败/跳过，没有计为通过。探针现在显式激活自己的输入上下文、留出连接建立时间，并以实际系统模式和图标作为断言，不以同步 handleEvent 返回值代替结果。上表原生模式结果来自此前已完成的正式探针；最终安装后的重复检查仍需在测试窗口能获得焦点时重跑。对应日志在 `.build/build24-mode-icon-initial-activation.log` 和 `.build/build24-mode-icon.log`。
