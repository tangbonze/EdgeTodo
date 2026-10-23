# 侧边待办 · EdgeTodo

一个常驻屏幕边缘的极简待办工具：平时只在屏幕边缘留一条灰色小拉手，鼠标滑上去（或按 `⌥⌘T`）展开面板，点一下窗口空白处直接写，回车就进 macOS「提醒事项」；在条目上右键可以设提醒时间。支持语音听写——点面板底部的麦克风，说话即成待办，说「提醒我明天十点开会」会自动拆成标题「开会」+ 明天 10:00 的提醒。所有数据都在系统提醒事项里，天然随 iCloud 同步到 iPhone / iPad。

## 下载安装

前往 [Releases](https://github.com/tangbonze/EdgeTodo/releases) 下载最新版 `EdgeTodo-*.dmg`，打开后把 `EdgeTodo.app` 拖进「应用程序」即可。

- **系统要求：macOS 27+**（Apple Silicon，二进制最低版本锁定 27.0，低版本无法启动）
- 首次启动会在菜单栏出现 ☑️ 图标，无 Dock 图标
- 首次使用会弹系统授权：允许「侧边待办」访问提醒事项（读写都走系统提醒事项，iCloud 同步）
- 应用为 ad-hoc 签名，首次打开如被 Gatekeeper 拦截：**右键 → 打开**，或在终端执行
  `xattr -dr com.apple.quarantine /Applications/EdgeTodo.app`

## 界面

- 面板是一张圆角半透明卡片，圆角 26，窗口本身的形状就等于圆角卡片，系统阴影沿着圆角走。
- 控件统一胶囊化：列表选择器是带折叠箭头的胶囊，右下角的刷新是圆形 hover 按钮，到期时间做成带底色的胶囊（今天橙、逾期红）。
- 列表行没有卡片边框，只在 hover 时浮出一层 6% 的浅色；编辑提醒时先压一层 10% 的暗色 scrim，再叠一张卡片。
- 明暗两套自成一体：浅色 +白、深色 +黑，文字一律用语义色，切系统外观不用改任何常量。

> 仓库里不放界面截图 —— 待办条目容易带出私人信息。想看效果直接跑起来，或者用下面的 `demoMode` 开关（假数据已全部换成通用条目）。

## 怎么用

| 操作 | 说明 |
| --- | --- |
| 鼠标滑到边缘的灰色拉手 | 面板弹出；鼠标移开自动收起 |
| 点窗口空白处 | 列表顶部出现一行输入，直接打字 |
| 打字 + `回车` | 立刻创建待办，输入行留着可以接着写下一条 |
| `⌥⌘T` | 显示 / 隐藏面板（显示时直接进入输入状态） |
| 点左侧圆圈 | 标记完成（同步回系统提醒事项） |
| **右键条目** | 设置提醒… / 清除提醒 / 移动到其他列表 / 在提醒事项中打开 / 删除 |
| 点顶部列表名 | 切换要显示的提醒事项列表 |
| `ESC` | 先关提醒编辑框 / 收起草稿行，再收起面板 |
| 拖动灰色拉手 | 沿边缘上下移动位置（会记住） |
| **右键拉手** | 停靠屏幕左侧 / 右侧、位置复位到中间 |
| 菜单栏图标 | 显示隐藏、停靠左/右、位置复位、开机自启、退出 |
| **点底部麦克风** | 开始语音输入：新建一条待办，说的话实时变成文字 |
| 说话时停顿约 2.5 秒 / 再点一次麦克风 | 自动结束听写并保存成提醒 |
| 听写时按 `回车` | 立刻保存当前内容，麦克风同时关闭 |

> 面板是「非激活窗口」：鼠标一旦移进面板本体（约 0.15 秒后）就会把键盘接过来，所以点一下就能直接打字，不需要先点一次激活。只是从边上划过不会抢焦点。

### 输入行里可以直接写时间

在标题里夹一句自然语言，会自动拆成「标题 + 提醒时间」：

```
明天 9:00 交报价单     → 标题「交报价单」，明天 09:00 提醒
今晚 8点 打电话        → 标题「打电话」，今天 20:00
下周一 10:00 例会      → 下周一 10:00
18:00 接孩子           → 今天 18:00（已过则顺延到明天）
后天 整理发票          → 后天 09:00（只给日期默认早 9 点）
四点 复盘              → 支持中文数字（16:00 需手动改）
三点四十 取快递        → 中文分钟也认识（15:40）
十分钟之后 回电话      → 相对时间：从现在 + 10 分钟
```

解析出的提醒时间会实时显示在输入行右侧，不满意就右键条目改。语音输入走的是同一套解析：说「提醒我明天十点开会」，会得到标题「开会」+ 明天 10:00 的提醒，「提醒我 / 帮我记一下」这类口头语会被自动去掉。

## 数据与权限

- 读写的是**系统「提醒事项」**（EventKit），不是自己的私有数据库 —— 在提醒事项 App 或 iPhone 上改的东西，这边会通过 `EKEventStoreChanged` 通知实时刷新。
- 首次启动会弹系统授权：允许「侧边待办」访问提醒事项。拒绝后可以在 `系统设置 › 隐私与安全性 › 提醒事项` 里重新打开；面板里也有「请求授权 / 打开系统设置」按钮。
- 语音听写用 macOS 本地模型（`SFSpeechRecognizer` + `requiresOnDeviceRecognition`），需要麦克风 + 语音识别两项权限；音频只在本机识别。
- 不上传任何数据，没有账号，没有网络请求。

## 自己改 / 重新编译

只依赖命令行工具（Xcode Command Line Tools），不需要 Xcode 工程，也没有第三方依赖：

```bash
git clone https://github.com/tangbonze/EdgeTodo.git
cd EdgeTodo
./build.sh                      # 产出 dist/EdgeTodo.app
cp -R dist/EdgeTodo.app /Applications/   # 覆盖安装
```

- `Sources/App.swift`：面板窗口、边缘悬停轮询、全局快捷键、菜单栏、开机自启
- `Sources/PanelController.swift`：面板 UI（纯 AppKit 手写布局）
- `Sources/Store.swift`：EventKit 读写（提醒事项）
- `Sources/QuickParse.swift`：自然语言时间解析
- `Sources/VoiceInput.swift`：本地语音听写（`SFSpeechRecognizer` + on-device 模型）
- `AppIcon.icns`：图标；`build.sh` 会自动打包 + ad-hoc 签名

**注意**：每次重新编译，二进制的签名指纹就变了，macOS 可能把提醒事项权限视为新应用而需要重新授权（面板会出现授权提示）。日常使用不重新编译就不会受影响。想彻底避免，用自己的开发者证书签名：

```bash
codesign --force --sign "Developer ID Application: 你的名字 (TEAMID)" --options runtime dist/EdgeTodo.app
```

## 已知限制

- 只显示未完成的条目；已完成的需要去「提醒事项」里看。
- 提醒时间用绝对时间（`EKAlarm(absoluteDate:)`），没有做「提前 10 分钟」这类相对闹钟 —— 右键菜单里可以后续扩展。
- 边缘拉手同时就是悬停热区：宽 7pt、长 52pt（可拖动改高度位置），所以只有把鼠标停在拉手上才会展开，不会误触。宽长可在 `App.swift` 里调 `edgeStripWidth` / `edgeStripHeight`。
- 面板固定 380×600，跟随鼠标所在屏幕弹出。
- 语音输入用系统**本地**听写模型（`requiresOnDeviceRecognition`），不联网；需要麦克风 + 语音识别两项权限，首次点麦克风会弹窗。已知坑：部分蓝牙耳机用 `AVAudioEngine` 的 inputNode 收不到声音（换内置麦克风即可）。

## 调试小开关（开发用）

```bash
# 用偏好开关（open 起来的进程也能生效）
defaults write com.tangbonze.edgetodo showOnLaunch -bool YES   # 启动即展开面板
defaults write com.tangbonze.edgetodo demoMode     -bool YES   # 假数据预览样式，不写真实提醒事项
defaults write com.tangbonze.edgetodo freezeHover  -bool YES   # 鼠标离开也不收起，方便截图
defaults write com.tangbonze.edgetodo forceDark    -bool YES   # 强制深色外观
defaults write com.tangbonze.edgetodo forcePermission -bool YES # 预览「需要访问提醒事项」页面

# 用完删掉
defaults delete com.tangbonze.edgetodo showOnLaunch
```

也支持环境变量 `EDGETODO_SHOW=1` / `EDGETODO_DEMO=1`（需直接跑
`dist/EdgeTodo.app/Contents/MacOS/EdgeTodo`）。
