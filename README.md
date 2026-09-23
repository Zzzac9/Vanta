# Vanta

Vanta 是一个 iOS 端个人 AI Agent 项目，目标是成为可以长期使用的个人智能助手。

## 技术栈

- iOS 原生开发：Swift + SwiftUI
- 目标系统：iOS 27
- 当前仅开发 iPhone App
- 后端规划：Python + FastAPI
- Agent 后端未来可能采用 LangGraph
- 后续可能接入 LLM、Memory、HealthKit、App Intents、语音和图片／截图理解等能力

## 规划架构

```text
iPhone App
    ↓ HTTPS
Python FastAPI Backend
    ↓
Agent / LangGraph
    ↓
LLM / Memory / Tools / MCP
```

iPhone App 未来主要负责：

1. 用户交互界面
2. Chat / Voice 输入
3. 展示 Agent 回复和执行状态
4. 调用 iOS 原生能力
5. HealthKit 等本地数据访问
6. App Intents / Shortcuts 等系统集成
7. 与后端 Agent 通信

## 当前阶段

当前只搭建 Vanta 的 iOS App 基础壳，不开发 Agent、LangGraph、LLM、HealthKit、数据库或真实网络请求。

第一版包含三个主要页面：

- **Assistant**：主页面。未来承载聊天、语音、图片和 Agent 执行；当前仅保留基础页面。
- **Memory**：未来展示 Vanta 对用户的长期记忆；当前显示简单占位内容。
- **Settings**：未来配置模型、服务器地址、权限、HealthKit 和调试选项；当前显示基础设置页面框架。

## 目录规划

```text
Vanta/
├── App/
├── Features/
│   ├── Assistant/
│   ├── Memory/
│   └── Settings/
├── Core/
│   ├── Models/
│   ├── Network/
│   ├── Storage/
│   └── Services/
├── Integrations/
│   ├── Health/
│   ├── AppIntents/
│   ├── Speech/
│   └── Camera/
└── Resources/
```

`Core` 和 `Integrations` 将在对应功能开始开发时再创建，避免提前引入空架构。

## 开发原则

- 使用 SwiftUI 和现代 iOS API。
- UI 接近 Apple 原生应用：简洁、现代、留白充分。
- 优先使用系统组件和 SF Symbols。
- 不过度封装，不在早期建立复杂架构。
- 当前允许使用 Mock 数据。
- 不提前实现未来功能，只预留合理边界。
- 每个阶段结束时都必须保证项目可以正常 Build 和运行。
- 每轮修改前先检查结构、说明计划并等待确认；修改后执行 Build、报告结果并等待下一步指令。

## 第一阶段目标

- App 可以正常启动。
- 根界面使用 `TabView`。
- 底部包含 Assistant、Memory、Settings 三个 Tab。
- Assistant 是默认首页。
- 三个页面可以正常切换。
- 暂不实现聊天逻辑。

