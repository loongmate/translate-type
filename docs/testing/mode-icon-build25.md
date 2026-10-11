# build 25：修复英文模式在系统菜单中不可见

## 问题与修复

build 24 设置 `tsInputModeIsVisibleKey=false`，可见模式排序也只有 `.Hans`。系统当前模式和图标 URL 能变成 `.English` / `InputMenuEnglish-v1.pdf`，但菜单栏仍使用此前可见输入源的标识。用户报告 Shift 后仍显示「方」，新增的菜单栏辅助功能检查在旧安装上复现了这个差异：

```text
PASS: com.translatetype.inputmethod.TranslateType.Hans / InputMenuIcon-v6.pdf
PASS: menu-bar description = 方寸输入法
PASS: com.translatetype.inputmethod.TranslateType.English / InputMenuEnglish-v1.pdf
FAIL: Menu-bar description expected 方寸输入法 · 英文, got ["方寸输入法"]
```

build 25 将 `.English` 设为可见并加入 `tsVisibleInputModeOrderedArrayKey`。保留现有 bundle ID、两种模式 ID 和 Shift 输入逻辑。系统菜单可以展示两种模式，菜单栏仍由系统管理一个指示图标。

Apple SDK 的 `TextServices.h` 将可见性键定义为是否出现在系统界面，将排序数组定义为可见且启用模式的界面顺序。[Google Mozc 的模式声明](https://github.com/google/mozc/blob/master/src/mac/Info.plist) 同样将罗马字母模式列为可见，并纳入模式排序。

## 验证

- 双架构构建（x86_64 / arm64）、签名校验及本机 build 25 安装通过。
- 图标资源检查通过，且新增断言确保安装包的两种模式都声明可见并列入界面排序。
- 模式探针现在区分 TIS 模式/图标元数据、菜单栏辅助功能描述、屏幕像素。没有辅助功能权限时，界面检查明确为 SKIP；不把元数据成功称为实际绘制通过。
- 旧版菜单栏缺陷已由上述辅助功能检查复现。日志：`.build/build24-menu-direct.txt`。
- 新版安装后触发 macOS 钥匙串授权框；它阻止测试窗口成为前台，因此后续探针记录失焦 SKIP，需用户在本机关闭系统授权框后继续。

本轮没有修改拼音引擎或按键处理逻辑。未重新计入 build 24 的 219 项测试结果。
