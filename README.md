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
- ✨ **火山方舟润色**：填写方舟 API Key 与模型或推理接入点 ID，即可使用火山模型润色转写结果

## 中文本地语音模型

在 **AI 模型 → 本地** 中可以直接下载并使用以下中文模型：

- **FunASR SenseVoice Small**：支持普通话、粤语、英语、日语和韩语；新安装默认使用该模型
- **FunASR Paraformer Large (中文)**：面向普通话优化
- **Qwen3-ASR 0.6B INT8**：通过 sherpa-onnx 在本机推理，支持中文、方言和多语言
- **sherpa-onnx Zipformer CTC 中文 INT8**：轻量中文模型
- **Parakeet CTC 0.6B zh-CN**：Core ML 中文模型
- **Whisper 多语言系列**：Tiny、Base、Small、Medium、Large v2/v3 和 Large v3 Turbo 均可识别中文；带 `.en` 的模型只支持英语

模型文件只会在用户点击下载后从对应的官方 GitHub Release 或 Hugging Face 仓库获取，下载完成后语音识别在本机执行。若选择云端转写或云端润色，音频或文字才会发送给用户自己配置的服务商。

## 开始使用

### 下载

从 [GitHub Releases](https://github.com/bifrost-proxy/VoiceInk/releases/latest) 下载最新版本。

### Homebrew 安装

通过 Bifrost Proxy 的 Homebrew Tap 安装 VoiceInk：

```shell
brew install --cask bifrost-proxy/voiceink/voiceink
```

Homebrew 的第三方 Cask 单行安装命令必须使用完整的 `owner/tap/cask` 格式。也可以使用下面的两步命令：

```shell
brew tap bifrost-proxy/voiceink
brew install --cask voiceink
```

由于该 Tap 始终指向最新的 GitHub Release，请使用下面的命令升级：

```shell
brew upgrade --cask --greedy voiceink
```

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
