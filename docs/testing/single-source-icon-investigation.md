# 单入口与中英图标切换调查（2026-10-24）

用户要求同时保留一个系统输入法入口，并在英文状态显示「英」。原生图标的两条实验路径未通过验收，未交付这些实验代码。用户随后明确接受额外占用一个菜单栏位置的独立「方／英」状态图标，随后明确要求语言字样为「中／英」、使用紫色并增加品牌提示。因此 build 39 保留单一系统输入源，并使用独立状态图标显示当前语言。

- 单一 `.Hans` 模式通过 `IMKStateSetting.modes(_:)` 返回不同图标，并重新选择同一个模式：没有观察到系统刷新为英文图标。不能将返回字典正确当作界面成功。[Apple 接口说明](https://developer.apple.com/documentation/inputmethodkit/imkstatesetting/modes%28_%3A%29)。
- 两种可见原生模式，切换时启用目标模式、停用另一模式：`TISDisableInputSource` 返回成功，调用进程内属性变为 disabled；独立进程仍枚举出两个启用入口。原生探针的单入口断言失败，因此不采用这条路径。
- 上一版探针曾把合成 keyDown 经 `NSTextInputContext.handleEvent` 后的 NSTextView 内容当作输入法结果。诊断日志表明这些字母事件未送达 IME；此做法无法验证中文或英文输入。已移除这些文字断言，保留跨进程 Shift、输入源数量、图标元数据及菜单栏辅助功能检查。探针不验证实际菜单栏像素或物理键盘输入。

恢复时 `swift Tests/IconProbe.swift` 独立检查已安装声明和系统注册，确认只有一个启用且可选的方寸入口。后续新增的独立状态图标不注册输入源，仅在选中方寸时出现；控制器及临时编辑区按当前会话状态更新其图像和辅助功能说明。中文显示「中」，英文显示「英」；紫色底、白色字样和右下角方角标以矢量绘制，菜单及悬停说明包含方寸名称。

实验与恢复日志位于 `.build/build37-dynamic-modes.log`、`.build/build37-mode.log`、`.build/icon-investigation-restored.log` 和 `.build/icon-investigation-restored-check.log`。

## build 39 最终验收

- 构建、安装和签名校验通过，安装版本为 39。
- `scripts/language-indicator-test.sh` 通过：使用紫底白字的「中／英」矢量图像，非模板图保留品牌色；中英图像不同，中文恢复同一图像实例；菜单与辅助功能描述同步；未选中时隐藏；不改变系统输入源或焦点。已渲染并检查浅色及深色背景预览 `.build/language-indicator-preview.png`。
- 完整控制器回归通过（`.build/build38-controller.log`）。之后仅修改图标绘制、菜单文案及版本号，未改语言切换逻辑。
- 安装后的跨进程 `scripts/mode-icon-test.sh` 通过（`.build/build39-mode.log`）：两次 Shift 经实际 IME 返回已处理；附加状态图标的辅助功能描述依次为中文、英文、中文；三步均只有一个启用且可选的方寸输入源，原生系统输入菜单名称保持方寸。三步原生菜单与三步状态图标的辅助功能检查全部匹配。未采集实际菜单栏像素。
