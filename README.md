<div align="center">
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
- ☁️ **云端实时转写**：支持豆包语音 2.0 和阿里云 Qwen Audio 3.0，边说边显示识别结果
- 🎧 **云端识别增强**：支持词典热词、上下文提示，以及面向地名、音乐和嘈杂环境的识别优化
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

Homebrew 官方仓库也包含一个同名的 `voiceink` Cask，因此即使已经添加 Tap，安装和升级时仍须使用完整的 `owner/tap/cask` 名称：

```shell
brew tap bifrost-proxy/voiceink
brew install --cask bifrost-proxy/voiceink/voiceink
```

Homebrew 会先使用版本固定的 SHA-256 校验发布包，再移除 ad-hoc 签名应用的隔离属性，避免首次启动时被 Gatekeeper 拦截。请使用下面的命令升级：

```shell
brew upgrade --cask --greedy bifrost-proxy/voiceink/voiceink
```

### 直接下载

也可以从 [GitHub Releases](https://github.com/bifrost-proxy/VoiceInk/releases/latest) 下载最新版本。当前社区发布使用 ad-hoc 签名，没有 Apple Developer ID 证书与公证；通过浏览器直接下载时，首次启动需要在“系统设置 → 隐私与安全性”中确认“仍要打开”。

### 云端实时语音识别

VoiceInk 支持豆包语音 2.0 和阿里云 Qwen Audio 3.0 两种云端实时转写服务。两者都会在录音时持续更新悬浮窗文字，停止录音后再给出最终结果。

| 服务 | 支持的能力 |
| --- | --- |
| **豆包语音 2.0** | 自动识别语言、二遍识别、自动标点、文本规范化、语义顺滑、VoiceInk 词典，以及地名和音乐领域辅助识别 |
| **阿里云 Qwen Audio 3.0** | 多语言和方言识别、自动识别语言、语义分句、VoiceInk 词典、识别上下文，以及安静或嘈杂环境下的分句和降噪调整 |

#### 配置豆包语音 2.0

1. 登录[豆包语音控制台](https://console.volcengine.com/speech/new?projectName=default)，[购买或开通流式语音识别大模型 2.0](https://console.volcengine.com/speech/new/purchase?projectName=default)，并在 [API Key 管理](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default)中创建密钥。
2. 打开 **AI 模型 → 云端 → Doubao Speech**，粘贴 API Key 并点击 **验证**。
3. 打开 **模式**，在 **转写 → 模型** 中选择 **Doubao Streaming ASR 2.0**。如果账号开通了并发版，也可以选择带 **Concurrent** 的模型。
4. 如需加强困难词识别，可在 **识别选项** 中开启二遍识别，然后开启 POI 地图或音乐领域辅助识别。POI 还可以填写一个可选的城市提示。

#### 配置阿里云 Qwen Audio 3.0

1. 登录[阿里云百炼控制台](https://bailian.console.aliyun.com/?tab=model#/api-key)，创建可使用语音识别模型的 API Key。
2. 打开 **AI 模型 → 云端 → Alibaba Cloud Qwen**，选择密钥所属的中国北京或国际新加坡地域。
3. 粘贴 API Key 并点击 **验证**。普通 API Key 可以保留 **API Host** 为空；专属语音输入密钥需要同时粘贴密钥页面显示的 API Host。
4. 打开 **模式**，在 **转写 → 模型** 中选择 **Qwen Audio 3.0 ASR Flash Streaming**。
5. 可在 **识别选项** 中启用 VoiceInk 词典、填写行业术语或前文作为识别上下文，并按使用环境调整语义分句、静音判停和噪声过滤。

阿里云 Qwen Audio 3.0 支持中文、英语、日语、韩语，以及多种东南亚、南亚、中东和欧洲语言。模式中可以直接选择语言，也可以使用自动识别。

#### 开始实时转写

1. 保存模式，并将它设为默认模式，或按应用、网站、触发词和快捷键使用。
2. 确认 **设置 → 实时文本显示** 已开启。
3. 开始录音后，悬浮窗会持续显示识别文字；停止录音后会采用最终结果。若模式还启用了 AI 润色，VoiceInk 会保留原始转写并继续显示润色状态。

#### 费用与隐私

- 云端转写会把录音发送给所选服务商，不能离线使用；费用和用量由你自己的豆包或阿里云账号承担。
- API Key 只保存在当前 Mac 的登录钥匙串中，不会通过 iCloud 同步，因此每台 Mac 都需要单独配置。
- 普通识别选项可以随 VoiceInk 配置同步；POI 城市、阿里云 API Host 和识别上下文仅保存在当前 Mac。
- VoiceInk 默认将单次录音限制为 5 分钟，可在 **设置 → 音频 → 最长录音时长** 中调整。

如果验证失败，请确认密钥所属地域与页面选择一致，并检查对应账号是否已开通服务、仍有可用额度。若模式中没有模型，请先确认服务商在 **AI 模型 → 云端** 中显示为 **已连接**，再重新打开模式编辑页。

### 火山方舟

打开 **AI 模型 → 云端 → Volcengine Ark**，然后填写：

- 方舟 API Key
- 模型 ID 或推理接入点 ID，例如 `ep-20250520154305-lz8cg`

VoiceInk 使用火山方舟北京地域固定的 OpenAI 兼容接口，无需配置 Base URL。

### Codex CLI 润色

已经安装并登录 Codex CLI 的用户可以在 **设置 → AI 模型 → Local CLI** 中载入 **Codex** 模板。VoiceInk 会启动一个共享的 Codex App Server，并在应用运行期间复用该进程；每次润色仍会创建独立的临时会话，避免不同转写内容互相进入上下文。

设置页会读取当前 Codex 账号实际可用的模型和推理强度。短文本润色建议选择 Luna、Mini、Spark 等低延迟模型并使用 **Low** 推理强度；模型可用范围以当前账号返回的目录为准。模型、推理强度、超时时间和执行模式属于普通配置，可通过 VoiceInk 的 iCloud 配置同步；Codex 登录凭据仍由 Codex 自己管理。若 App Server 不可用，可以切回 **Command** 执行方式继续使用自定义命令。

### 从源码构建

请参阅[构建指南](BUILDING.md)自行构建 VoiceInk。

## 系统要求

- macOS 14.4 或更高版本

## 文档

- [模型选择建议](docs/recommended-models.md)：按语言、设备、隐私和延迟选择转写与润色模型
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
