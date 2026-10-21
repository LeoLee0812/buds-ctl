<p align="center"><img src="App/Resources/icon.png" width="128" alt="Buds"></p>

<h1 align="center">Buds</h1>

<p align="center">在 Mac 菜单栏里直接控制小米耳机，不用再掏手机开「小米耳机」App</p>

<p align="center">
<img src="https://img.shields.io/badge/macOS-14%2B-lightgrey?style=flat-square&logo=apple" alt="macOS 14+">
<img src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20CoreBluetooth-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
<a href="https://github.com/LeoLee0812/buds-ctl/releases/latest"><img src="https://img.shields.io/github/v/release/LeoLee0812/buds-ctl?style=flat-square" alt="release"></a>
<a href="LICENSE"><img src="https://img.shields.io/github/license/LeoLee0812/buds-ctl?style=flat-square" alt="license"></a>
</p>

## 能做什么

点菜单栏的耳机图标（旁边显示电量），弹出控制面板：

- 左右耳、充电盒电量
- 降噪 / 关闭 / 通透 一键切换
- 降噪强度滑条（轻 ↔ 深）、自适应降噪、个性化降噪
- 通透档位：标准 / 人声增强 / 环境增强
- 音效：默认、人声、低音、高音、音量增强、经典、传奇、低音舒缓、哈曼 AudioEFX、哈曼大师
- 空间音频、头部追踪、音质优先 / 低延迟优先、场景渲染
- 自适应听感、自适应音量、佩戴检测、免唤醒语音、自动接听、双设备连接、智能免摘
- 单击 / 双击 / 三击 / 长按 / 滑动 手势自定义
- 查找耳机（响铃）
- 开机自启

在耳机上长按切模式、摘下戴上，面板会实时跟着变。耳机不支持的功能会自动隐藏。

另附命令行工具 `buds`，方便写脚本或绑快捷键，见下文。

## 下载安装

1. 到 [Releases](https://github.com/LeoLee0812/buds-ctl/releases/latest) 下载 `Buds-x.y.z-macOS.zip`，解压后把 `Buds.app` 拖进「应用程序」。
2. 本 App 没有经过苹果公证，第一次打开会被拦。在终端执行一次：
   ```bash
   xattr -cr /Applications/Buds.app
   ```
   或者在「系统设置 → 隐私与安全性」里点「仍要打开」。
3. 打开后系统会问「Buds 想要使用蓝牙」，点允许。
4. 先在 Mac 的蓝牙设置里连上耳机，菜单栏就会出现耳机图标和电量。

Apple 芯片和 Intel 的 Mac 都能用，需要 macOS 14 及以上。

> 菜单栏图标被刘海挡住时，可以用 [Hidden Bar](https://github.com/dwarvesf/hidden) / [Ice](https://github.com/jordanbaird/Ice) 之类的工具调整，或按住 ⌘ 把图标拖到右边。

## 支持哪些耳机

| 型号 | 状态 |
|---|---|
| Xiaomi Buds 5 Pro（固件 1.5.0.6） | 全部功能实测可用 |
| 其他走「小米耳机」App 的小米 / Redmi 耳机 | 协议相同，**理论上能连**，但没测过 |

其他型号可能碰到的情况：

- 有的老型号只开放经典蓝牙控制通道，没有 BLE 控制服务，在 Mac 上就连不上（面板一直显示「耳机没连上」）。
- 降噪强度的档位每个型号不一样（Buds 5 Pro 是 0~19 共 20 档，有的型号只有 3~4 档），滑条在其他型号上可能对不上。
- 不支持的功能会自动隐藏，但个别功能的取值可能和 Buds 5 Pro 不同。

用其他型号试过的话，欢迎开 Issue 说一下能不能用，最好附上 `buds status -v` 的输出。

## 命令行

```bash
buds status                        # 全部状态
buds anc | buds anc 10 | buds anc deep | buds anc adaptive
buds trans | buds trans voice | buds trans ambient
buds off
buds eq harman                     # default voice bass treble volume classic legend soothing harman harman-master
buds spatial on | buds head on | buds spatial-pref quality
buds scene music                   # off standard music video game book
buds gesture double both next      # single/double/triple/long/swipe  left/right/both  动作
buds cycle both anc,trans,off      # 长按在哪几个模式间循环
buds find both | buds find stop
buds wear-detect on | buds hotword on | buds auto-answer on | buds dual on
buds free-talk 5                   # off 5 10 15 always
buds help                          # 完整说明；加 -v 打印收发的原始字节
```

Release 里的 `buds-cli-x.y.z-macOS.zip` 解压后放进 `PATH` 即可。App 和命令行同时连耳机会抢控制通道，用命令行前先退出 App。

## 从源码编译

只需要 Xcode Command Line Tools（`xcode-select --install`），不需要 Xcode：

```bash
./build.sh            # 本机编译：命令行软链到 ~/.local/bin/buds，App 装到 /Applications/Buds.app
./release.sh 1.0.0    # 打发布包：arm64 + x86_64 通用二进制，输出到 dist/
```

目录结构：

```
Shared/   协议层：认证、帧编解码、BLE 连接（App 和命令行共用）
App/      菜单栏 App（SwiftUI MenuBarExtra）
CLI/      命令行
PROTOCOL.md  协议规格
```

## 原理

- 耳机和手机 App 之间用的是小米 MMA 协议：`FE DC BA` 开头、`EF` 结尾的帧，先做一轮挑战-应答认证，再读写配置。认证算法和基础帧格式移植自 [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) 的 Redmi Buds 实现。
- Gadgetbridge 走经典蓝牙 RFCOMM（服务 UUID `0xFD2D`），这条路在 macOS 上打不开；本项目改走 BLE：服务 `AF00`，写 `AF07`、订阅 `AF08`，帧格式完全相同。
- 各配置项的编号和取值整理自「小米耳机」App 的行为分析，完整规格见 [PROTOCOL.md](PROTOCOL.md)。

## 声明

- 本项目是个人兴趣作品，与小米公司无关，「小米」「Xiaomi」「Redmi」是小米公司的商标。
- 只通过读写耳机自己开放的配置项工作，不修改固件。使用风险自负。

## 许可证

[AGPL-3.0](LICENSE)。认证算法部分移植自 Gadgetbridge（AGPL-3.0），所以本项目沿用同一许可证。
