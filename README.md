# 8GB 显存跑通 DeepSeek Harness：全本地「文字 + 视觉」双模型方案

一台 RTX 5060 Laptop（8GB 显存）+ 16GB 内存的 Windows 机器上，让 DeepSeek Harness（下称 dsh）
完全离线地跑 agent 任务，并且能看懂粘贴进来的截图。不依赖任何云端 API。

- 推理引擎：llama.cpp **b12110**（Windows CUDA 13.4 预编译包），**路由模式**
- 文字模型：`Qwen3.5-9B-Q4_K_M.gguf`（5.68GB）→ 给 dsh 当大脑
- 视觉模型：`Qwen3-VL-4B-Instruct` Q4_K_M + mmproj（2.9GB）→ 给 modlens 识图
- 一个端口 `http://127.0.0.1:2210/v1`，两个模型按需换入换出显存

所有数字都是本机实测，不是估算，见第 8 节。

**这个仓库里没有模型权重，一个字节都没有**——底座是 Qwen3.5-9B 与 Qwen3-VL-4B（第三方模型），
这里放的只是我调它们的那套东西：路由参数模板、启动脚本、配置写入与自检脚本，加这份记录。
权重怎么拿、放哪，见第 4 节与第 12.1 节。

> **不想逐条下载 8GB？** 我另外打了一个整合包（引擎 + 两个模型 + 自动配置脚本，解压即用），
> 走夸克网盘分发，链接、提取码与校验值在第 12 节。

---

## 1. 为什么不是「一个模型搞定」

两个独立的坑，各自决定了这里的一个选择：

**工具调用可靠性 → 量化底线。** 极低比特（三值 / 1.58-bit 一类）的超压缩方案会严重削弱
function-calling：模型照样输出，但函数名和参数是编的——这台机器上换掉这类模型之前，
agent 反复用错误参数调用工具、任务卡死就是直接后果。`Q4_K_M` 是本地工具调用普遍公认的
可用下限，9B 是这个下限上 8GB 卡能全量进显存的最大尺寸。

**显存 → 一次只能驻留一个模型。** 9B 在 65536 上下文下实测常驻 6508 MiB（开 98304 是 7208 MiB，
开 49152 是 6152 MiB），视觉模型 32768 上下文时空闲 5954 MiB、编码 4K 截图时峰值 7160 MiB，
两者相加远超 8GB。所以不是「同时跑两个」，而是**路由模式**：一个常驻进程 + 一张模型登记表，请求里的
`model` 字段决定装载谁，`--models-max 1` 保证显存里永远只有一个。

9B 能把窗口开到 98304（本指南默认给 65536，留更多余量）的原因是它是**混合线性注意力**模型：32 层里只有 8 层真正保存 KV
（`full_attention_interval = 4`），其余 24 层的递归状态与上下文长度无关。实测每 token
的可变显存约 **22 KiB**，其中纯 KV 只占 16.0 KiB，其余是 SSM 状态与计算缓冲随窗口的增长。

代价很实在：每次粘图，下一条文字消息要多等几秒（冷启动 8~10 秒，页缓存热了约 5 秒）。
偶尔截图完全划算，别一条消息塞十张图。

---

## 2. 前提

| 项目 | 要求 |
| :--- | :--- |
| GPU | NVIDIA 8GB 显存（驱动 617.42 实测可用） |
| 内存 | 16GB 起（模型靠 mmap 读入，权重页会占文件缓存） |
| 系统 | Windows 10/11 x64 |
| 磁盘 | 约 9GB（两个模型 + 引擎） |
| Node.js | ≥ 22.19（modlens 要求；本机 v24.16.0） |
| dsh | 桌面端已安装，且知道 profile 目录（默认 `~/.dsh/profiles/<profile>/`） |

下文用 `<LLAMA_HOME>` 代表这套东西的根目录，例如 `D:\llama`。
**路径带空格也能用**（`<LLAMA_HOME>` 在带空格的目录里没问题），但所有命令行里都要加引号。

---

## 3. 目录结构

```
<LLAMA_HOME>\
├── start-llama.bat        启动脚本（双击）
├── config.bat             端口 / API key
├── models.ini             每个模型的参数（上下文、KV 量化、采样、mmproj）
├── engine\                llama.cpp 预编译包解压到这里
└── models\
    ├── Qwen3.5-9B-Q4_K_M.gguf                       文字
    └── Qwen3-VL-4B-Instruct\                        视觉（必须放子目录）
        ├── Qwen3VL-4B-Instruct-Q4_K_M.gguf
        └── mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf     文件名必须以 mmproj 开头
```

路由模式的两条硬规则：多模态文件放**子目录**；投影文件名以 **`mmproj`** 开头，否则识图能力直接失效。

上面是**跑起来之后**的目录。本仓库实际带的是模板和脚本，`models.ini` 与 `config.bat` 由脚本按你的
解压位置生成，不进仓库（里面是本机绝对路径和一个本地 API key）：

| 仓库里 | 生成到 | 说明 |
| :--- | :--- | :--- |
| `models.ini.template` | `models.ini` | 路径写成 `{{ROOT}}` 占位，由 `scripts\render-ini.ps1` 渲染 |
| `config.bat.example` | `config.bat` | example 里没有密钥；真密钥只待在你本机 |
| `start-llama.bat` | 同名 | 按脚本自身位置定位引擎，换盘不用改 |
| `scripts\` | — | 渲染、写 dsh/modlens 配置、校验权重与服务 |
| `使用说明.txt` | — | 365 行速查：档位怎么选、显存怎么算、故障对照，与本文互为补充 |

---

## 4. 下载

### 4.1 引擎

GitHub `ggml-org/llama.cpp` Releases → 找 **build 12110**（或更新版本），下载
`llama-b<build>-bin-win-cuda-13.4-x64.zip`（具体资产名以页面为准，选 CUDA 版本与你驱动匹配的）。
解压后把 `llama-server.exe`、各 `*.dll` 放进 `<LLAMA_HOME>\engine\`。

国内直连 GitHub 资产经常 ECONNRESET；实测单线程走 gh-proxy 类镜像只有 26~53KB/s，
需要**分段并发下载**再拼接（4MB 分片、8 路并发可用）。

> 校验解压完整性：`llama-server.exe --version` 应打印 `build 12110`。

### 4.2 文字模型（ModelScope，国内快）

```bash
curl -L --fail --continue-at - -o models/Qwen3.5-9B-Q4_K_M.gguf \
  "https://modelscope.cn/models/unsloth/Qwen3.5-9B-GGUF/resolve/master/Qwen3.5-9B-Q4_K_M.gguf"
```

期望字节数 **5,680,522,464**；
sha256 `03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8`。

### 4.3 视觉模型 + 投影

```bash
curl -L --fail --continue-at - -o "models/Qwen3-VL-4B-Instruct/Qwen3VL-4B-Instruct-Q4_K_M.gguf" \
  "https://modelscope.cn/models/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/master/Qwen3VL-4B-Instruct-Q4_K_M.gguf"

curl -L --fail --continue-at - -o "models/Qwen3-VL-4B-Instruct/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf" \
  "https://modelscope.cn/models/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/master/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf"
```

| 文件 | 字节数 | sha256 |
| :--- | ---: | :--- |
| `Qwen3VL-4B-Instruct-Q4_K_M.gguf` | 2,497,281,664 | `66358cb18bb6b3b1b6675aa412c7a88ef01d228f481184d13668e5201c730a0a` |
| `mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf` | 453,974,304 | `30ba2c7dd3127a4561b6cba9d13d0f711c91bdb38742e2f56d73c8cb596bd06d` |

`sha256sum` 对不上就别往下走——半截 GGUF 的报错千奇百怪，比重新下载便宜得多。

---

## 5. 三个配置文件

### 5.1 `config.bat`

```bat
@echo off
REM  config.bat -- user settings for start-llama.bat
REM  Lines must stay as  set NAME=value  (no spaces around =).
set PORT=2210
set API_KEY=replace-me-with-your-own-random-hex
```

生成一个密钥：`node -e "console.log(require('crypto').randomBytes(16).toString('hex'))"`
留空 = 不鉴权，同机任何进程都能调你的 API，不建议。

### 5.2 `models.ini`

```ini
version = 1

; 全局默认。键名就是 llama-server 的长选项名（去掉 --）。
[*]
jinja = true
flash-attn = on
n-gpu-layers = 99
cache-type-k = q8_0
cache-type-v = q8_0

; 文字模型：dsh 用这个。
[qwen3.5-9b]
model = D:/llama/models/Qwen3.5-9B-Q4_K_M.gguf
ctx-size = 65536
parallel = 1
temp = 0.6
top-k = 20
top-p = 0.95
min-p = 0.0

; 视觉模型：modlens 用这个。
[qwen3-vl-4b]
model = D:/llama/models/Qwen3-VL-4B-Instruct/Qwen3VL-4B-Instruct-Q4_K_M.gguf
mmproj = D:/llama/models/Qwen3-VL-4B-Instruct/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf
ctx-size = 32768
image-max-tokens = 8192
temp = 0.2
```

要点：

- **section 名 = 模型 id**。客户端请求里 `"model": "qwen3.5-9b"` 就是这个字符串，改成别的，
  dsh 那边要同步改。
- **`parallel = 1` 必须写。** 默认 4 个 slot，65536 会被切成 4 份 16K，直接触发
  `exceed_context_size_error`。
- 路径用正斜杠 `/`，避开 INI 转义歧义；空格不用转义，但要确认整个值在一行内。
- 显存不够先降 `ctx-size`；想保上下文就先把 `cache-type-k/v` 换成 `q4_0`（KV 那部分再省一半）。
- 窗口大小怎么估：`固定约 5096 MiB（权重+缓冲）+ ctx × 22 KiB`。
  65536 → 推算 6504 / 实测 **6508 MiB**（差 4 MiB，说明这个式子在锚点外也准）；
  98304 → 7208 MiB（实测吻合）；131072 → 约 7912 MiB，已超出 7899 MiB 可用，装不下。
- **`image-max-tokens` 才是识图清晰度的开关，不是 `ctx-size`。** 图像 token 数 = 宽×高÷1024
  （Qwen3-VL 是 32×32 像素一个 token）。超过这个开关的值时 llama.cpp **把图缩小**而不是报错，
  所以窗口永远不会因为图大而爆——代价是小字变糊。默认顶约 4096 token（≈4.2 MP），
  设成 8192 后上限约 8.4 MP，4K 截图按原分辨率进模型。
- 视觉模型的显存斜率和文字模型不同：它 36 层全存 KV，实测 `55.9 KiB/token`，固定部分约
  `4167 MiB`（由 5060@16384 和 5954@32768 两点定出）。32768 空闲驻留 5954 MiB，
  但**编码 4K 时峰值到 7160 MiB**，只剩 739 MiB——这是全套配置里最紧的一处。

### 5.3 `start-llama.bat`

```bat
@echo off
REM ============================================================
REM  start-llama.bat -- llama.cpp (CUDA 13.4) ROUTER server
REM  One port, two models, loaded on demand:
REM    qwen3.5-9b    text   -> DeepSeek Harness
REM    qwen3-vl-4b   vision -> modlens (mmproj)
REM  Per-model settings live in models.ini, port/key in config.bat.
REM ============================================================
setlocal EnableExtensions
set "ROOT=%~dp0"
set "BIN=%ROOT%engine"
set "INI=%ROOT%models.ini"
set "MODEL=%ROOT%models\Qwen3.5-9B-Q4_K_M.gguf"
set "VMODEL=%ROOT%models\Qwen3-VL-4B-Instruct\Qwen3VL-4B-Instruct-Q4_K_M.gguf"
set "VPROJ=%ROOT%models\Qwen3-VL-4B-Instruct\mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf"

if exist "%ROOT%config.bat" (
  call "%ROOT%config.bat"
) else (
  echo [config] config.bat not found, using defaults
)
if not defined PORT set PORT=2210
set "KEYARG="
if defined API_KEY set "KEYARG=--api-key %API_KEY%"

if not exist "%BIN%\llama-server.exe" (
  echo REFUSE: llama-server.exe not found in "%BIN%"
  pause
  exit /b 4
)
if not exist "%INI%" (
  echo REFUSE: models.ini not found "%INI%"
  pause
  exit /b 3
)
if not exist "%MODEL%" (
  echo REFUSE: text model not found "%MODEL%"
  pause
  exit /b 3
)
if not exist "%VMODEL%" (
  echo REFUSE: vision model not found "%VMODEL%"
  pause
  exit /b 3
)
if not exist "%VPROJ%" (
  echo REFUSE: mmproj not found "%VPROJ%"
  echo   Without mmproj the vision model cannot read images.
  pause
  exit /b 3
)

setlocal EnableDelayedExpansion
netstat -ano | findstr ":!PORT! " | findstr "LISTENING" >nul 2>nul
if not errorlevel 1 (
  echo [ALREADY RUNNING] port !PORT! is busy. Close that server first.
  pause
  exit /b 4
)

if defined API_KEY (
  echo [auth] API key ENABLED - clients must send it as bearer token
) else (
  echo [auth] no API key - anyone on this machine can call the API
)
echo [router] http://127.0.0.1:%PORT%/v1
echo [router] models: qwen3.5-9b ^(text^)  qwen3-vl-4b ^(vision^)
"!BIN!\llama-server.exe" ^
  --host 127.0.0.1 --port !PORT! ^
  !KEYARG! ^
  --models-preset "!INI!" ^
  --models-max 1 ^
  --models-memory-margin 256 ^
  --no-webui
endlocal

echo [engine exited] errorlevel=%ERRORLEVEL%
pause
```

**写 .bat 的三条铁律**（踩过的坑）：

1. 必须 **CRLF** 行尾 + **纯 ASCII** 内容。混进 LF 或非 ASCII 字符，双击会闪退
   （报 `此时不应有 。`，exit 255）。转换：`tr -d '\r' < a.bat | sed 's/$/\r/' > b.bat`
2. 端口检查用**单行** `netstat -ano | findstr ... >nul 2>nul` + `if not errorlevel 1 ( ... )`。
   不要写 `for /f ... do ( 多行 )`，在 cmd 里极易解析失败。
3. 脚本结尾必须有 `pause`，否则报错窗口一闪而过，你永远看不到原因。

---

## 6. 启动与自检

双击 `start-llama.bat`，看到 `listening on http://127.0.0.1:2210` 即成功。
路由模式**启动时不加载任何模型**，所以显存显示 0 MiB 是正常的，第一个请求才会装载。

```bash
# 1) 活着吗
curl -s -H "Authorization: Bearer <API_KEY>" http://127.0.0.1:2210/health

# 2) 两个模型都注册上了吗，视觉那个声明了 image 输入吗
curl -s -H "Authorization: Bearer <API_KEY>" http://127.0.0.1:2210/v1/models

# 3) 工具调用是真的返回 tool_calls，而不是把 JSON 写进正文
curl -s -H "Authorization: Bearer <API_KEY>" -H "Content-Type: application/json" \
  http://127.0.0.1:2210/v1/chat/completions -d '{
  "model":"qwen3.5-9b",
  "messages":[{"role":"user","content":"What is the file size of report.pdf? You must call a tool."}],
  "tools":[{"type":"function","function":{"name":"get_file_size",
    "description":"Return the size in bytes of a file on disk",
    "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]
}'
```

第 3 步期望 `"finish_reason":"tool_calls"`，且 `tool_calls[0].function.arguments` 是
`{"path":"report.pdf"}`。如果 `finish_reason` 是 `stop` 而正文里躺着一段 JSON 文本，
说明这个量化版本不适合当 agent 大脑，换更高量化或更大模型。

---

## 7. 接入 dsh

### 7.1 文字模型

编辑 `~/.dsh/profiles/<profile>/cordis.patch.yml`（`DSH_HOME` 默认 `~/.dsh`）：

```yaml
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      localqwen:
        displayName: Qwen3.5-9B local (llama.cpp)
        apiKeyEnv: LOCALQWEN_API_KEY
        api: openai-completions
        baseURL: http://127.0.0.1:2210/v1
        models:
          - id: qwen3.5-9b

- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: localqwen
    model: qwen3.5-9b
```

然后在 dsh 设置界面里给 `Qwen3.5-9B local (llama.cpp)` 填 API key（和服务端 `config.bat`
必须一致，否则 401），**完全退出并重启 dsh**（配置只在启动时读取）。

不要给 9B 挂太多工具：5 个以内、上下文别超 49K，可靠性最好。

### 7.2 视觉（modlens）

装插件：

```bash
npx -y @deepseek-ai/dsh plugin --profile <profile> add @liustack/modlens
```

给插件指一个**能看图的 OpenAI 兼容端点**（modlens 自己不带视觉能力）。
它写自己的 `~/.modlens/config.json`：

```bash
modlens config set provider        openai
modlens config set openai.baseUrl  http://127.0.0.1:2210/v1
modlens config set openai.model    qwen3-vl-4b
echo "<API_KEY>" | modlens config set openai.apiKey   # 从管道读，不进 shell 历史
modlens config show
modlens doctor            # 离线自检，不花额度；[ok] openai 那行必须出现
```

代理默认**跟随系统**，什么都不用设：`providers.openai.proxy` 字段缺失就是继承
`HTTPS_PROXY` / `HTTP_PROXY`，而这条路线遵守 `NO_PROXY`。只有当你用
`modlens config set proxy <url>`（顶层键）时不保证遵守 `NO_PROXY`，那时才需要单独
给本地端点设直连：`modlens config set openai.proxy ""`（空串 = 强制直连；想恢复继承
就删掉这个字段）。

**关键一步，多数人卡在这里。** dsh 在**粘贴阶段**就做图片准入检查：你选的
`qwen3.5-9b` 是纯文本本体，图片根本到不了 modlens，界面直接弹
「当前模型不支持图片，请切换支持图片的模型」。

modlens 的解法是给文本模型注册一个**视觉分身**（provider id 形如 `modlens-localqwen`，
显示名带 `(modlens vision)`，声明 `inputModalities` 含 image）。但它默认只为
`deepseek / glm / mimo` 三个前缀建分身，其它模型不在名单里。在
`cordis.patch.yml` 追加（**覆盖已安装插件的 config，不要再写一条 insert**）：

```yaml
- id: modlens
  name: "@liustack/modlens"
  config:
    families: ['deepseek', 'glm', 'mimo', 'ling', 'qwen']
```

- `families` 是**替换**默认值，不是追加，所以把默认的三家也写上。
- 别用 `families: ['*']`：`'*'` 要求上游元数据显式声明 `inputModalities` 包含 `text`，
  自定义 provider 通常没声明，结果一个分身都不生成。显式前缀没有这个限制。
- 前缀同时匹配完整模型 id 和去掉厂商命名空间后的裸 id。

重启 dsh，在模型下拉里选带 **`(modlens vision)`** 的那条，再粘图。

---

## 8. 实测数据（RTX 5060 Laptop 8GB / 16GB RAM）

| 项目 | 实测 |
| :--- | :--- |
| 显存预算 | 8151 MiB 总 / **7899 MiB 可用**（驱动常驻约 252 MiB） |
| `qwen3.5-9b` @ ctx **65536** + q8_0（本指南默认） | 常驻 **6508 MiB**，余量 1391 MiB |
| `qwen3.5-9b` @ ctx 98304 + q8_0（可选上限档） | 常驻 **7208 MiB**，余量 691 MiB |
| `qwen3.5-9b` @ ctx 49152 + q8_0（历史值） | 驻留 **6152 MiB** |
| `qwen3-vl-4b` @ ctx **32768** + q8_0 | 空闲驻留 **5954 MiB**；`image-max-tokens 8192` 下编码 4K **峰值 7160 MiB**，余 739 MiB |
| `qwen3-vl-4b` @ ctx 16384 + q8_0（旧配置） | 驻留 **5060 MiB** |
| 视觉显存斜率 | **55.9 KiB/token**，固定约 4167 MiB（由 5060@16K / 5954@32K 两点定出） |
| 图像 token 换算 | 宽×高 ÷ 1024（32×32 px 一个 token），到 `image-max-tokens` 顶为止 |
| 顶默认 ≈4096 token | 4K/5K/6K 宽一律缩到 4082 token，细节上限约 **4.2 MP** |
| 顶设 8192 | 4K 全保（8151 token），5K/6K 宽仍缩，上限约 **8.4 MP** |
| 单图耗时（顶 8192） | 1080p **0.5 秒**、2K **3.6 秒**、4K **13.0 秒** |
| 多图叠加 | 每张独立封顶、线性相加：6 张 1080p = 12262 token；4K ×3 = 24496 token（窗口 75%，17.2 秒）；第 4 张 4K 会超 32768 |
| 窗口 98304 灌 94867 token | **通过**（96.5% 占用） |
| 窗口 65536 灌 61267 token | **通过**（93.5% 占用），常驻仍是 6508 MiB |
| 窗口 65536 灌 67962 token | `400 exceed_context_size_error` 干净拒绝 |
| 46188 token 冷启动预填充 | 31.1 秒 ≈ **1485 t/s** |
| 灌 105488 token | 服务端 `400 exceed_context_size_error` 干净拒绝 |
| 显存 vs 填充量 | **无关**。70K / 90K / 94.8K 三档峰值都是 7212 MiB，窗口一次性预分配 |
| 冷启动 90145 token，针埋在 5% / 50% / 95% 深度 | **3/3 全中**（含最容易丢的中部） |
| 冷预填充吞吐 | **1363~1522 t/s**；90K 一次 **66.1 秒**，46K 一次 26.2 秒 |
| 文字 tool_call | `finish_reason: tool_calls`，函数名与参数正确 |
| 切换 文字 → 视觉 | 冷启动 **8.6 秒**；页缓存热了 **4.3~4.7 秒** |
| 切换 视觉 → 文字 | 冷启动 **9.8 秒**；页缓存热了 **5.3 秒** |
| 路由父进程自身 | 不占显存，仅约 200MB 内存 |

窗口显存的算法（本机标定）：`约 5096 MiB 固定 + ctx × 22 KiB`。65536 算出 6504、实测 6508（差
4 MiB，说明这个式子在两个锚点之外也准）；98304 算出 7208、实测吻合；131072 算出 7912 MiB，
**已超出 7899 MiB 可用，装不下**。22 KiB/token 里有 16.0 KiB 是纯 KV
（32 层中仅 8 层存 KV），其余 5.4 KiB 是 SSM 状态与计算缓冲的增长。

---

## 9. 故障对照表

| 现象 | 真实原因 | 处理 |
| :--- | :--- | :--- |
| 双击 bat 窗口一闪而过 | 行尾不是 CRLF，或文件里有非 ASCII 字符 | 转 CRLF + 纯 ASCII，脚本末尾留 `pause` |
| `此时不应有 。` / exit 255 | `for /f ... do ( 多行 )` 在 cmd 里解析失败 | 换成单行 `netstat \| findstr >nul` + `if not errorlevel 1` |
| `401 Invalid API Key` | 客户端 key 与 `config.bat` 不一致 | 对齐两边，改完重启服务 |
| `exceed_context_size_error` | 请求超过 `ctx-size`；或漏了 `parallel = 1` 被切成 4 个约 16K slot | 补 `parallel = 1`，或降档 / 换 `q4_0` |
| 进程活着但显存 0 MiB | 路由模式按需加载，正常 | 发一个请求就会装载 |
| 每次粘图后第一条文字消息很慢 | 模型换入换出，冷启动约 8~10 秒、页缓存热了约 4~5 秒 | 正常；减少单条消息的图片数量（4K 一张另加约 13 秒识图时间） |
| 4K 截图里的小字看不清 | `image-max-tokens` 到顶，图被缩小后再喂（不报错） | 升到 8192（4K 全保，慢约 3 倍），见第 5.2 节 |
| 下拉里没有 `(modlens vision)` | 模型前缀不在 `families` 里，或用了 `['*']` 但上游没声明 modality | 按 7.2 加显式前缀，重启 dsh |
| 粘图报「当前模型不支持图片」 | 选的是纯文本本体，不是分身 | 改选带 `(modlens vision)` 的条目 |
| `ENOTDIR, not a directory` / `not a regular file` / `ripgrep provider failure` / `spawn powershell.exe ENOENT` | **工作目录被切进了 `app.asar`**（Electron 只读归档，是文件不是目录）。这批报错极具误导性，既不是权限问题也不是模型问题 | 让 agent `cd` 回项目根，或新开会话（坏 cwd 会留在会话状态里） |

最后一行值得单独说：agent 为了读打包目录里的 skill 而 `cd` 进安装目录之后，
**所有**文件与子进程工具会同时失败，而模型只会认为「再试一次就好了」，于是连环重试卡死。
预防办法是在 `~/.dsh/AGENTS.md`（dsh 会作为用户全局指令注入每个会话）里写死：
`cd` 只允许在会话启动目录及其子目录内，安装目录只准 `read` 不准写。

---

## 10. 换机器时要改的四处

1. `config.bat` 的 `PORT` / `API_KEY`（**密钥不要提交进仓库**，`.gitignore` 掉或改用环境变量）
2. `models.ini` 里两行 `model =` 和一行 `mmproj =` 的绝对路径
3. `cordis.patch.yml` 的 `baseURL` 端口
4. `~/.modlens/config.json` 的 `openai.baseUrl` / `openai.apiKey`

显存不同的机器改 `models.ini`：8GB 以下必须降 `ctx-size`；12GB 以上可以试 65536，
并把 `--models-max 1` 提到 `2` 让两个模型同时驻留，彻底消除切换等待。

---

## 11. 版本

| 组件 | 版本 |
| :--- | :--- |
| llama.cpp | b12110（`0.9.0-dev`，commit `cd959bae9`），Windows CUDA 13.4 x64 |
| 文字模型 | unsloth/Qwen3.5-9B-GGUF → `Q4_K_M` |
| 视觉模型 | Qwen/Qwen3-VL-4B-Instruct-GGUF → `Q4_K_M` + `mmproj-Q8_0` |
| modlens | 3.27.2 |
| 驱动 | 617.42 |
| Node | v24.16.0 |

---

## 12. 懒人包（网盘整合包）

已经配好一切的目录包，**解压 → 双击 → 跑一个脚本 → 重启 dsh** 即可，不用逐条下载命令。

- 夸克网盘：<https://pan.quark.cn/s/d4f513ccc101?pwd=LsDS>　提取码：`LsDS`
- 压缩包 sha256：`28aac9ac86490b1780a6d8ebcfc7af5da49a809690b8c5b5816b96d21c1041f6`
- 大小：**9,041,656,237 字节**（8.42 GiB / 9.04 GB）
- sha256 是对本地这份 zip 实测得到的（`certutil -hashfile dsh-local-pack.zip SHA256`，10.8 秒算完）；
  网盘上那份显示的大小已核对为 **9,041,656,237 字节**，与本地一致，所以上面这个哈希就是你要比对的值。
- 下载完先比大小再看 sha256。网盘大文件下载不完整是这类包最常见的故障，
  一个半截的 GGUF 会带来千奇百怪的报错，比重新下一遍贵得多。
- 链接失效或模型升级会在本 README 顶部更新，issue 里喊一声更快

包内自带 `README.md`（四步上手）、`scripts\apply-dsh-config.ps1`（幂等写 dsh/modlens
配置，改前自动备份，冲突时只提示不硬改）和 `scripts\verify.ps1`（校验三个权重的 sha256、
服务健康、模型注册、`tool_calls` 是否真返回）。**下载完请先跑一次 verify**——网盘大文件
下载不完整是这类包最常见的故障，校验值能一眼看出来。

包里的权重与原仓库完全一致（校验值见第 4 节），只是组装好了目录和配置；
版权与许可归属 unsloth / Qwen / llama.cpp / modlens 各项目。

### 12.1 权重不进仓库：怎么下载、放哪

GitHub 仓库里**没有 GGUF**，一个字节都没有——单文件 100 MB 的硬限制加上三个权重共
7.99 GiB，放上来既传不动也没人愿意拉。两条路拿：

**路 A（推荐，一条命令都不用）**：直接下第 12 节的网盘整合包，解压后目录已经排好，
跳过本节剩下的内容。

**路 B（自己下）**：用第 4.2 / 4.3 节的 ModelScope 命令（国内实测快，hf-mirror 慢，
HuggingFace 与 GitHub raw 直连基本不通）。三个文件放成下面这个样子，
路径相对你解压 `llama/` 的位置：

```
llama/
└── models/
    ├── Qwen3.5-9B-Q4_K_M.gguf                              ← 文字模型，必需
    └── Qwen3-VL-4B-Instruct/                               ← 视觉模型，只在你要 modlens 识图时必需
        ├── Qwen3VL-4B-Instruct-Q4_K_M.gguf
        └── mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf
```

| 文件 | 字节数 | sha256 |
| :--- | ---: | :--- |
| `Qwen3.5-9B-Q4_K_M.gguf` | 5,680,522,464 | `03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8` |
| `Qwen3VL-4B-Instruct-Q4_K_M.gguf` | 2,497,281,664 | `66358cb18bb6b3b1b6675aa412c7a88ef01d228f481184d13668e5201c730a0a` |
| `mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf` | 453,974,304 | `30ba2c7dd3127a4561b6cba9d13d0f711c91bdb38742e2f56d73c8cb596bd06d` |

三个位置写死在 `models.ini` 里，形如 `model = <LLAMA_HOME>/models/...`。
换盘换目录就改这两行；不想手改可以用整合包里的 `scripts\render-ini.ps1` 按解压位置重算。

放错会怎样，按代价排序：

- **mmproj 文件名不以 `mmproj` 开头**：识图能力**静默消失，不报错**。它必须待在自己那个子目录里。
- **视觉模型没下**：`models.ini` 的 `[qwen3-vl-4b]` 那段指着不存在的文件，路由服务启动时这个档位加载失败。
  只跑文字对话可以先把它注释掉；要 modlens 识图就必须补齐。
- **多下别的仓库的同名量化**：`Q4_K_M` 这个名字在不同仓库指向不同文件，只有上面三个 sha256
  是这套参数实测过的组合。
- **下了一半**：GGUF 截断后的报错千奇百怪（窗口异常、工具调用乱形、直接崩），
  比重新下一遍便宜得多——所以先比字节数，再比 sha256。

---

## 13. 许可与归属

本仓库自己写的部分（`README.md`、`models.ini.template`、`start-llama.bat`、`config.bat.example`、
`scripts/`）以 **MIT** 许可分发，见 [LICENSE](LICENSE)。

里面引用与依赖的东西各自遵循上游许可，本仓库不替代、不改变它们：

| 组件 | 来源 | 许可 |
| :--- | :--- | :--- |
| `Qwen3.5-9B` 底座 | unsloth 量化的 GGUF（源模型 Qwen） | 遵循 Qwen 上游条款 |
| `Qwen3-VL-4B-Instruct` 底座 | Qwen 官方 GGUF | 遵循 Qwen 上游条款 |
| llama.cpp（引擎，**不在本仓库**） | ggml-org/llama.cpp | MIT |
| modlens（识图侧组件，**不在本仓库**） | 上游项目 | 见其仓库 |

权重不在本仓库也不在任何我的服务器上：请从第 4 节的 ModelScope 地址自取，
或用第 12 节的整合包（其中权重与原仓库完全一致，校验值可核对）。
