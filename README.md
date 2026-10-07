# 键盘下方状态（KeyboardStatus）

在 iOS 系统键盘**底栏**加一排**可用功能按钮**，外加一条（可选）只读状态条。

- 越狱环境：iOS 16 rootless（Dopamine / Relaxin / RootHide 隐根）
- 入口：系统「设置」→「键盘下方状态」

## 功能按钮（默认全开，可单独关）
全选 / 剪切 / 粘贴 / 光标左右移动 / 剪贴板历史 / 快捷短语（可增删、跨 App 共享）/ 收起键盘。

## 智能隐藏（1.3.3 新增，默认开）
输入验证码、密码、纯数字/电话键盘，以及游戏自绘键盘（隐藏输入框）的场景下，工具栏自动不显示；正常打字（QWERTY 文本框）时照常出现。设置里可关。

## 1.3.4 更新
- 新增「文言文」按钮（默认关，设置里开）：选中文字→点「文」→调用已配置的 AI 转成文言文并替换（复用 AI 管线，需先配好 API Key）。
- 修复「全删」清不掉候选字：现在连同未确认的拼音/候选（markedText）一起清，键盘联想条不再残留。
- 修复「快捷短语」删空后默认短语又冒出来：删干净就是空，不再回退默认。

## 状态条（可选，纯显示）
时间 / 电量 / 剪贴板预览 / 网络(WiFi/蜂窝)，约 1 秒刷新一次。

## 安全设计（防 dock 卡死 / 白苹果）
- **只注入普通 App**，明确排除 `SpringBoard` 与 `Preferences`（设置）。
- 全部逻辑包在 `@try/@catch`；任一动作异常都不影响宿主 App。
- 总开关 + 每个功能独立开关，出问题时关总开关即恢复原生键盘。
- 不调用 CoreTelephony 等易崩框架；网络检测用标准 BSD `getifaddrs`。

## 构建 / 发布
- 推送到 GitHub → Actions 自动出 `packages/*.deb`
- 走既有越狱源发布流程（同 超级截图 / 隐私总开关）

## 指定注入的 App
编辑 `layout/Library/MobileSubstrate/DynamicLibraries/KeyboardStatus.plist` 的 Bundles 数组，加入目标 App 的 bundle id 即可。
