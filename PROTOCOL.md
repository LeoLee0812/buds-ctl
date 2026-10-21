# Xiaomi Buds 5 Pro（O71）BLE 控制协议规格

> 依据：小米耳机 App `com.mi.earphone 1.25.1` 反编译源码 + HyperOS 系统蓝牙扩展 `com.xiaomi.bluetooth` 反编译源码，**只读代码，未向真机发送任何命令**。
> 每条结论后标注【已确认】（读到了实现代码）或【推测】（代码里只有间接证据 / 需真机验证）。

## 0. 路径缩写与说明

| 缩写 | 实际路径 |
|---|---|
| `E:` | 小米耳机 App（com.mi.earphone 1.25.1）jadx 反编译后的 `sources/` |
| `SDK:` | `E:com/mi/earphone/bluetoothsdk/` |
| `UI:` | `E:com/mi/earphone/settings/ui/` |
| `RCSP:` | `E:com/xiaomi/aivsbluetoothsdk/protocol/rcsp/` |
| `B:` | 小米系统蓝牙扩展（com.xiaomi.bluetooth）jadx 反编译后的 `sources/` |
| `S:` | 单独用 jadx `--show-bad-code` 重新导出的类（原 sources 里该方法反编译失败） |

**型号判定**：VID `0x2717`(10007) + PID `20651/20652/20653/20660` 全部归为内部代号 **O71**；其中 `20653(0x50AD)`/`20660` 是 **O71BT**（普通蓝牙版，就是这副），`20651/20652` 是 **O71Wifi** 版。
来源：`SDK:util/DeviceVidPidTypeUtilsKt.java:105-115` 【已确认】

**关键事实**：App 里绝大多数"这个型号支持哪些功能、降噪有几档"的信息**不是写死在 APK 里**，而是从小米云端按 VID/PID 拉下来的功能列表（`DeviceFunctionWrapper`：`functionId` + `extraInfo` JSON）。APK 的 assets 里没有按型号的功能配置文件（只有 `feedback.json`/`region.json`/lottie）。所以 Buds 5 Pro 的**具体档位数值表无法从本地代码完整还原**，下文会明确标出。
来源：`UI:noise/NoiseReductionVM.java:551`（`reqAllConfig` 从 `device.getFunctionList()` 取 extraInfo）；`unzip -l base.apk | grep assets/` 【已确认】

---

## 1. 帧格式（复核）

```
FE DC BA | flags | opcode | paramLen(2B 大端) | [status] | seq | payload... | EF
```

- 帧头/帧尾常量 `FE DC BA` / `EF`：`E:d6/f.java:119-128` 【已确认】
- `flags` 字节按位解析（`E:d6/f.java:1548-1616` `d0()`，`CHexConver.getBooleanArrayBig` 下标 7 = bit7）【已确认】：
  - bit7 = type：1 = 命令，0 = 响应
  - bit6 = hasResponse：1 = 需要对方回复
  - bit0-2 = targetApp
  - 所以 `C4`=命令+需回复+target4；`04`=响应；`C0`、`C7` 都是"耳机发来的命令且需要回复"，区别只在 targetApp（0 vs 7）。
- 响应包：`paramLen` 后第 1 字节是 status，第 2 字节是 seq；命令包：第 1 字节就是 seq。opcode=0x01 时还多一个 xmOpCode，opcode=0xF1 时多 VID(2)+PID(2)+customOp(1)。`E:d6/f.java:1567-1600` 【已确认】
- status 码：0 成功、1 失败、2 未知命令、3 忙、4 无资源、5 CRC 错、6 全数据 CRC 错、7 参数错、8 回包超限、9 设备不支持、10 部分失败。`E:com/xiaomi/aivsbluetoothsdk/constant/RCSP.java:121-133` 【已确认】

### 1.1 opcode 全表

`E:com/xiaomi/aivsbluetoothsdk/constant/Command.java:8-56` 【已确认】

| opcode | 名称 | 说明 |
|---|---|---|
| 0x01 | CMD_DATA | 透传数据（带 xmOpCode） |
| 0x02 | GET_TARGET_INFO | 设备信息，见 §3.1 |
| 0x03 | REBOOT_DEVICE | 重启（param 0=重启，1=关机，`RCSP.java:91,94`） |
| 0x04 | NOTIFY_DEVICE_APP_INFO | |
| 0x06 | DISCONNECT_CLASSIC_BLUETOOTH | |
| 0x07 | F2A_EDR_STATUS | |
| 0x08 | SET_TARGET_INFO | "运行设置"，见 §2 |
| 0x09 | GET_DEVICE_RUN_INFO | 运行信息，见 §3.2 |
| 0x0A | NOTIFY_COMMUNICATION_WAY | |
| 0x0B | WAKEUP_CLASSIC_BLUETOOTH | |
| 0x0C | NOTIFY_PHONE_VIRTUAL_ADDR | |
| 0x0D | NOTIFY_F2A_BT_OP | |
| 0x0E | REPORT_DEVICE_STATUS | 耳机主动上报，见 §3.3 |
| 0x0F | NOTIFY_DEVICE_UNBOUND / RESET_BT_OP | |
| 0x10 | NOTIFY_A2F_STATUS | |
| 0x30-0x35 | ASR/TTS/NLP | 小爱语音 |
| 0x50 / 0x51 | AUTH_CHECK / AUTH_SEND_CALC_RESULT | 认证 |
| 0xC1-0xC4 | 日志上传 | |
| 0xD0-0xD3 | START/STOP/CANCEL/LONG_HOLD SPEECH | |
| 0xE1-0xE7 | OTA | |
| 0xE8 | LAUNCH_BULK_DATA_TRANSMISSION | |
| 0xF0 / 0xF1 | VENDOR_JIELI_S18 / VENDOR_EXTEND | |
| **0xF2** | **SET_DEVICE_CONFIG** | 见 §4 |
| **0xF3** | **GET_DEVICE_CONFIG** | 见 §4 |
| **0xF4** | **NOTIFY_DEVICE_CONFIG** | 耳机主动推送配置变化，见 §4.3 |
| 0xFA / 0xFB | BLOB_MESSAGE / BLOB_CHUNK_DATA | 大数据块 |

App 对耳机发来的命令按 opcode 分派：0x02→回主机信息，0x0E→电量等状态，0xF4→配置变化。`SDK:devicecmd/DeviceCommandFactory.java:18-28` 【已确认】

---

## 2. opcode 0x08（SET_TARGET_INFO）—— "Vendor TLV" 运行设置

payload 就是一个 Vendor TLV：`[len][type][data...]`，`len = 1 + data 长度`（含 type 字节）。所以 `[02, 04, mode]` 的含义是 "len=2, type=4(降噪), data=mode"。
组包：`SDK:util/VendorDataUtilKt.java:103-115`（`toParam`：`[mLength, mType, datas...]`）；发送：`SDK:setting/helper/SetDeviceConfigHelper.java:84-90`（opcode 8）【已确认】

type 常量：`SDK:constant/VendorTypeConstantKt.java:8-14` 【已确认】

| type（payload 第 2 字节） | 常量名 | data | App 里的实际用法 |
|---|---|---|---|
| 0x00 | TYPE_POWER_SAVE | ? | App 内无调用方 —— **未找到用法** |
| 0x01 | TYPE_SET_FUNCTION_KEY | ? | App 内无调用方 —— **未找到用法** |
| 0x02 | TYPE_HOT_WORLD（语音免唤醒热词） | 1=开 0=关 | `[02 02 01]`。`SDK:setting/function/FunctionConfigImpl.java:87-94`【已确认】。UI：`UI:DeviceSetMoreVM.java:219` |
| 0x03 | TYPE_SUP_POWER_SAVE_NEW | ? | **未找到用法** |
| 0x04 | CMD_SET_NOISE_REDUCTION | 0=关闭 1=降噪 2=通透 | `[02 04 mode]`。`FunctionConfigImpl.java:281-288`；常量 `SDK:setting/function/NoiseLevelConstants.java:19-21`【已确认】 |
| 0x05 | CMD_SET_GB_PLAY_MODE | ? | 常量存在但 App 内无调用方 —— **未找到用法**（名字像"游戏/播放模式"，【推测】） |
| 0x06 | CMD_SET_EAR_DETECTION（佩戴检测开关） | **0=开启，1=关闭**（取反！） | `[02 06 x]`，`x = isOpen ? 0 : 1`。`FunctionConfigImpl.java:307-314`【已确认】 |

> 注意佩戴检测是**反逻辑**：开 = 0x00，关 = 0x01。读回值同理（§3.2 run-info type 0x0A：0=开）。`UI:DeviceSetMoreFragment.java:825-828`（`monitor == 0` 视为开启）【已确认】

---

## 3. 设备信息 / 运行信息 / 状态上报 / F4 的 TLV 含义

三种回包（0x02、0x09、0x0E）的 TLV 格式相同：`[len][type][value(len-1)]`，1 字节 type。

### 3.1 GET_TARGET_INFO（0x02）设备信息

请求 payload：4 字节大端 mask，App 发 `-1` 即 `FF FF FF FF`（全要）。`RCSP:param/GetTargetInfoParam.java:20-21`；`SDK:setting/ota/OtaCommandKt.java:34-36`【已确认】

解析：`E:d6/f.java:1639`（`e0()`，原 sources 反编译失败，完整代码见 `S:d6.f.java` 中 `e0`）【已确认】

| type | 字段 | 解析 | 你的实测 |
|---|---|---|---|
| 0x00 | name | UTF-8 字符串 | |
| 0x01 | 固件版本 | 2 字节：每 4bit 一段 → `a.b.c.d`；4 字节时后 2 字节是 subVersion | |
| 0x02 | quantity | 1 字节电量 | |
| 0x03 | VID+PID | 4 字节：VID(2B 大端) PID(2B 大端) | `27 17 50 AD` |
| 0x04 | — | 跳过 | |
| 0x05 | mandatoryUpgradeFlag | 1=强制升级 | |
| 0x06 | uboot 版本 | 2 字节同版本号编码或 ASCII | |
| 0x07 | mulQuantity 多电量 | N 字节，见 §3.3 电量编码 | |
| 0x08 | codecType | 1 字节 | `02 08 00` → 0 |
| 0x09 | supportPowerMode | 1 字节 | `02 09 00` → 不支持 |
| 0x0A | supportFunctionKey | 1 字节 | `02 0A 01` → 支持 |
| 0x0B | supportHotWord | 1 字节 | `02 0B 01` → 支持语音热词 |
| 0x0C | charsetType | 0=UTF8 1=UTF16 2=Unicode 3=GB2312（`RCSP.java:82-85`） | |
| 0x0D | colorType | 1 字节（机身颜色编号） | `02 0D 02` → 2 |
| 0x0E | spatialAudioType | 1 字节 | `02 0E 03` → 3 |
| 0x0F | virtualSurroundType | 1 字节 | `02 0F 01` → 1 |
| 0x10 | bulkData | 2 字节：[支持情况位图, OTA 包间隔 ms] | |

- spatialAudioType / virtualSurroundType 的数值语义 App 内没有枚举，只是原样转给系统空间音频（`"type,surround"` 字符串）。`SDK:setting/helper/HandleTargetInfoHelper.java:80-88`；`B:com/android/bluetooth/ble/app/headset/L.java:447,499-510`（>0 即广播"设备支持空间音频"）。3 = 支持空间音频的某一级别、1 = 支持虚拟环绕【推测】
- colorType=2 对应哪种颜色：**未找到**映射表（应在云端皮肤配置里）。

### 3.2 GET_DEVICE_RUN_INFO（0x09）运行信息

请求同样是 4 字节 mask `FF FF FF FF`。`RCSP:param/GetDeviceRunInfoParam.java:15-18`【已确认】
解析：`E:d6/f.java:1186-1279`（`b0()`）【已确认】

| type | 字段 | 含义 |
|---|---|---|
| 0x00 | edrAddr | 6 字节经典蓝牙地址 |
| 0x01 | bleAddr | 6 字节 BLE 地址 |
| 0x02 | protocolMtu | 已废弃，App 忽略 |
| 0x03 | edrStatus | 1 字节：0=经典蓝牙未连接 1=已连接（`RCSP.java:123-124`） |
| 0x04 | powerMode | 1 字节：0=普通 1=低功耗（`RCSP.java:92-93`） |
| 0x05 | **vendorData** | 内嵌 Vendor TLV 列表（格式同 §2，`SDK:util/VendorDataUtilKt.java:79-100`）。App 读其中 **type 0x02 = 语音热词开关**（1=开）：`UI:DeviceSetMoreFragment.java:430-438`【已确认】 |
| 0x06 | twsMaster2slave | 1 字节：TWS 主从连接 0=断开 1=已连 |
| 0x07 | deviceVirtualAddress | 4 字节 |
| 0x08 | — | App 不解析；常量表里 8 = `ATTR_TYPE_GET_DONGLE_STATUS`（`RCSP.java:26`）【推测：接收器状态】 |
| 0x09 | **ancStatus** | 1 字节当前降噪模式 0关/1降噪/2通透（与 Gadgetbridge 一致）【已确认解析，值语义按 §2 推得】 |
| 0x0A | **autoPlay = 佩戴检测开关** | 1 字节：**0=开启**，1=关闭。`UI:DeviceSetMoreFragment.java:427-429,825-828`；系统侧同样 `autoPlayStatus==0` 视为开：`B:com/android/bluetooth/ble/app/headset/L.java:370-374`【已确认】 |
| 0x0B | — | App 不解析；常量 11=`ATTR_TYPE_HOTWORD`（`RCSP.java:27`）【推测：热词状态】 |

### 3.3 REPORT_DEVICE_STATUS（0x0E）耳机主动上报

解析：`E:d6/f.java:1466-1523`（`c0()`）；事件分派：`SDK:devicecmd/DeviceNotifyDeviceChangeStrategy.java:26-52`。App 收到后**回一个 status=0 的响应**（OTA 中回 status=3 忙）。【已确认】

| type | 字段 | 含义 |
|---|---|---|
| 0x00 | mulQuantity 电量 | N 字节，按下标：**0=左耳，1=右耳，2=充电盒**（`SDK:setting/helper/HandleTargetInfoHelper.java:113-116`；`E:n2/d.java:84,93`）。每字节：bit7=正在充电，bit0-6=电量百分比；**0xFF=无数据（不在线）**。`SDK:setting/bean/DeviceElectricInfo.java:87-100`【已确认】 |
| 0x01 | twsStatus | 1 字节 |
| 0x02 | localRecord | 1 字节（本地录音状态） |
| 0x04 | ancStatus | 1 字节，当前降噪模式 0/1/2 |
| 0x05 | voiceTypeStatus | N 字节 |
| 0x06 | musicVideoTypeStatus | N 字节 |
| 其他 | — | App 记 "Not Support ATTR type" 后**停止解析剩余部分** |

### 3.4 NOTIFY_DEVICE_CONFIG（0xF4）

payload = 一个或多个 config 记录（格式见 §4.1），与 GET_CONFIG 回包相同。App 用同一个工厂类把每条记录转成对象，并对耳机**回 status=0 响应**（命令对象 type==1 时不回）。`SDK:devicecmd/DeviceNotifyConfigChangeStrategy.java:21-38`【已确认】

系统蓝牙扩展（HyperOS 设置页）对 F4 的 configId 处理更全，表见 §4.4。

#### 你抓到的 F4 通知解码

```
1E | 00 14 | FF 01 02 01 01 15 00 04 01 FF FF 05 0B 20 05 01 01 31 03 00 01 00 02 05 02 0C 01 FF
len  id=0x14  value(28B)
```

- `len=0x1E=30` = 2(id) + 28(value)，符合 §4.1。configId = **0x0014(20)**。【已确认（按 §4.1 格式）】
- App 的工厂里没有 20，落到默认 `BaseCommonDeviceConfig`（只取第 1 字节）——**App 不使用它**。`SDK:setting/bean/BaseDeviceConfigKt.java:144-145`【已确认】
- 系统蓝牙扩展：configId **16~32(0x10~0x20)** 统称 "mma command"，value 首字节是 0xFF 时转成十六进制字符串，作为 HFP 厂商 AT 事件 `+XIAOMI`（911）在系统内部广播。`B:com/android/bluetooth/ble/app/headset/L.java:183-193`【已确认】
- `+XIAOMI` 负载格式（系统解析器 `B:com/android/bluetooth/ble/app/MiuiFastConnectService.java:1719-1892`、`B:com/android/bluetooth/ble/app/headset/BluetoothHeadsetService.java:1261-1376`）：`FF 01 02 | 类别(2B) | 长度 | 子类型 | 数据 | FF`，校验规则 `长度-1 == 总长-8`。【已确认】
  - 你的数据：类别 `01 01`，长度 `0x15`(21)，`21-1 = 28-8 = 20` ✓，子类型 `00`，数据 20 字节 `04 01 FF FF 05 | 0B 20 05 01 01 31 03 00 01 00 02 05 | 02 0C 01`。
  - 数据看起来又是 `[len][type][value]` 小 TLV：type 0x01 = `FF FF 05`；type 0x20 = `05 01 01 31 03 00 01 00 02 05`；type 0x0C = `01`。【推测】
  - 系统只对 "类别 01 01 且 data 内 type==0x0A" 做了处理（佩戴状态：12→双耳佩戴、8/9→单耳、4/6→…）。`MiuiFastConnectService.java:1873-1890`【已确认】；你这条里的 0x01/0x20/0x0C 三项**含义未找到**（多连接/MMA 相关的内部状态）。

---

## 4. SET_CONFIG(0xF2) / GET_CONFIG(0xF3) / NOTIFY_CONFIG(0xF4)

### 4.1 记录格式

```
SET  payload: [len][idHi][idLo][value...]   （可串多条）   len = value长度 + 2
GET  payload: [idHi][idLo] [idHi][idLo] ...   （一次可查多个 id）
回包/F4 payload: [len][idHi][idLo][value...]  （多条首尾相接）
```

- 组包 `getRawData`：`[len, type 2B 大端, value]`，`len = value.length + 2`。`RCSP:data/CommonConfig.java:131-155`；`SDK:setting/bean/BaseDeviceConfig.java:25-29`【已确认】
- 解析 `parseData`：`len=byte0, id=byte1..2, value=len-2 字节`。`CommonConfig.java:166-177`【已确认】
- 例外：id=**0x34(52, BIG_DATA_TRANSFER)** 以 `FF` 开头：`FF | 00 34 | len16(2B) | data`，总长 = len16+5。`CommonConfig.java:88-104,133-139`【已确认】
- GET payload 是 `id` 的 2 字节大端数组。`RCSP:param/GetDeviceConfigParam.java:13-25`【已确认】
- 你已知的 "SET payload `[len,0x00,configId,values]`" = 这里 id 高字节恰好为 0。

### 4.2 configId 完整清单

常量表：`SDK:constant/DeviceConfigIdConstantKt.java:8-53`；GET/F4 回包 → 对象工厂：`SDK:setting/bean/BaseDeviceConfigKt.java:47-149`；SET 封装：`SDK:setting/function/FunctionConfigImpl.java`。
"value" 指 §4.1 里 id 后面的字节。下表除注明外均【已确认】。

| id (hex/dec) | 常量名 | 含义 | SET value | GET / F4 value |
|---|---|---|---|---|
| 0x01 / 1 | CONFIG_AUDIO_MODE | 音频模式 | App 无调用 | — （**未找到用法**） |
| **0x02 / 2** | CONFIG_CUSTOM_CLICK | **手势** | `[手势类型, 左动作, 右动作]`，只改一侧时另一侧填 `FF` | 若干个 3 字节组 `[手势类型, 左, 右]` 顺序拼接 —— 见 §5.3 |
| **0x03 / 3** | CONFIG_AUTO_ANSWER_PHONE | 自动接听 | `[1/0]` | `[1/0]` |
| **0x04 / 4** | CONFIG_MULTIPOINT_CONNECTION | 双设备连接 | `[1/0]` | `[1/0]` |
| 0x05 / 5 | CONFIG_OPEN_COMPACTNESS | 启动佩戴贴合度检测 | `[1]` 开始 | — |
| 0x06 / 6 | CONFIG_COMPACTNESS_LISTENER | 贴合度检测结果 | — | `[左, 右]` 结果（0 未知/1 贴合/2 不贴合，【推测】同 0x3D） |
| **0x07 / 7** | CONFIG_EQ_MODEL | **音效（EQ 预设）** | `[mode]` | `[mode]` —— 见 §5.2 |
| **0x09 / 9** | FIND_DEVICE | **查找耳机（响铃）** | `[state, which]`：state 1=开始响 0=停止；which 1=左 2=右 3=双耳 | 同 |
| **0x0A / 10** | NOISE_MODE_CHOOSE | **长按循环的降噪模式集合** | `[左位图, FF]` 或 `[FF, 右位图]` | `[左位图, 右位图]` —— 见 §5.4 |
| **0x0B / 11** | NOISE_LEVEL_CHOOSE | **降噪/通透 模式+强度** | `[模式, 档位]` | `[模式, 档位]` —— 见 §5.1 |
| **0x0C / 12** | REMIND_LOST | **佩戴/入盒状态**（只读） | — | 1 字节位图：bit3 左耳佩戴、bit2 右耳佩戴、bit1 左耳在盒、bit0 右耳在盒。`SDK:setting/lab/DeviceConfigRemindLost.java:85-89` |
| 0x0D / 13 | DEVICE_CALL_LISTENER | **智能免摘**（说话时自动通透） | `[开关, 恢复秒数]`：UI 选项 0(关)/5/10/15/255(不再恢复)。`SDK:setting/lab/CallListenerConfig.java:37-48`；`UI:DeviceSetMoreFragment.java:130` | 同 |
| 0x14 / 20 | （无名，16~32 区段） | MMA/+XIAOMI 透传状态 | — | 见 §3.4 |
| 0x1D / 29 | SWITCH_SPATIAL_AUDIO | **空间音频开关（写）** | 1 字节位图，见 §5.5 | — |
| 0x1E / 30 | SPATIAL_AUDIO_CONFIG | **空间音频状态（读）** | — | 1 字节位图，同 0x1D |
| 0x21 / 33 | （系统侧）| 头部追踪姿态数据 | — | `[?, yaw f32LE, pitch f32LE, roll f32LE]`。`B:.../headset/L.java:30-36,123-145`【已确认（系统侧）】 |
| 0x22 / 34 | （系统侧）| 环境噪声分贝（听力保护） | — | `[分贝 f32LE...]`，转给 `com.miui.misound` 的听力保护。`L.java:146-156`【已确认（系统侧）】 |
| 0x23 / 35 | （系统侧）| 静默升级开关 | — | `01`=开。`L.java:90,267-277` |
| **0x24 / 36** | CONFIG_VIRTUAL_SURROUND | **虚拟环绕声** | `[1/0]` | `[1/0]` |
| **0x25 / 37** | AUTO_NOISE | **自适应降噪** | `[1/0]` | `[1/0]` |
| 0x27 / 39 | GET_EARPHONE_SN | 序列号（只读） | — | ASCII，忽略 0x00 |
| 0x28 / 40 | DEVICE_TIME | 同步时间 | 4 字节大端 Unix 秒 | — |
| **0x29 / 41** | ADAPTIVE_SENSE | **自适应听感**（依耳道和佩戴调音） | `[1/0]` | `[1/0]` |
| 0x2C / 44 | （系统侧）| SoundID/耳道测听状态 | — | 原样存储。`L.java:235-241` |
| **0x2F / 47** | LOW_LATENCY | **低延迟（游戏）模式** | `[1/0]`（通话中 App 拒绝发送） | `[1/0]` |
| 0x31 / 49 | （系统侧）| 语音识别模式 | — | value[7]==1 开始，否则结束。`L.java:194-207` |
| 0x34 / 52 | BIG_DATA_TRANSFER | 大数据通道（耳道扫描数据等） | 特殊格式，见 §4.1 | value[2]==1 → 耳道扫描数据 |
| **0x36 / 54** | SCENE_RENDERING | **场景渲染**（沉浸声的场景） | 关：`[0]`；开：`[1, 场景]`，场景 1 标准/2 音乐/3 视频/4 游戏/5 听书 | `[开关, 场景]` |
| **0x37 / 55** | CUSTOM_EQ | **自定义 EQ 曲线 / 选择 EQ** | 见 §5.2.2 | 见 §5.2.2 |
| 0x38 / 56 | DONGLE_STATUS | 接收器状态 | — | 0 接收器已连/1 耳机已连/2 断开 |
| 0x3A / 58 | SPATIAL_AUDIO_NOTIFY_SOUND | 空间音频提示音 | `[1/0]` | `[1/0]` |
| **0x3B / 59** | PERSONALIZED_NOISE_REDUCTION | **个性化降噪** | `[1/0]` | `[1/0]` |
| 0x3C / 60 | EAR_CANAL_DETECTION | 启动耳道检测 | `[1]` 开始 /`[0]` | — |
| 0x3D / 61 | EAR_CANAL_EAR_CANAL_FIT | 耳道检测结果 | — | `[左, 右]`：0 未知 / 1 贴合 / 2 不贴合 |
| 0x3E / 62 | EAR_CANAL_DETECTION_EXIST | 是否做过耳道检测 | — | `[1/0]` |
| 0x3F-0x42 / 63-66 | （系统侧 COOLER_*） | 散热器相关，非耳机 | — | — |
| 0x44 / 68 | VOICE_STATUS | 录音状态 | — | `[id, 状态(2录音中/3实时), 来源, 类型, 时长2B]` |
| 0x45 / 69 | VOICE_LIST | 录音列表 | — | `[数量]` + 子 TLV（1 id、3 来源、4 类型、5 时长、7 开始时间、8 长度、9 格式 1mp3/2m4a/3wav/其他ogg） |
| 0x46 / 70 | VOICE_CONFIG | 录音容量 | — | `[总时长2B, 左2B, ?, 右2B]` |
| 0x47 / 71 | EARPHONE_VERSION | 左右耳固件版本 | — | 4 字节，左 2B 右 2B，每 4bit 一段 |
| **0x48 / 72** | ADAPTIVE_VOLUME | **自适应音量** | `[1/0]` | `[1/0]` |
| 0x4A / 74 | BLUETOOTH_INFO | 当前编解码信息（只读） | — | `[场景, 音频类型, 7, int, short, rate]`；rate 的 bit7 与 bit5 同时为 1 ⇒ aptX Adaptive 96k |
| 0x4B / 75 | START_RECORD | 录音/翻译控制 | `[操作, 录音id]`：1 开始录音、2 停止、4 实时、5 面对面翻译 | — |
| 0x4C / 76 | SEND_REGION | 下发 App 地区码 | UTF-8 字符串 | — |
| 0x4D / 77 | DONGLE_MODE | 接收器模式 | 0 无损/1 低延迟/2 无线麦 | 同 |
| 0x4F / 79 | PERSONAL_SPATIAL_AUDIO | 个性化空间音频适配 | 开始 `[1, 总点数, 当前点]`，停止 `[2]` | `[当前点, 点状态]` |
| 0x51-0x53 / 81-83 | DONGLE_MONITOR_* / DONGLE_GESTURE | 接收器相关 | — | — |
| 0x55 / 85 | PERSONAL_SPATIAL_AUDIO_STATUS | 个性化空间音频状态 | — | 1 字节 |
| 0x57 / 87 | PERSONAL_SPATIAL_AUDIO_CONTROL | 个性化空间音频开关 | `[1/0]` | `[1/0]` |
| 0x7E / 126 | （系统侧 MMA 双连接子命令）| | — | `[子命令, 值]`：0=入耳测试模式，1=是否支持语音控制 |
| 0xEEEE / 61166 | LOG_MODE | 日志流 | `[1/0]` | |

各行出处（均【已确认】）：
- 0x02：`SDK:setting/gesture/DeviceConfigClickSet.java:159-272`；`FunctionConfigImpl.java:44-84`
- 0x03/0x04/0x24/0x2F/0x3A/0x48 及其它一字节开关：`FunctionConfigImpl.java:204-250`（`setSwitch`），`SDK:setting/lab/BaseCommonDeviceConfig.java:25-37`
- 0x05/0x06：`SDK:setting/function/DeviceConfigFit.java:35-55`
- 0x07：`FunctionConfigImpl.java:253-258`；`SDK:setting/function/DeviceConfigSoundEffect.java`
- 0x09：`SDK:setting/lab/DeviceConfigFindDevice.java:29-46`；`FunctionConfigImpl.java:35-41`；`UI:finddevice/FindDeviceFragment.java:106-122`；`SDK:setting/lab/FindDeviceConstant.java:9-15`
- 0x0A：`SDK:setting/gesture/DeviceConfigNoiseModeChoose.java:70-149,182-197`
- 0x0B：`SDK:setting/function/DeviceConfigNoiseLevel.java:29-47`；`FunctionConfigImpl.java:97-103`
- 0x1D/0x1E：`SDK:setting/function/DeviceConfigSpatialAudio.java:49-101`
- 0x25：`SDK:setting/function/DeviceConfigAutoNoise.java`；`UI:noise/NoiseReductionVM.java:588`
- 0x29：`SDK:setting/function/DeviceConfigAdaptiveSense.java`；`UI:soundeffect/SoundEffectVM.java:214-229`
- 0x36：`SDK:setting/function/DeviceConfigSceneRendering.java:14-62`
- 0x37：`SDK:setting/function/DeviceConfigCustomEq.java:70-204`
- 0x3B：`SDK:setting/function/DeviceConfigPersonalizedNoiseReduction.java:34-48`
- 0x3C/0x3D/0x3E：`SDK:setting/function/DeviceConfigEarCanalFit.java:42-62`、`DeviceConfigEarCanalDetectionExist.java`
- 0x44-0x46/0x4B：`SDK:setting/function/recordingtranslation/*.java`
- 0x47：`SDK:setting/lab/DeviceConfigVersion.java:124-125`
- 0x4A：`SDK:setting/function/DeviceConfigBluetoothInfo.java:41-52`
- 0x4F/0x55/0x57：`SDK:setting/function/DeviceConfigPersonalSpatialAudio.java:56-83`；`UI:spatialaudio/PersonalAudioVM.java:900-903,1403,1472,1532`
- 系统侧各项：`B:com/android/bluetooth/ble/app/headset/L.java:84-330`

### 4.3 F4 通知要回复

耳机发来的 F4（flags bit6=1）需要回 `04 F4 ... status=00 seq` 的空响应，否则耳机可能重发。`SDK:devicecmd/DeviceNotifyConfigChangeStrategy.java:34-38`【已确认】。0x0E 同理（`DeviceNotifyDeviceChangeStrategy.java:38-39`）。

### 4.4 系统蓝牙扩展对 F4 的分类（补充）

`B:com/android/bluetooth/ble/app/headset/L.java:84-330`【已确认】：
2 手势、3 自动接听、6 贴合度、7 音效、9 查找、11 ANC 档位、12 防丢/佩戴、13 智能免摘、15 抗风噪模式、16~32 MMA 透传、30 空间音频状态、33 头部姿态、34 环境噪声、35 静默升级、37 自适应降噪、41 自适应听感、44 SoundID 状态、49 语音识别、52 大数据、54 场景渲染、72 自适应音量（部分机型复用为相机模式）、78 相机模式、88/100 其他、126 MMA 双连接子命令。

---

## 5. 关键取值详解

### 5.1 降噪 / 通透 强度（0x0B）

value = `[ancState, ancLevel]`。`DeviceConfigNoiseLevel.java:29-47`【已确认】

- `ancState`：0 关闭 / 1 降噪 / 2 通透。`NoiseLevelConstants.java:19-21`【已确认】
- `ancLevel` 的**通用常量**（老机型）`NoiseLevelConstants.java:9-18`【已确认】：

| 模式 | 值 | 中文（res `zh-rCN`） |
|---|---|---|
| 降噪 | 0 | 均衡 |
| 降噪 | 1 | 轻度 |
| 降噪 | 2 | 深度 |
| 降噪 | 3 | 自适应 |
| 降噪 | 4 | 抗风噪 |
| 降噪 | 5 | 深度+ |
| 通透 | 0 | 标准通透 |
| 通透 | 1 | 人声增强 |
| 通透 | 2 | 环境增强 |
| 通透 | 3 | 人声增强+ |

（文字来源：`UI:noise/NoiseReductionVM.java:133-187` 的值→字符串映射 + `aapt2 dump resources base.apk`）

**Buds 5 Pro 的 0x13 是什么**：
- App 并不认为 ancLevel 一定落在 0~5。每个型号可用的档位数组来自云端功能 `1002/1003/1006/1007`（降噪）和 `1004/1005`（通透）的 extraInfo JSON：`{"tws_gear":[...], "auto_fit":..., "anc_wear_type":..., "ota_tws_gear":[{固件版本, 档位数组}]}`。`UI:noise/DeviceNoiseModelKt.java:13-16`；`UI:noise/NoiseExtra.java:23-35`；`NoiseReductionVM.java:189,551`【已确认】
- 读回来的 ancLevel 原样去 `tws_gear` 数组里**按值查下标**来定位滑块；写入时把滑块下标映射回数组里的**原始值**发出。`NoiseReductionVM.java:398`（getLevelProgress）、`628`（setNoiseLevel）【已确认】
- **当 `tws_gear` 长度 > 9 时，UI 切成"轻度 ↔ 深度"连续滑条**（不显示每档文字）。`NoiseReductionVM.java:486`；`UI:noise/NoiseReductionView.java:368-389`【已确认】
- 结论：0x13(19) 是 Buds 5 Pro 云端档位表里的某一个原始档位值，表示一个**连续降噪深度滑条上的某一档**（不是 0~5 那套枚举）【推测：高度可信，因为 0x13 不可能出现在任何本地枚举里，而 App 只有"多档滑条"这一种分支能容纳它】。具体 19 对应第几档、档位范围是多少：**本地代码查不到**，需要真机做"GET 0x0B → 在官方 App 拖动滑条 → 再 GET"抓几组值，或抓 App 访问云端功能列表的 HTTPS 响应。
- 自适应降噪：新机型走单独开关 0x25（`[1/0]`）；只有 L76/L77/K73/K73a/L77s 这些老机型才用"ancLevel=3 表示自适应"。`NoiseReductionVM.java:445,588`【已确认】。O71 不在老机型名单 ⇒ Buds 5 Pro 用 0x25【已确认】。
- 通透档位同理，来自云端 `1004/1005` 的 `tws_gear`；若其值在 0~3 内，含义按上表。【推测】
- 便捷切换：仅切模式（不改档位）用 §2 的 opcode 08 `[02 04 mode]`；同时设模式+档位用 SET 0x0B `[04 00 0B mode level]`。【已确认】

### 5.2 音效 / EQ

#### 5.2.1 EQ 预设（0x07）

value = `[mode]`。值→名称：`SDK:util/SoundEffectType.java:23-36`、`UI:soundeffect/SoundEffectExtKt.java:14-50`；中文取自 res `zh-rCN`【已确认】

| 值 | 常量 | 中文名 |
|---|---|---|
| 0 | DEFAULT | 默认 |
| 1 | HUMAN_VOICE | 人声增强 |
| 2 | ROCK | （无 UI 文案） |
| 3 | CLASSIC | （无 UI 文案） |
| 4 | POPULARITY | （无 UI 文案） |
| 5 | LOW | 低音增强 |
| 6 | HIGH | 高音增强 |
| 7 | VOLUME_BOOST | 音量增强 |
| 10 | CUSTOM | 自定义（曲线在 0x37） |
| 11 | CLASSIC_HEARING_SENSE | 经典听感 |
| 12 | LEGENDARY_HEARING_SENSE | 传奇听感 |
| 13 | SOOTHING_BASS | 低音舒缓 |
| **14 (0x0E)** | **HARMAN** | **Harman AudioEFX（哈曼调音）** |
| 15 | HARMAN_MASTER | 哈曼大师 |

- 你读到的 **0x0E = 哈曼 AudioEFX 音效**【已确认】。
- 这个型号实际显示哪几项由云端 `FUNC_SOUND_SETTINGS_SOUND_MODE(2006)` / `_OTA(2016)` 的 extraInfo 决定（`UI:soundeffect/SoundEffectVM.java:543` requestSupportiveSoundEffects，反编译失败但读得出是从功能列表取）【推测】。
- 设置后 App 会再 GET 一次 0x07 刷新：`SoundEffectVM.java:185-201`【已确认】。
- 空间音频开启时音效模式不可选（res `device_settings_sound_disable`）【已确认】。

#### 5.2.2 自定义 EQ（0x37）

`DeviceConfigCustomEq.java:70-204`；`FunctionConfigImpl.java:106-161,185-201`【已确认】

| 操作 | SET value |
|---|---|
| 选择 EQ 模式 | `[01, mode]` |
| 保存自定义曲线 | `[01, 0A, 01, 01, 01, 00, N, (freqHi freqLo gain) × N]` |
| 重置自定义 | `[04, 01, 01, 01]` |
| 预览曲线（不保存） | `[05, 01, 01, N, (freqHi freqLo gain) × N]` |

- 增益编码：正数直接写；负数写 `128 + |g|`（即 bit7 = 符号）。默认上限 ±10。
- GET/F4 回包：`[01, mode, maxBound(0 视为10), minBound, eqId, eqNameLen, N, (freqHi freqLo gain)×N]`；gain ≥128 时表示 `-(gain-128)`。

### 5.3 手势（0x02）

value 由 3 字节组 `[手势类型, 左耳动作, 右耳动作]` 拼接；GET 可能一次返回全部手势。SET 一次只发一组，不改的一侧填 `0xFF`。`gesture/DeviceConfigClickSet.java:159-272`；`FunctionConfigImpl.java:44-84`【已确认】

**手势类型**（`SDK:setting/gesture/GestureClick.java:23-27`）【已确认】：

| 值 | 手势 |
|---|---|
| 1 | 双击 |
| 2 | 三击 |
| 3 | 长按 |
| 4 | 单击 |
| 5 | 滑动 |

**动作编码**（`SDK:setting/gesture/GestureType.java:19-35`）【已确认】：

| 值 | 动作 |
|---|---|
| 0 | 唤醒小爱 |
| 1 | 播放/暂停 |
| 2 | 上一首 |
| 3 | 下一首 |
| 4 | 音量+ |
| 5 | 音量- |
| 6 | 降噪模式切换（循环集合由 0x0A 决定） |
| 7 | 游戏模式 |
| 8 | 无（取消） |
| 9 | 拍照 |
| 10 | 录音 |
| 11 | 音量调节 |
| 12 | 同传翻译 |
| 0xFF | 本侧不修改（SET 时） |

- 例：右耳长按设为"降噪切换" ⇒ SET `[05 00 02 03 FF 06]`。【已确认（按上述编码拼出）】
- Buds 5 Pro 的长按选项里有"录音/翻译"（O71 专用文案）。`UI:DeviceSettingsFragment.java:456`【已确认】
- 每种手势允许选哪些动作，来自云端功能 4001~4006/4011 的 extraInfo `click_action` 列表，本地查不到具体清单。`UI:gesture/GestureControlViewModel.java:163`；`Function.java:26-32`【已确认（机制）】

### 5.4 长按循环的降噪模式（0x0A）

value = `[左, 右]`，每字节位图：**bit2 = 通透，bit1 = 降噪，bit0 = 关闭**。SET 只改一侧，另一侧 `0xFF`。`DeviceConfigNoiseModeChoose.java:70-149,182-197`【已确认】

- 例：左耳长按在"降噪↔通透"循环 ⇒ `[04 00 0A 06 FF]`。
- UI 规则：云端 `noise_ctrl` 选项多于 2 个时才显示这个设置。`UI:gesture/GestureControlLongPressViewModel.java:97`【已确认】

### 5.5 空间音频（写 0x1D，读 0x1E）

1 字节位图（`DeviceConfigSpatialAudio.java:49-101`）【已确认】：

| bit | 含义 |
|---|---|
| bit0 | 空间音频开关 |
| bit1-2 | 偏好：0 = 高音质，1 = 低延迟（默认 1） |
| bit3 | 头部追踪 |
| bit4 | 虚拟环绕 |

- 例：开空间音频 + 头部追踪 + 低延迟偏好 ⇒ `0b01011 = 0x0B` ⇒ SET `[03 00 1D 0B]`。
- App 读取用 0x1E（`SpatialAudioVM.java:137` 一次 GET `1E 3A 36`），写入用 0x1D（`SpatialAudioVM.java:218`）【已确认】
- O71 在 aptX Adaptive 96k 时不支持开空间音频（App 会拦）。`UI:spatialaudio/SpatialAudioVM.java:159-168`；`UI:spatialaudio/SpatialAudioActivity.java:278`【已确认】
- 系统侧另有一条走 HFP AT 的头部追踪开关：`+XIAOMI: FF01020103020501FF`(开) / `...0500FF`(关)，姿态数据由 F4 configId 0x21 上报。`B:.../headset/BluetoothHeadsetService.java:1515-1521`【已确认】

---

## 6. Buds 5 Pro（O71）功能清单与协议映射

功能 ID 定义：`E:com/mi/earphone/device/manager/export/Function.java:9-57`【已确认】。哪些功能对 O71 打开由云端下发，**本地没有 O71 的功能列表**；下表"O71 是否有"一栏，有代码里针对 O71 的分支/文案的标【已确认】，其他按产品宣传和你实测回包标【推测】。

| 功能 | functionId | 协议命令 | O71 是否有 | 出处 |
|---|---|---|---|---|
| 降噪/通透/关闭 模式 | 1002/1003/1006/1007、1004/1005 | opcode08 `[02 04 m]`；或 SET 0x0B | 有（实测） | §2、§5.1 |
| 降噪/通透强度 | 同上（tws_gear） | SET/GET 0x0B `[mode, level]` | 有（实测 0x13） | §5.1 |
| 自适应降噪 | 1002 等 `auto_fit` | SET 0x25 `[1/0]` | 【推测】有 | `NoiseReductionVM.java:588` |
| 个性化降噪 | 3012 | SET 0x3B `[1/0]`（需先做耳道检测） | 【推测】有 | `NoiseReductionView.java:494,531` |
| 抗风噪 | — | ancLevel=4（老机型）；系统侧 F4 0x0F | 【推测】 | `NoiseLevelConstants.java:10`；`L.java:157-163` |
| 耳道检测 / 贴合度 | 3013 / 3003 | SET 0x3C `[1]` → 结果 0x3D；0x05 → 0x06 | 【推测】有 | §4.2 |
| 音效预设（含哈曼） | 2006/2016 | SET/GET 0x07 | 有（实测 0x0E 哈曼） | §5.2.1 |
| 自定义 EQ | 2006 | SET/GET 0x37 | 【推测】有 | §5.2.2 |
| 自适应听感 | 2008 | SET 0x29 `[1/0]` | 【推测】有 | `SoundEffectVM.java:214` |
| 自适应音量 | 2017 | SET 0x48 `[1/0]` | 【推测】有 | `SoundEffectVM.java:245` |
| 虚拟环绕声 | 2001 | SET 0x24 `[1/0]`（LDAC 开启时无效） | 有（设备信息 0x0F=1） | `SoundEffectVM.java:276` |
| 空间音频 | 2002 | SET 0x1D / GET 0x1E | 有（设备信息 0x0E=3） | §5.5；`SoundEffectVM.java:437-456`（O71BT 不受 LE Audio 限制） |
| 头部追踪 | 2004 | 0x1D 的 bit3；姿态 F4 0x21 | 【推测】有 | §5.5 |
| 空间音频偏好（音质/低延迟） | 2003 | 0x1D 的 bit1-2 | 【推测】有 | §5.5 |
| 空间音频提示音 | 2007 | SET 0x3A `[1/0]` | 【推测】 | `SpatialAudioVM.java:86` |
| 场景渲染 | 2009 | SET 0x36 `[1,场景]`/`[0]` | 【推测】 | §4.2 |
| 个性化空间音频 | 2018 | 0x4F 适配、0x57 开关、0x55 状态 | 【推测】 | `PersonalAudioVM.java` |
| 低延迟游戏模式 | 3011 | SET 0x2F `[1/0]` | 【推测】有 | `UI:DeviceSetMoreVM.java:254` |
| 自动游戏模式 | 3009 | **未找到协议**（App 内无调用方） | ？ | `Function.java:15` |
| 手势自定义 | 4001-4006、4011 | SET/GET 0x02 | 有 | §5.3 |
| 长按降噪循环 | — | SET/GET 0x0A | 有 | §5.4 |
| 录音 / 同传翻译 | 5003 | 0x4B 控制、0x44/0x45/0x46 状态，录音文件走 0x34 大数据通道 | 有（O71 专用文案"录音/翻译"） | `UI:DeviceSettingsFragment.java:447,456` |
| 查找耳机 | 5001 | SET 0x09 `[1, 1/2/3]` 响；`[0, x]` 停 | 有 | §4.2 |
| 佩戴检测 | 3002 | opcode08 `[02 06 (开?0:1)]`；读 run-info 0x0A；状态 F4 0x0C | 有 | §2、§3.2 |
| 自动接听 | 3008 | SET 0x03 `[1/0]` | 【推测】有 | `DeviceSetMoreVM.java:184` |
| 双设备连接 | 3004 | SET 0x04 `[1/0]` | 【推测】有 | `DeviceSetMoreVM.java:295` |
| 语音控制（免唤醒热词） | 3005 | opcode08 `[02 02 1/0]`；读 run-info vendorData type 2 | 有（O71 专用热词文案；设备信息 0x0B=1） | `UI:DeviceSetMoreFragment.java:675-676`；res `device_settings_voice_control_detail_o71` |
| 智能免摘 | 3001 | SET 0x0D `[1, 5/10/15/255]` / `[0,0]` | 【推测】 | `DeviceSetMoreVM.java:576` |
| 通知播报 | 3007 | 手机端读通知；只会配合 opcode08 切降噪模式 | 【推测】 | `UI:notification/DeviceNotificationManager.java:388-400` |
| 听力健康 / 听力保护 | 3006 | **App 内未找到协议**；系统侧有 F4 0x22（环境噪声分贝 → `com.miui.misound`） | 【推测】 | `L.java:146-156` |
| 实验室降噪 | 6001 | opcode08 `[02 04 0/1]` | 【推测】 | `UI:lab/DeviceLaboratoryVM.java:72-89` |
| 固件版本 / 左右耳版本 | 5004 | 设备信息 0x01；GET 0x47 | 有 | §3.1 |
| 序列号 | — | GET 0x27 | 有 | §4.2 |
| 编解码 / aptX Adaptive 96k 识别 | — | GET 0x4A；设备信息 0x08 codecType | 有（O71 有 96k 判断） | `SpatialAudioVM.java:159-168` |
| **LDAC / Hi-Res 开关** | — | **未找到**。App 里没有切换 LDAC 的命令，只在虚拟环绕声说明里提到"打开 LDAC 时此开关无效"；编码选择在 Android 系统蓝牙设置里完成 | — | res `device_settings_sound_virtual_surround_desc` |
| **游戏模式（opcode08 type5）** | — | opcode08 type 0x05 `CMD_SET_GB_PLAY_MODE`，**App 无调用，取值未知** | ？ | `VendorTypeConstantKt.java:9` |
| 皮肤/主题 | 3010 | 纯云端资源，无设备命令 | — | `Function.java:18` |
| 接收器（Dongle）相关 | 7001-7005 | 0x38/0x4D/0x51-0x53 | 否（O71 无接收器）【推测】 | §4.2 |

---

## 7. 实用命令速查（按本规格拼好的帧 payload，未在真机验证）

> 帧外壳：`FE DC BA C4 <op> <lenHi lenLo> <seq> <payload> EF`，`len = payload长度 + 1(seq)`。

| 目的 | op | payload |
|---|---|---|
| 降噪模式 → 降噪 | 08 | `02 04 01` |
| 降噪模式 → 通透 | 08 | `02 04 02` |
| 降噪模式 → 关闭 | 08 | `02 04 00` |
| 读 ANC 模式+强度 | F3 | `00 0B` |
| 设降噪强度为 0x13 | F2 | `04 00 0B 01 13` |
| 读 EQ | F3 | `00 07` |
| EQ → 哈曼 | F2 | `03 00 07 0E` |
| 一次读多项（手势/降噪循环/自适应降噪/低延迟） | F3 | `00 02 00 0A 00 25 00 2F` |
| 开低延迟 | F2 | `03 00 2F 01` |
| 开自适应降噪 | F2 | `03 00 25 01` |
| 开空间音频+头部追踪+低延迟偏好 | F2 | `03 00 1D 0B` |
| 读空间音频状态 | F3 | `00 1E` |
| 双耳响铃找耳机 / 停止 | F2 | `04 00 09 01 03` / `04 00 09 00 03` |
| 关闭佩戴检测 | 08 | `02 06 01` |
| 开启语音热词 | 08 | `02 02 01` |
| 右耳长按 = 降噪切换 | F2 | `05 00 02 03 FF 06` |
| 左耳长按循环 降噪↔通透 | F2 | `04 00 0A 06 FF` |

---

## 8. 未解决 / 需要真机确认的点

1. **降噪强度 0x13 的档位表**（§5.1）：云端下发，本地无。建议在官方 App 里把滑条从最轻拖到最深，每次 GET 0x0B 记录值，即可还原整张表。
2. **通透档位**在 O71 上的实际取值（同上）。
3. **F4 configId 0x14** 内部 type 0x01/0x20/0x0C 的含义（§3.4）。
4. spatialAudioType=3、colorType=2 的枚举含义。
5. opcode08 type 0x00/0x01/0x03/0x05 的取值。
6. "自动游戏模式(3009)"、"听力健康(3006)"在 App 内无设备命令。

---

## 9. 真机补充（2026-10-21，Buds 5 Pro 固件 1.5.0.6）

- **降噪档位表已还原**：App 日志里云端下发的功能 1002 `extraInfo` 是 `{"auto_fit":1, "tws_gear":[0..19], "anc_wear_type":2}`，即降噪强度是 0~19 共 20 档的连续滑条（界面"轻度↔深度"），实测 0x13 = 19 = 最深；通透（功能 1005）`tws_gear` 是 `[0,1,2]` = 标准 / 人声增强 / 环境增强。
- 实测**有回应**的 configId：02 03 04 07 0A 0B 0C 0D 1E 25 27 29 36 3A 3B 47 48 4A；**没有回应**（这副耳机不支持）：24 虚拟环绕、2F 低延迟游戏模式、3D、3E。
- 实测写入生效：0x0B 强度、0x07 音效、0x1D 空间音频各位（开关 / 头部追踪 / 偏好）、0x36 场景渲染、0x29、0x48、0x3B、0x25、0x02 手势、0x0A 长按循环、0x03、0x04、0x0D，以及 opcode 08 的 02（热词）、04（模式）、06（佩戴检测）。
- opcode 08 切模式后要等约 0.5 秒，运行信息里的模式才会变。
