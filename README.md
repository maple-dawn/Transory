# Transory

macOS 上的多模型 AI 翻译工具。Swift 6 + SwiftUI，最低 macOS 14。

## 运行

```bash
swift run Transory        # 开发时直接运行
swift test                # 单元测试
./scripts/bundle.sh       # 打包成 build/Transory.app
```

也可以用 Xcode 直接打开 `Package.swift`。

首次运行后在「设置 › 模型服务」里填 API Key 和模型名，点「测试连接」确认可用。

## 结构

```
Sources/
  TransoryCore/            与 UI 无关的核心逻辑
    Models/                语言、风格、翻译请求、服务商配置
    Networking/            HTTP 传输层 + SSE 解析
    Providers/             模型适配器
      TranslationProvider    统一协议 + 工厂
      OpenAICompatible       OpenAI / DeepSeek / Ollama / 任意兼容接口
      Anthropic              Claude（Messages API）
      Gemini                 Google Gemini
    Prompt/                提示词模板
    Translation/           多模型并发对比
    Storage/               钥匙串存储 API Key
  Transory/                SwiftUI App：主窗口、菜单栏、设置
Tests/TransoryCoreTests/   适配器与提示词测试（用假传输层，不发真实请求）
```

## 接入新的服务商

- 兼容 OpenAI Chat Completions 的服务：不用写代码，在设置里点「＋」，填地址和模型即可。
- 其他协议：实现 `StreamingProvider` 的两个方法 `makeURLRequest(for:)` 和 `parse(_:)`，在 `ProviderKind` 和 `ProviderFactory` 里各加一项。

## 下一步

- 划词翻译：Accessibility API 取选中文本 + `NSPanel` 浮窗 + 全局快捷键
- 截图 OCR：ScreenCaptureKit + Vision
- 历史记录、收藏、术语表（SwiftData）
- 文档翻译：PDFKit、DOCX/PPTX 的 XML 文本替换
