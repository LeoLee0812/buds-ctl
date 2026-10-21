# buds-ctl

![platform](https://img.shields.io/badge/platform-macOS-lightgrey?style=flat-square&logo=apple)
![swift](https://img.shields.io/badge/Swift-CoreBluetooth-F05138?style=flat-square&logo=swift&logoColor=white)
![last commit](https://img.shields.io/github/last-commit/LeoLee0812/buds-ctl?style=flat-square)

在 Mac 上直接控制小米耳机（Xiaomi Buds 5 Pro 实测），不用掏手机开「小米耳机」App。

## 能做什么

| 功能 | 命令 |
|---|---|
| 全部状态（电量、佩戴、降噪、音效、空间音频、手势……） | `buds status` |
| 降噪 / 强度 0~19 / 自适应 | `buds anc`、`buds anc 10`、`buds anc deep`、`buds anc adaptive` |
| 通透 / 人声增强 / 环境增强 | `buds trans`、`buds trans voice`、`buds trans ambient` |
| 关闭降噪和通透 | `buds off` |
| 个性化降噪 | `buds personal-anc on` |
| 音效预设（含哈曼） | `buds eq harman`、`buds eq bass` …… |
| 空间音频 / 头部追踪 / 音质或低延迟偏好 | `buds spatial on`、`buds head on`、`buds spatial-pref quality` |
| 场景渲染 | `buds scene music`（standard/music/video/game/book/off） |
| 自适应听感 / 自适应音量 | `buds adaptive-sense on`、`buds adaptive-volume on` |
| 手势 | `buds gesture double both next`、`buds gesture single left play` |
| 长按在哪几个模式间循环 | `buds cycle both anc,trans,off` |
| 查找耳机（响铃） | `buds find both`、`buds find stop` |
| 佩戴检测 / 免唤醒语音 / 自动接听 / 双设备连接 | `buds wear-detect on`、`buds hotword on`、`buds auto-answer on`、`buds dual on` |
| 智能免摘 | `buds free-talk 5`（off/5/10/15/always） |

所有命令执行完都会打印一遍最新状态。加 `-v` 可看收发的原始字节。

## 安装

```bash
./build.sh   # 编译并软链到 ~/.local/bin/buds
```

前提：耳机已经连在这台 Mac 上；第一次运行时终端要有蓝牙权限。

## 原理

- 耳机和手机 App 之间用的是小米 MMA 协议：`FE DC BA` 开头、`EF` 结尾的帧，先做一轮挑战-应答认证，再读写配置。认证算法和基础帧格式参考了 [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) 的 Redmi Buds 实现。
- Gadgetbridge 走经典蓝牙 RFCOMM（服务 UUID `0xFD2D`），这条路在 macOS 上打不开；本工具改走 BLE：服务 `AF00`，写 `AF07`、订阅 `AF08`，帧格式完全相同。
- 各配置项编号和取值是从「小米耳机」App 1.25.1 逆向出来的，降噪档位表（0~19）来自 App 日志里云端下发的 `tws_gear`。完整规格见 [PROTOCOL.md](PROTOCOL.md)。

## 已知限制

- 只在 Xiaomi Buds 5 Pro（固件 1.5.0.6）上实测；其他小米 / Redmi 耳机协议相同，但支持的功能和取值可能不同。
- 查找耳机会在耳朵里响铃，没有实测。
- LDAC / 高清音质、听力健康这几项 App 里没有对应的耳机命令，没法做。
