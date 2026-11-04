# build 42：临时编辑器与右侧预览

紫色中／英状态图标菜单中，`临时编辑器…` 紧接在 `问问 AI…` 下方。窗口独立于聊天和原来的临时编辑区，复用 Rime 输入及原生 AppKit 文本编辑。主应用菜单也提供同一入口。

- 纯文本编辑：中英切换、中文候选、选区、换行、Tab、撤销/重做、原生查找替换。
- 文件：打开不超过 2 MB 的 UTF-8 文本，复制选区/全文，另存文本。编辑过程不自动覆盖原文件。
- 预览：右侧展开/收起，编辑后自动刷新；按内容或文件扩展名识别 Markdown、HTML、JSON、纯文本，可手动指定。
- Markdown：Marked 18.1.1，支持 GFM 表格、任务列表、引用、代码围栏、行内格式等；库与 MIT 许可证随应用本地打包，不依赖 CDN。
- HTML：静态 HTML 与内联样式。内容脚本关闭，CSP 限制远程资源、文件资源、表单与子页面；自动导航被取消，主动点击 HTTP(S) 链接在浏览器打开。
- 本机恢复：`~/Library/Application Support/FangCun/Scratchpad/draft.json`，目录 0700、文件 0600，保存文字、格式和预览开关。未确认拼音保存为原码，避免自动替用户选字。

快捷键：`⌘F` 查找，`⌘O` 打开，`⌘S` 另存，`⇧⌘P` 切换预览，`⌘W` 收起，`⌘Z` / `⇧⌘Z` 撤销/重做。预览超过 200,000 字时截断显示，文本编辑和保存仍保留全文。

## 验证

`FANGCUN_EDITOR_TEST=ScratchpadTests ./scripts/editor-test.sh`：41 项通过。使用独立临时目录和真实 Rime/WebKit；覆盖菜单顺序与独立回调、格式识别、实际 DOM 与样式、脚本禁用与导航阻止、原生中文输入和撤销、文件导入导出、本机恢复及权限。预览截图：`.build/build42-markdown-preview.png`。

`./scripts/language-indicator-test.sh`：通过，包含新菜单入口与原中／英图标状态验证，不改变系统输入源或焦点。

原有 AIActionTests 44 项、EditorTests 160 项全部通过。快速连续编辑后立即关闭窗口的恢复场景也通过。日志见 `.build/scratchpad-regression-*.log` 与 `.build/scratchpad-tests.log`。

本机已安装 build 42，签名校验通过，安装二进制与构建二进制一致；系统仍只有一个可选方寸输入源。
