<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="180" height="180" />
  <h1>VoiceInk</h1>
  <p>macOS 原生语音转文字应用，几乎可以即时把你说的话转换为文字</p>

  [![许可证](https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF%E8%AF%81-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  ![平台](https://img.shields.io/badge/%E5%B9%B3%E5%8F%B0-macOS%2014.0%2B-brightgreen)
  [![最新版本](https://img.shields.io/github/v/release/bifrost-proxy/VoiceInk?label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC)](https://github.com/bifrost-proxy/VoiceInk/releases)
  ![总下载量](https://img.shields.io/github/downloads/bifrost-proxy/VoiceInk/total?label=%E6%80%BB%E4%B8%8B%E8%BD%BD%E9%87%8F)

  <a href="https://github.com/bifrost-proxy/VoiceInk/releases/latest">
    <img src="https://img.shields.io/badge/%E7%AB%8B%E5%8D%B3%E4%B8%8B%E8%BD%BD-%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC-blue?style=for-the-badge&logo=apple" alt="下载 VoiceInk" width="250"/>
  </a>
</div>

---

VoiceInk 是一款 macOS 原生应用，可以快速将语音转换为文字。本分支完全免费，不包含付费许可证、激活流程或试用限制。

![VoiceInk macOS 应用](https://github.com/user-attachments/assets/12367379-83e7-48a6-b52c-4488a6a04bba)

项目致力于为 macOS 提供高效、注重隐私的语音转文字体验。

## 功能特性

- 🎙️ **准确转写**：使用本地 AI 模型，快速将语音转换为文字
- 🔒 **隐私优先**：支持完全离线处理，音频数据无需离开你的设备
- ⚡ **模式匹配**：根据当前应用或网址自动应用预先配置的转写模式
- 🧠 **上下文感知**：结合屏幕内容理解当前场景并优化输出
- 🎯 **全局快捷键**：可配置快速录音和按住说话等快捷操作
- 📝 **个人词典**：通过自定义词语、专业术语和文字替换提高识别效果
- 🔄 **智能模式**：在针对不同写作风格和使用场景优化的 AI 模式之间快速切换
- 🤖 **AI 助手**：内置语音助手模式，可通过语音进行对话
- ☁️ **豆包流式语音识别**：使用豆包语音 2.0 优化双向流式接口，支持边说边显示识别结果
- ✨ **火山方舟润色**：填写方舟 API Key 与模型或推理接入点 ID，即可使用火山模型润色转写结果

## 中文本地语音模型

在 **AI 模型 → 本地** 中可以直接下载并使用以下中文模型：

- **FunASR SenseVoice Small**：支持普通话、粤语、英语、日语和韩语
- **FunASR Paraformer Large (中文)**：面向普通话优化
- **Qwen3-ASR 0.6B INT8**：通过 sherpa-onnx 在本机推理，支持中文、方言和多语言
- **Qwen3-ASR 0.6B MLX INT8**：Apple Silicon Metal GPU 原生流式量化版本；中文系统首次引导优先推荐，约占用 1.15 GB 常驻内存
- **Qwen3-ASR 0.6B MLX FP16**：独立下载的未量化 Metal GPU 原生流式版本，适合希望保留 FP16 全参数权重的用户
- **sherpa-onnx Zipformer CTC 中文 INT8**：轻量中文模型
- **Parakeet CTC 0.6B zh-CN**：Core ML 中文模型
- **Whisper 多语言系列**：Tiny、Base、Small、Medium、Large v2/v3 和 Large v3 Turbo 均可识别中文；带 `.en` 的模型只支持英语

模型文件只会在用户点击下载后从对应的官方 GitHub Release 或 Hugging Face 仓库获取，下载完成后语音识别在本机执行。若选择云端转写或云端润色，音频或文字才会发送给用户自己配置的服务商。

## 开始使用

### Homebrew 安装（推荐）

通过 Bifrost Proxy 的 Homebrew Tap 安装 VoiceInk：

```shell
brew install --cask bifrost-proxy/voiceink/voiceink
```

Homebrew 的第三方 Cask 单行安装命令必须使用完整的 `owner/tap/cask` 格式。也可以使用下面的两步命令：

```shell
brew tap bifrost-proxy/voiceink
brew install --cask voiceink
```

Homebrew 会先使用版本固定的 SHA-256 校验发布包，再移除 ad-hoc 签名应用的隔离属性，避免首次启动时被 Gatekeeper 拦截。请使用下面的命令升级：

```shell
brew upgrade --cask --greedy voiceink
```

### 直接下载

也可以从 [GitHub Releases](https://github.com/bifrost-proxy/VoiceInk/releases/latest) 下载最新版本。当前社区发布使用 ad-hoc 签名，没有 Apple Developer ID 证书与公证；通过浏览器直接下载时，首次启动需要在“系统设置 → 隐私与安全性”中确认“仍要打开”。

### 豆包流式语音识别

VoiceInk 接入的是豆包流式语音识别模型 2.0，通过官方推荐的优化双向流式 WebSocket 接口边录音边返回文字。接入协议和资源 ID 可查阅[火山引擎大模型流式语音识别 API 文档](https://www.volcengine.com/docs/6561/1354869?lang=zh)。

> **请使用新版豆包语音控制台生成的 API Key。** VoiceInk 的 `AK (API Key)` 输入框只需要填写这一项，不要填写旧版控制台中的 APP ID、Access Token、Secret Key，也不要填写火山引擎访问控制中的 IAM AK/SK。

#### 1. 开通服务并获取 API Key

1. 登录[豆包语音控制台](https://console.volcengine.com/speech/new?projectName=default)，选择要使用的项目；不同项目的服务和密钥相互隔离。
2. 在“开通管理”中开通“流式语音识别大模型”2.0。个人按实际录音时长使用时建议开通小时版；已购买并发配额时可以使用并发版。实际可用额度和计费方式以控制台为准。
3. 打开[API Key 管理](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default)，新建或复制一个 API Key。请不要把真实密钥粘贴到 Issue、日志或截图中。

VoiceInk 提供以下两个资源选项：

| VoiceInk 中的模型 | 火山引擎资源 ID | 适用情况 |
| --- | --- | --- |
| Doubao Streaming ASR 2.0 | `volc.seedasr.sauc.duration` | 2.0 小时版，适合按音频时长使用 |
| Doubao Streaming ASR 2.0 (Concurrent) | `volc.seedasr.sauc.concurrent` | 2.0 并发版，需要账号具有对应并发资源 |

VoiceInk 当前使用小时版资源完成连接验证，因此即使计划使用并发版，也建议先确认账号已开通 2.0 小时版。

#### 2. 在 VoiceInk 中保存并验证密钥

1. 打开 **AI 模型 → 云端**。也可以先选择顶部的 **转写模型** 筛选项。
2. 进入 **Doubao Speech**。
3. 将控制台生成的 API Key 粘贴到 **AK (API Key)** 输入框，点击 **验证**。
4. 出现“API Key 已验证并保存到 macOS 钥匙串”后返回目录，Doubao Speech 应显示为 **已连接**。

API Key 只会加密保存在当前 Mac 的登录钥匙串中，不会写入偏好设置、导出文件或仓库，也不会通过 iCloud 同步。应用的模式等普通配置可能会同步到其他设备，但每台 Mac 都需要单独保存豆包 API Key；缺少密钥时，VoiceInk 会提示前往配置。

#### 3. 在模式中选择豆包转写

1. 打开 **模式**，新建一个模式或编辑现有模式。
2. 在 **转写 → 模型** 中选择 **Doubao Streaming ASR 2.0**；只有开通了并发版资源时才选择带 **Concurrent** 的模型。
3. 豆包模型只能以原生流式方式运行，选择后 VoiceInk 会启用实时转写；语言使用自动识别。
4. 保存模式，将它设为默认模式，或给它配置应用、网站、触发词和快捷键。
5. 开始录音后，悬浮窗会持续显示实时文本；停止录音后会提交尾包并使用最终识别结果。若模式还启用了 AI 润色，原始转写会继续保留，同时显示“正在润色”状态。

如需在悬浮窗中查看实时文字，请确认 **设置 → 实时文本显示** 已开启。VoiceInk 会把“词典”中的非空词条作为本次请求的自定义词汇发送给豆包，以改善专有名词识别。

#### 4. 费用、隐私和时长限制

- 使用豆包云端模型时，麦克风音频会通过加密 WebSocket 实时发送到火山引擎，无法完全离线使用；服务费用由你自己的火山引擎账号承担。
- VoiceInk 默认将单次录音限制为 5 分钟。可在 **设置 → 音频 → 最长录音时长** 中选择 1–10 分钟，达到上限后会自动停止并转写，避免意外长时间录音产生额外费用。
- 关闭或退出 VoiceInk 不会删除已保存的 Key。如需移除密钥，请进入 **AI 模型 → 云端 → Doubao Speech**，点击已保存密钥旁的移除按钮。

#### 5. 常见问题

| 现象 | 检查方法 |
| --- | --- |
| 验证失败 | 确认粘贴的是新版控制台 **API Key**，没有多余空格，并且当前项目已开通豆包流式语音识别模型 2.0 小时版。 |
| 已连接但模式中没有豆包模型 | 返回 AI 模型目录确认 Doubao Speech 显示“已连接”，然后重新打开模式编辑页。 |
| 并发版调用失败 | 确认账号已购买或开通 `volc.seedasr.sauc.concurrent` 对应资源；否则改用小时版模型。 |
| 另一台 Mac 提示未连接 | 这是预期行为。API Key 不进行 iCloud 同步，需要在该 Mac 的 Doubao Speech 页面重新验证并保存。 |
| 没有显示实时文字 | 确认模式选择的是豆包模型，并检查 **设置 → 实时文本显示** 是否开启。 |
| 突然无法调用 | 在火山控制台检查服务状态、余额、用量/并发配额和 API Key 是否仍有效。 |

### 火山方舟

打开 **AI 模型 → 云端 → Volcengine Ark**，然后填写：

- 方舟 API Key
- 模型 ID 或推理接入点 ID，例如 `ep-20250520154305-lz8cg`

VoiceInk 使用火山方舟北京地域固定的 OpenAI 兼容接口，无需配置 Base URL。

### 从源码构建

请参阅[构建指南](BUILDING.md)自行构建 VoiceInk。

## 系统要求

- macOS 14.4 或更高版本

## 文档

- [构建指南](BUILDING.md)：从源码构建项目
- [贡献指南](CONTRIBUTING.md)：参与 VoiceInk 项目
- [行为准则](CODE_OF_CONDUCT.md)：社区行为规范

## 参与贡献

本项目目前**不接受 Pull Request**，但欢迎你 Fork 项目并根据自己的需要进行修改。

你仍然可以通过以下方式参与：

- 通过 [Issues](https://github.com/bifrost-proxy/VoiceInk/issues) 报告问题
- 提交功能建议或改进意见
- 通过 Issue 提出文档改进建议

更多信息请参阅[贡献指南](CONTRIBUTING.md)，构建说明请参阅[构建指南](BUILDING.md)。

## 开源许可证

本项目采用 GNU General Public License v3.0，详情请参阅 [LICENSE](LICENSE)。

## 获取支持

如果遇到问题或有任何疑问，请：

1. 检查仓库中已有的 Issue
2. 如果问题尚未有人报告，请创建新的 Issue
3. 尽可能详细地描述你的运行环境和遇到的问题

## 致谢

### 核心技术

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp)：高性能 Whisper 推理实现
- [FluidAudio](https://github.com/FluidInference/FluidAudio)：用于实现 Parakeet 模型
- [FunASR](https://github.com/modelscope/FunASR)：SenseVoice 与 Paraformer 中文语音模型
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)：Qwen 本地多语言语音识别模型
- [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr)：Qwen3-ASR 的 Apple Silicon Metal GPU 原生流式运行时
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)：Qwen3-ASR 与 Zipformer 的本地 ONNX 推理

### 主要依赖

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)：用户可配置的全局快捷键
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin)：登录时自动启动
- [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter)：录音时控制媒体播放
- [Zip](https://github.com/marmelroy/Zip)：文件压缩与解压缩
- [SelectedTextKit](https://github.com/tisfeng/SelectedTextKit)：获取当前选中文字
- [Swift Atomics](https://github.com/apple/swift-atomics)：提供线程安全所需的底层原子操作

---

本分支由 [bifrost-proxy](https://github.com/bifrost-proxy) 维护。VoiceInk 最初由 Pax 创建。
