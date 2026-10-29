<div align="center">

<img src="TouchMyMac/Assets.xcassets/AppIcon.appiconset/icon.png" width="128" alt="TouchMyMac 图标">

# TouchMyMac

**把 iPad 式的触屏交互带到 macOS。**

[English](README.md) · **简体中文**

[![最新版本](https://img.shields.io/github/v/release/jinghuichen/touchMyMac?style=flat-square&label=release&color=2ea043)](https://github.com/jinghuichen/touchMyMac/releases/latest)
[![下载量](https://img.shields.io/github/downloads/jinghuichen/touchMyMac/total?style=flat-square&color=0969da)](https://github.com/jinghuichen/touchMyMac/releases)
[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-111111?style=flat-square&logo=apple&logoColor=white)](#-安装)
[![Apple 芯片](https://img.shields.io/badge/Apple%20silicon-arm64-555555?style=flat-square)](#-安装)
[![许可证: MIT](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)](LICENSE)
[![Stars](https://img.shields.io/github/stars/jinghuichen/touchMyMac?style=flat-square&color=e3b341)](https://github.com/jinghuichen/touchMyMac/stargazers)
[![最近提交](https://img.shields.io/github/last-commit/jinghuichen/touchMyMac?style=flat-square)](https://github.com/jinghuichen/touchMyMac/commits/main)

[**下载**](https://github.com/jinghuichen/touchMyMac/releases/latest) · [手势](#-手势) · [安装](#-安装) · [常见问题](#-常见问题) · [从源码构建](#-从源码构建)

</div>

TouchMyMac 能把一块外接的 USB 触摸屏变成真正的 macOS 输入设备。它在用户态直接读取 HID 触摸数据，转换成点击、带惯性的滚动、拖拽、多指手势、快捷键和屏幕键盘，用起来不像在用鼠标模拟，而更接近 iPad。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/keyboard-dark.png">
  <img src="docs/images/keyboard-light.png" alt="浮动键盘：完整的 Mac 键盘布局">
</picture>

## ✨ 亮点

| | |
|---|---|
| 👆 **直接触控** | 轻点即点击，拖动即滚动，按住再移动即拖拽，双指轻点即右键。 |
| 🌀 **触控板般的滚动** | 滚动跟随屏幕刷新率，过滤掉触摸抖动，松手后无停顿地转入惯性。 |
| ⌨️ **浮动键盘** | 完整的 Mac 键盘布局，一按就出字，打字再快、手指再重叠也不会漏字。 |
| 🖐 **多指手势** | 调出调度中心、切换桌面、显示或隐藏键盘，四指和五指手势可以绑定自定义快捷键。 |
| 🩺 **诊断工具** | 实时显示连接状态、触摸计数和手势识别结果，方便调校噪声较大的屏幕。 |
| 🔒 **纯用户态** | 不需要内核扩展或额外安装驱动：一个 App，一项辅助功能权限。 |

## 🖐 手势

| 手势 | 功能 |
|---|---|
| 轻点 | 点击（快速点两下为双击） |
| 单指拖动 | 滚动，甩一下会带惯性 |
| 按住片刻再移动 | 拖拽（选中文字、移动窗口和文件） |
| 双指同时轻点 | 右键，和 Mac 触控板一样 |
| 双指捏合 | 缩放 |
| 三指上滑 | 调度中心 |
| 三指左滑 / 右滑 | 切换桌面和全屏 App |
| 四指上滑 / 下滑 | 显示 / 隐藏浮动键盘（在键盘上也能用） |
| 四指左滑 | 快捷键序列（默认 `cmd+a, delete`） |
| 五指按住不动 | 持续按住某个快捷键（默认 `fn`） |

## ⌨️ 浮动键盘

- 完整的 Mac（美式 ANSI）布局，包含数字行、符号和方向键
- 一按就出字（按下后 45 毫秒内，提前抬手则立即出字），每根手指各打各的键，快速打字不漏字
- Shift、Control、Option、Command 为粘滞键，可以打出 ⌘C 这类快捷键；支持 Caps Lock
- 按住 Delete、空格和方向键会连续输入
- 始终浮在所有窗口之上；按住顶部的拖动条或键盘边缘的空白处就能拖动，并会记住你放的位置
- 点隐藏键或四指下滑即可收起，手指放在键盘上下滑也可以
- 隐藏键旁边的按键可以把它缩成 mini 键盘（布局不变，尺寸缩到 60%），并会记住大小

## 🌀 滚动是怎么做的

合成出来的滚动事件很容易让人觉得卡、不跟手，所以 TouchMyMac 参考了手机和触控板的做法：

- **每帧只滚一步。** 触摸报告（常见的是 120Hz 左右）和屏幕帧的节奏对不上，所以按每一帧对手指轨迹重新采样，而不是来一个报告发一次。
- **过滤抖动。** 用 One Euro 滤波：慢速时强力平滑，因为这时触摸噪声和真实位移差不多大；快速时几乎不平滑，避免延迟。
- **离手速度参照 Android。** 对最近 100ms 做二次拟合；如果离手前 40ms 手指已经停住，就不甩出去。
- **无缝衔接惯性。** 惯性从离手速度开始。有的屏幕确认抬手比较晚，这时内容会继续滑行，不会停顿。
- **带触控板的滚动相位**，让各个 App 按触控板滚动来处理这些事件。

## 📦 安装

1. 从 [**Releases**](https://github.com/jinghuichen/touchMyMac/releases/latest) 下载 `TouchMyMac-x.y.z-macOS-unsigned.zip`，解压后把 `TouchMyMac.app` 拖到 `/Applications`。
2. 打开 App。它没有经过公证，第一次打开会被 macOS 拦下：到 **系统设置 → 隐私与安全性**，点 **仍要打开**。
3. 按提示授予 **辅助功能** 权限（系统设置 → 隐私与安全性 → 辅助功能）。TouchMyMac 需要它来发送点击、滚动和按键。
4. 连接触摸屏。如果接了多块显示器，在 **Settings → General → Assign Mouse Events to** 里选中触摸屏。

> [!IMPORTANT]
> 发布的版本是 ad-hoc 签名，macOS 会把每次更新都当成一个新 App。更新之后，请**在辅助功能列表里删掉 TouchMyMac 再重新加回来**，否则即使开关显示为打开，触摸也不会有反应。

> [!NOTE]
> 发布的 zip 是为 Apple 芯片构建的。Intel Mac 可以[从源码构建](#-从源码构建)，但没有测试过。

## ⚙️ 设置

以下选项都在设置窗口里（菜单栏图标 → Settings…）。

| 设置项 | 默认值 | 作用 |
|---|---|---|
| Open at Login | 关 | 登录时自动启动 TouchMyMac（需要 macOS 13 或更高版本） |
| Hold Duration | 0.1 秒 | 停住多久之后再移动，会变成拖拽而不是滚动 |
| Scroll Speed | 1.0 | 手指移动多少，内容就滚多少；1.0 表示内容紧贴手指 |
| Scroll Inertia | 开 | 甩动后继续滚动 |
| Decay Speed | 0.92 | 惯性减速的快慢（越大滑得越久） |
| Inertia Amount | 1.0 | 惯性能滑多远 |
| Double Click Zone | 8 毫米 | 两次轻点相距多近才算双击 |
| Error Resistance | 4 | 对容易丢失触点的屏幕，等多少个报告再判定手指离开 |
| Ignore Origin Touches | 开 | 忽略部分屏幕会发出的 (0, 0) 假触点 |
| 右键 / 缩放 / 调度中心 / 切换桌面 / 键盘 | 开 | 单独开关各个手势 |
| Five-Finger Hold Shortcut | `fn` | 五指按住时持续按下的组合键 |
| Four-Finger Left Swipe Sequence | `cmd+a, delete` | 四指左滑时依次触发的快捷键 |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-dark.png">
  <img src="docs/images/settings-light.png" alt="TouchMyMac 设置窗口">
</picture>

## 🖥 已测试的硬件

| 显示器 | 状态 |
|---|---|
| LG Smart Monitor Swing | ✅ 本分支实测可用 |
| 其他 USB HID 触摸屏 | ❔ 如果在 Windows 上免驱可用，这里大概率也能用；尚未验证 |

在别的屏幕上用起来了？欢迎提 issue 或 PR 把它加到这里。

## ❓ 常见问题

<details>
<summary><b>安装或更新之后，触摸没有任何反应</b></summary>

辅助功能权限缺失或已经失效。在 系统设置 → 隐私与安全性 → 辅助功能 里删掉 TouchMyMac，重新添加 `/Applications/TouchMyMac.app`，然后退出并重新打开 App。
</details>

<details>
<summary><b>macOS 提示 App 已损坏或无法打开</b></summary>

这个版本没有经过公证。到 系统设置 → 隐私与安全性 点 **仍要打开**。如果还是打不开，清除下载时附加的隔离标记：

```bash
xattr -dr com.apple.quarantine /Applications/TouchMyMac.app
```
</details>

<details>
<summary><b>想滚动，结果却选中了内容或拖动了东西</b></summary>

手指放上去后停顿超过 Hold Duration 再移动，就会变成拖拽。起手时早点移动，或者在 Settings → Tuning 里把 Hold Duration 调大。
</details>

<details>
<summary><b>触摸落到了别的显示器上</b></summary>

在 Settings → General → Assign Mouse Events to 里选中触摸屏，TouchMyMac 会记住这个选择。
</details>

<details>
<summary><b>触摸只会移动指针，而且是在指针当前所在的屏幕上</b></summary>

很多为 Windows 设计的触摸屏开机时是单点鼠标模式，要电脑切换后才会发送多点触摸数据。TouchMyMac 现在会像 Windows 一样，在触摸屏连接时完成切换。如果触摸还是只会移动指针，把触摸屏的 USB 线拔掉重插；还不行的话，请附上 `hidutil list` 的输出提个 issue。
</details>

<details>
<summary><b>输入跳动，或者触点卡住不放</b></summary>

把 Error Resistance 调大，并保持 Ignore Origin Touches 打开。Diagnostics 页面会实时显示触摸数量和识别到的手势，方便定位问题。
</details>

## 🛠 从源码构建

```bash
git clone https://github.com/jinghuichen/touchMyMac.git
cd touchMyMac
open TouchMyMac.xcodeproj
```

也可以一步完成构建、安装到 `/Applications` 并启动：

```bash
scripts/build_install_run.sh
```

需要 Xcode 和 macOS 12 或更高版本。

## 🗂 项目结构

```
TouchMyMac/   App：设置界面、菜单栏图标、诊断工具、浮动键盘
Core/         TouchUpCore：HID 解析、触点跟踪、手势识别、事件发送
scripts/      构建并安装的脚本
docs/         README 用到的图片
```

## 🧭 路线图

- [x] 完整 Mac 布局的浮动键盘
- [x] 双指轻点右键
- [x] 跟随屏幕刷新、过滤抖动、惯性无缝衔接的滚动
- [ ] 触控板手势事件，让更多 App 支持左右滑动翻页和边缘回弹
- [ ] 把滚动放到独立线程，主线程忙的时候也不掉帧
- [ ] 签名并公证的发布版本

## 🙏 致谢

TouchMyMac 基于 [Sebastian Hueber](https://hci.rwth-aachen.de/touchup)（亚琛工业大学）原版的 TouchMyMac 和 TouchUpCore。本分支沿用了它的基础，并加入了手势集、快捷键映射、浮动键盘、设置界面和滚动方面的改进。

## 📄 许可证

[MIT](LICENSE) © 2024 Sebastian Hueber, © 2026 Jinghui Chen

## ⭐ Star 趋势

<a href="https://star-history.com/#jinghuichen/touchMyMac&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=jinghuichen/touchMyMac&type=Date&theme=dark">
    <img src="https://api.star-history.com/svg?repos=jinghuichen/touchMyMac&type=Date" alt="Star 趋势图" width="600">
  </picture>
</a>
