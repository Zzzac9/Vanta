# Vanta Backend

当前链路：iPhone SwiftUI → FastAPI → DeepSeek → iPhone。

## 首次配置

打开 `backend/.env`，填写：

```env
DEEPSEEK_API_KEY=你的_API_Key
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-flash
```

如果要使用 Pro，把模型改为：

```env
DEEPSEEK_MODEL=deepseek-v4-pro
```

`.env` 已加入 `.gitignore`，不要把 Key 写进 Swift 或 Python 源码。

## 启动

```bash
cd /Users/zzzac/Desktop/Vanta/backend
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

## 接口

- `GET /`：后端状态和当前模型
- `GET /health`：健康检查
- `POST /chat`：调用 DeepSeek

测试：

```bash
curl -X POST http://127.0.0.1:8000/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"你好，介绍一下你自己"}'
```
