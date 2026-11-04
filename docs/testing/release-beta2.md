# 0.1.0-beta.2 / build 42 发布验证

日期：2026-11-04。环境：Intel / macOS 14.7.4。

`FANGCUN_ARCHS='x86_64 arm64' ./scripts/build.sh` 和 `./scripts/package-dmg.sh` 均成功。对最终两份 DMG 验证了映像完整性、只读挂载、应用深度严格签名、主程序与 Rime 的单一架构、版本号、macOS 13 目标、可执行权限、与构建产物一致的全部资源、安装说明和 SHA-256。两份映像均已卸载。

| 回归套件 | 结果 |
| --- | --- |
| core | 通过（1059 项检查记录） |
| credentials | 通过（13 项检查记录） |
| language | 通过（1 项检查记录） |
| double-pinyin | 通过（179 项检查记录） |
| emoji | 通过（540 项检查记录） |
| punctuation | 通过（72 项检查记录） |
| paging | 通过（344 项检查记录） |
| controller | 通过（108 项检查记录） |
| panel | 通过（17 项检查记录） |
| editor | 通过（160 项检查记录） |
| ai-actions | 通过（44 项检查记录） |
| candidate-actions | 通过（32 项检查记录） |
| credential-settings | 通过（7 项检查记录） |
| ai-entry | 通过（14 项检查记录） |
| agent | 通过（40 项检查记录） |
| scratchpad | 通过（41 项检查记录） |

标点回归包含 2,304 个待确认输入场景和 15,779 条断言。AI 回归使用本机 mock 服务，没有请求付费模型。

本轮命令日志位于本地 `.build/release-beta2-*.log`，映像验证结果位于 `.build/release-beta2-dmg-verification.json`；未将日志或本机凭据加入源码。

Apple Silicon 通过交叉编译和包检查，尚未真机运行；macOS 13、新账户首次安装、浏览器下载触发的 Gatekeeper 流程尚未验收。初次发布采用 ad hoc 预览签名；正式签名更新见下文。

## 同日 Developer ID 签名更新

应用代码和 build 保持不变，使用 Developer ID Application: yunxia gao（RCVC2JSJY7）对应用、Rime 动态库及最终 DMG 正式签名，包含安全时间戳。应用和动态库启用 Hardened Runtime，应用仅附加 JavaScriptCore 所需 `com.apple.security.cs.allow-jit` 权限，未禁用动态库验证。

两份 DMG 再次通过原有完整性、挂载签名、架构、资源和摘要检查，并额外核对 Team ID、证书链、安全时间戳与运行时标志。Intel 发行包直接启动本机凭据探针成功。

复制既有测试程序，将 Rime 放入应用 Frameworks 并调整 rpath，使用同一 Developer ID、Hardened Runtime 和权限签名，按每个 suite 独立 mock 服务运行：EditorTests 160 项、CandidateActionTests 32 项、AgentTests 40 项、ScratchpadTests 41 项均通过，覆盖输入、上屏交接、本机命令和文件工具、JavaScriptCore Markdown 及 WebKit 预览。测试日志保存在本机 `.build/signed-smoke-*.log`。

正式签名后的公证更新见下文。完整的新账户首次安装流程仍待验收。

## 同日 Apple 公证更新

复用同一 Apple Developer 团队的既有本机公证凭据，未重新申请证书。四份提交均为 Accepted，Apple 报告的 issues 均为空：

| 架构 | 提交物 | 公证提交 ID |
| --- | --- | --- |
| AppleSilicon | app | `5f8c5baf-39bc-408c-91ec-bc2d3768eca5` |
| AppleSilicon | dmg | `39d9ff19-9212-48e2-b69a-867f0c66dcfd` |
| Intel | app | `7eefd25f-2781-40d9-872b-615dbc25f539` |
| Intel | dmg | `7ffb175d-9482-44cd-bd98-82c78fb5c2e2` |

两份最终 DMG 及挂载后的应用均通过 `stapler validate`，Gatekeeper 的执行／打开评估均返回 `Notarized Developer ID`。最终映像完整性、严格签名、版本、架构、资源、权限、包内说明和 SHA-256 再次通过验证。公证报告和验证日志留在本机 `.build/`，未将公证凭据写入源码。
