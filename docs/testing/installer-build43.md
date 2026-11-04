# build 43：原生自动安装器与 DMG

日期：2026-11-04。环境：Intel / macOS 14.7.4。

## 安装行为

DMG 只暴露 `安装方寸输入法.app` 和说明，输入法 payload 内置在安装器 Resources 中。安装器在当前用户会话运行，无需 sudo，不请求管理员权限；目标为 `~/Library/Input Methods/FangCun.app`。先验证签名及团队，再在旁边 staging 目录复制并再次验证，切换备用输入源、退出确切安装路径中的本产品进程，备份旧应用后替换。注册、启用并检查可选状态，打开已安装应用的设置。

首次安装遇到输入源发现延迟时保留已安装应用并明确提示重新登录。升级发生注册、启用或启动失败时恢复原应用并尝试恢复原输入源。系统级副本、多个旧副本、同名其他产品、符号链接及并发安装会被拒绝，不覆盖其他应用。

## 回归

- `./scripts/installer-test.sh`：28 项通过。真实临时目录文件复制、备份、旧名称迁移、回滚、用户数据保留及并发锁；注册、进程和启动使用测试替身，覆盖失败、传播延迟和需登录分支。实际 AppKit 按钮触发安装流程，验证成功、需登录、失败重试、安装中不可关闭及完成后可关闭。
- 同一测试程序封装为测试应用，使用 Developer ID + Hardened Runtime 签名后再次运行：28 项通过。
- 核心输入：1,059 项通过；设置凭据：7 项通过；语言状态图标回归通过。
- 对最终两个架构的真实 payload，调用生产 `InstallTransaction` 在临时目录复制、验证、重命名为安装目标，签名和公证票据仍有效，Gatekeeper 返回 `Notarized Developer ID`。不修改本机已安装输入法或用户数据。
- Intel 最终 DMG 中的真实安装器直接启动并生成界面截图，检查窗口文案、按钮与版本号。截图保存在本机 `.build/build43-installer.png`。

## 签名、公证与最终包

每种架构的输入法、安装器和 DMG 分别提交 Apple 公证，全部 Accepted，报告无 issues：

| 架构 | 对象 | 公证提交 ID |
| --- | --- | --- |
| AppleSilicon | app | `59b3eaf1-d010-41d3-8979-185910cbdf49` |
| AppleSilicon | installer | `b8abd67c-398e-45e3-ab12-ee1234e4900f` |
| AppleSilicon | dmg | `8dd369bf-03db-4eb7-95fb-0115b9bc212c` |
| Intel | app | `b4a8364d-6175-40f1-933c-c727fe442ed0` |
| Intel | installer | `459ad7df-8fcb-4e14-89e5-b822841a992f` |
| Intel | dmg | `f3303e10-ce70-4148-9910-6a511debb039` |

输入法、安装器和 DMG 票据均通过 `stapler validate`；应用执行与 DMG 打开的 Gatekeeper 评估均为 `Notarized Developer ID`。两份映像通过完整性、签名团队、安全时间戳、Hardened Runtime、版本号、最低系统版本、三个可执行文件的对应单一架构、资源一致性、安装说明和 SHA-256 检查，验证后已卸载。

本地日志：`.build/build43-*.log`；最终包验证：`.build/build43-dmg-verification.json`；公证报告：`.build/notary-build43-*-log.json`。凭据未写入源码。

## 验证边界

没有在全新 macOS 用户账户完成系统注册、重新登录和实际打字的完整安装验收。文件操作与原生界面测试使用真实文件，系统操作故障通过替身覆盖；保留“需要重新登录”结果，不将 API 调用成功当作新账户安装验证。Apple Silicon 通过交叉编译和包检查，尚未真机运行；macOS 13 也尚待实机验证。既有输入行为和 AI 能力测试不代表所有宿主或模型服务。
