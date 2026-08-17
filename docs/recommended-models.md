# VoiceInk 模型选择建议

VoiceInk 将“语音转写”和“文本润色”作为两个独立阶段。先选择适合语言、设备和隐私要求的转写模型，再按延迟和提示词复杂度选择润色模型。模型目录与服务商能力会变化；应用内显示的可用状态和服务商当前文档始终优先。

## 转写模型

### 中文与方言

| 场景 | 建议模型 | 说明 |
| --- | --- | --- |
| Apple Silicon 日常中文听写 | Qwen3-ASR 0.6B MLX INT8 | Metal GPU 原生流式，兼顾实时反馈和内存占用；首次配置中文环境时优先尝试。 |
| Apple Silicon，希望保留 FP16 权重 | Qwen3-ASR 0.6B MLX FP16 | Metal GPU 原生流式，模型更大、资源占用更高。 |
| CPU 本地推理或不使用 MLX | Qwen3-ASR 0.6B INT8 | sherpa-onnx 量化版本，支持中文、方言和多语言。 |
| 普通话本地转写 | Parakeet CTC 0.6B zh-CN 或 Paraformer Large（中文） | 两者都面向普通话；应使用自己的真实音频比较效果。 |
| 普通话、粤语、英语、日语、韩语混合 | SenseVoice Small | 适合其明确支持的五种语言。 |
| 中文云端实时转写 | Doubao Streaming ASR 2.0 | 原生双向流式；小时版使用 `volc.seedasr.sauc.duration`，已有并发资源时可用 `volc.seedasr.sauc.concurrent`。 |

### 英语和欧洲语言

| 场景 | 建议模型 | 说明 |
| --- | --- | --- |
| 多语言本地实时转写 | Parakeet V3 | 适合英语及其目录中列出的欧洲语言，离线运行。 |
| 仅英语本地实时转写 | Parakeet V2 | 英语专用的本地备选。 |
| 通用本地转写 | Whisper 多语言模型 | Tiny/Base/Small/Medium/Large 系列可识别中文及多种语言；带 `.en` 的模型只支持英语。 |

### 云端备选

AssemblyAI `universal-3-5-pro`、Deepgram `nova-3` 和 ElevenLabs `scribe_v2` 都可作为低延迟云端转写备选。云端模型会把音频发送给对应服务商，并可能产生费用；免费额度、价格和模型名称以服务商当前页面为准。

## 润色模型

润色通常只需要清理口语、补标点、格式化或执行模式提示词，不必默认使用昂贵的旗舰推理模型。优先选择低延迟模型，并用自己的转写样本验证输出是否忠实。

- 已使用火山引擎时，可通过 Volcengine Ark 选择低延迟模型或推理接入点。
- Groq 可先尝试 `openai/gpt-oss-120b`。
- Cerebras 可先尝试 `gpt-oss-120b` 或 `zai-glm-4.7`。
- Gemini 可先尝试 `gemini-3.5-flash`。
- OpenRouter 可用一个 API Key 管理多个模型，适合需要频繁比较模型的情况。
- 已有 OpenAI、Anthropic、Mistral、Ollama、Local CLI 或 OpenAI 兼容服务时，可以直接复用现有配置。

如果润色经常超过约两秒，应先尝试更快的模型或服务商。可在 VoiceInk 的历史记录中选择转写并使用“分析”，或在仪表盘中打开模型洞察，基于实际耗时和结果比较模型。

## 快速选择

1. 中文 Apple Silicon 用户先试 Qwen3-ASR 0.6B MLX INT8；英语或欧洲语言用户先试 Parakeet V3。
2. 本地模型不满足准确率或语言需求时，再比较豆包、AssemblyAI、Deepgram 或 ElevenLabs 等云端实时模型。
3. 润色先选低延迟模型；只有复杂改写确实需要时再提高模型规模或推理强度。
4. 最终选择应使用自己的麦克风、口音、常用词和真实应用场景评测，避免把其他数据集的评分直接当作产品体验。
