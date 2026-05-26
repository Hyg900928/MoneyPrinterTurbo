# AI 视频生产系统方案设计

## 1. 背景

客户希望实现一套视频自动化生产系统：输入一批原始视频素材和脚本后，系统能够自动识别素材中的可用片段，过滤废片，再根据脚本镜头需求匹配素材，最后自动生成带字幕、配音、BGM、音效和花字的视频。

这不是单条 n8n 工作流能完整承担的需求。更合理的定位是：

> n8n 负责编排流程，MoneyPrinterTurbo 负责视频合成，新增 AI 素材理解与镜头匹配服务负责核心业务判断。

第一阶段不建议承诺“完全替代剪辑师”。推荐先做可控的模板化成片系统，并保留人工审核。

## 2. 目标与非目标

### 2.1 目标

- 支持客户上传或同步原始视频素材。
- 自动把原始视频拆成候选片段。
- 自动识别废片、空镜、模糊、严重抖动、无主体、无产品等无效片段。
- 自动给可用片段打标签，例如主体出镜、手持产品、产品特写、使用场景、口播、正面展示等。
- 根据脚本拆出镜头规则。
- 根据镜头规则从片段库中匹配素材。
- 自动合成视频，支持字幕、配音、BGM、基础音效和模板化花字。
- 生成预览视频，支持人工审核、重新匹配、重新生成。
- n8n 负责流程编排、状态流转、通知、失败重试和人工节点。

### 2.2 非目标

- 第一阶段不做完全自由剪辑。
- 第一阶段不承诺广告级审美判断。
- 第一阶段不做复杂多人协作后台。
- 第一阶段不训练私有视觉模型，优先使用通用视觉模型 + 规则评分。
- 第一阶段不让 n8n 直接承担大视频处理和渲染任务。

## 3. 现有 MoneyPrinterTurbo 评估

### 3.1 可复用能力

当前 MoneyPrinterTurbo 已具备一条短视频生成链路：

- FastAPI 接口：`/videos`、`/tasks`、`/video_materials`、`/musics`。
- 后台任务队列：支持内存队列和 Redis 队列。
- 本地素材上传：素材进入 `storage/local_videos/`。
- TTS：支持多种语音 provider。
- 字幕：支持 TTS 时间轴和 Whisper 兜底。
- BGM：支持本地音乐和随机选择。
- 视频合成：MoviePy + FFmpeg。
- WebUI：Streamlit 界面可用于调试。
- MIT License：允许商用二次开发，但需保留版权声明。

核心链路在：

- `app/services/task.py::start`
- `app/services/task.py::generate_final_videos`
- `app/services/video.py::combine_videos`
- `app/services/video.py::generate_video`
- `app/controllers/v1/video.py`
- `app/models/schema.py`

### 3.2 当前不足

MoneyPrinterTurbo 当前更适合“根据主题/文案找素材或使用本地素材，然后随机/顺序拼接成短视频”，还不能直接满足客户的“脏素材自动清洗 + 镜头语义匹配”需求。

主要缺口：

- `combine_videos()` 当前按固定时长切段，再随机或顺序拼接，不理解镜头语义。
- `preprocess_video()` 当前只做素材可读性、尺寸校验、图片转视频，不做废片识别、主体识别、产品识别。
- `VideoParams.video_materials` 只有素材 URL 和 duration，没有 timeline、镜头规则、片段标签等结构。
- API 鉴权代码存在但当前路由中被注释，生产环境必须恢复。
- CORS 默认允许 `*`，生产环境需要收紧。
- 任务状态默认内存态，服务重启后丢失，生产环境至少要 Redis，最好增加数据库。
- 本地仓库存在 `._*` macOS 元数据文件，后续二开前需要清理。

### 3.3 定位结论

MoneyPrinterTurbo 适合作为：

> 视频合成/渲染服务底座。

不适合作为：

> 完整 AI 自动剪辑系统。

因此推荐在 MoneyPrinterTurbo 上新增“按 timeline 合成”的定制 API，同时把素材理解、打标、匹配、审核放在外层业务系统中。

## 4. 总体架构

```text
客户上传素材/提交脚本
        |
        v
n8n 编排层
        |
        +--> 素材入库服务
        |
        +--> 视频预处理服务
        |       - 转码
        |       - 抽帧
        |       - 分镜
        |       - 切片
        |
        +--> AI 视觉识别打标服务
        |       - 废片识别
        |       - 主体识别
        |       - 产品识别
        |       - 动作/镜头标签
        |       - 质量评分
        |
        +--> 镜头规则匹配服务
        |       - 脚本拆镜
        |       - 片段匹配
        |       - 缺素材提示
        |
        +--> MoneyPrinterTurbo 成片服务
        |       - timeline 裁切
        |       - 拼接
        |       - 字幕
        |       - 配音
        |       - BGM
        |       - 模板化花字
        |
        +--> 审核与通知
                - 预览
                - 人工通过/驳回
                - 重新生成
                - 下载/交付
```

## 5. 模块设计

### 5.1 n8n 编排层

n8n 不直接处理大视频文件，不直接跑复杂 FFmpeg 命令，不直接保存完整素材库。n8n 负责流程编排和业务状态推进。

职责：

- 接收任务触发。
- 调用素材服务创建任务。
- 调用预处理服务。
- 调用 AI 打标服务。
- 调用镜头匹配服务。
- 调用 MoneyPrinterTurbo 生成预览视频。
- 通知人工审核。
- 根据审核结果继续生成、重试或结束任务。
- 记录每一步状态和错误原因。

推荐工作流：

- `素材入库工作流`
- `素材分析工作流`
- `成片生成工作流`
- `审核发布工作流`

### 5.2 素材入库服务

职责：

- 保存客户上传的原始视频。
- 记录素材基础信息。
- 生成 `asset_id`。
- 返回素材 URL 或本地路径。

建议存储：

- MVP：本地磁盘或 NAS。
- 生产版：对象存储，例如 S3、OSS、COS、MinIO。

素材元数据示例：

```json
{
  "asset_id": "asset_001",
  "file_name": "shoe_demo_001.mp4",
  "file_url": "s3://bucket/raw/shoe_demo_001.mp4",
  "product_id": "shoe_001",
  "scene": "手持展示",
  "duration": 68.4,
  "status": "uploaded"
}
```

### 5.3 视频预处理服务

职责：

- 转码为统一格式。
- 生成低清预览版本。
- 按镜头变化或固定窗口切成候选片段。
- 抽取关键帧。
- 初步过滤客观废片。

客观废片规则：

- 黑场或白场。
- 音视频不可读。
- 时长过短。
- 分辨率过低。
- 严重模糊。
- 严重抖动。
- 无明显主体。

候选片段示例：

```json
{
  "clip_id": "clip_001",
  "asset_id": "asset_001",
  "start": 12.4,
  "end": 16.8,
  "duration": 4.4,
  "preview_url": "s3://bucket/clips/clip_001.mp4",
  "keyframes": [
    "s3://bucket/frames/clip_001_01.jpg",
    "s3://bucket/frames/clip_001_02.jpg"
  ],
  "status": "prepared"
}
```

### 5.4 AI 视觉识别打标服务

职责：

- 对关键帧进行视觉识别。
- 输出结构化标签和质量评分。
- 判断是否为可用片段。

建议先用通用视觉模型分析关键帧，不直接把整段视频交给模型。这样成本更低，结果也更容易解释。

识别维度：

- 是否有人。
- 是否主体出镜。
- 是否手持产品。
- 是否产品清晰可见。
- 产品是否占画面主体。
- 镜头类型：远景、中景、近景、特写。
- 动作类型：拿起、展示、转动、试穿、使用、口播。
- 质量问题：模糊、抖动、遮挡、曝光异常。
- 是否废片。
- 置信度。

打标结果示例：

```json
{
  "clip_id": "clip_001",
  "usable": true,
  "quality_score": 0.86,
  "match_tags": [
    "主体出镜",
    "手持产品",
    "正面展示",
    "产品清晰"
  ],
  "shot_type": "medium",
  "action": "product_showcase",
  "product_visible": true,
  "issues": [],
  "summary": "主体手持产品正面展示，画面清晰，可作为开场镜头"
}
```

### 5.5 脚本拆镜服务

职责：

- 把脚本文案拆成镜头列表。
- 为每个镜头生成匹配规则。
- 给出目标时长、画面要求、字幕/配音文本。

脚本拆镜示例：

```json
{
  "shots": [
    {
      "shot_id": "shot_001",
      "order": 1,
      "duration_range": [3, 5],
      "required_tags": ["主体出镜", "手持产品", "产品清晰"],
      "preferred_tags": ["正面展示"],
      "text": "这双鞋最大的特点就是轻便透气",
      "fallback": "product_closeup"
    },
    {
      "shot_id": "shot_002",
      "order": 2,
      "duration_range": [2, 4],
      "required_tags": ["产品特写", "产品清晰"],
      "preferred_tags": ["材质细节"],
      "text": "鞋面采用大面积透气网布",
      "fallback": "product_showcase"
    }
  ]
}
```

### 5.6 镜头匹配服务

职责：

- 根据镜头规则检索片段库。
- 给每个候选片段计算匹配分。
- 生成最终 timeline。
- 找不到合适素材时返回缺口。

匹配评分建议：

```text
总分 = 必需标签命中分
     + 偏好标签命中分
     + 质量分
     + 时长适配分
     + 产品一致性分
     - 重复使用惩罚
     - 风险问题惩罚
```

timeline 示例：

```json
{
  "timeline": [
    {
      "shot_id": "shot_001",
      "clip_id": "clip_001",
      "file": "s3://bucket/raw/shoe_demo_001.mp4",
      "start": 12.4,
      "end": 16.8,
      "text": "这双鞋最大的特点就是轻便透气",
      "match_score": 0.91
    },
    {
      "shot_id": "shot_002",
      "clip_id": "clip_014",
      "file": "s3://bucket/raw/shoe_demo_004.mp4",
      "start": 3.1,
      "end": 6.3,
      "text": "鞋面采用大面积透气网布",
      "match_score": 0.84
    }
  ],
  "missing_shots": []
}
```

### 5.7 MoneyPrinterTurbo 成片服务

职责：

- 接收 timeline。
- 按指定文件、起止时间裁切片段。
- 按顺序拼接。
- 添加字幕、配音、BGM、基础转场。
- 根据模板添加花字和画面样式。
- 输出预览视频和最终视频。

推荐新增接口：

```http
POST /timeline_videos
```

请求示例：

```json
{
  "video_subject": "女鞋透气卖点视频",
  "video_aspect": "9:16",
  "template": "product_showcase_v1",
  "timeline": [
    {
      "file": "shoe_demo_001.mp4",
      "start": 12.4,
      "end": 16.8,
      "text": "这双鞋最大的特点就是轻便透气"
    }
  ],
  "voice_enabled": true,
  "voice_name": "zh-CN-XiaoxiaoNeural-Female",
  "subtitle_enabled": true,
  "bgm_type": "random",
  "bgm_volume": 0.2
}
```

建议新增代码结构：

```text
app/models/schema.py
  - TimelineClipItem
  - TimelineVideoRequest

app/controllers/v1/video.py
  - POST /timeline_videos

app/services/task.py
  - start_timeline_video()

app/services/video.py
  - combine_timeline_clips()
```

不要直接替换现有 `/videos` 流程，避免破坏原项目能力。

### 5.8 审核服务

职责：

- 展示预览视频。
- 展示每个镜头使用了哪个片段。
- 支持人工通过。
- 支持重新匹配。
- 支持替换指定镜头片段。
- 支持修改字幕后重新生成。

MVP 可以先用飞书/企业微信/邮件通知 + 简单审核链接。生产版再做独立审核后台。

## 6. 数据模型建议

### 6.1 任务表 `video_generation_task`

| 字段 | 说明 |
| --- | --- |
| task_id | 任务 ID |
| customer_id | 客户 ID |
| product_id | 产品 ID |
| script | 脚本文案 |
| template_id | 模板 ID |
| status | 当前状态 |
| preview_url | 预览视频 |
| final_url | 最终视频 |
| error_message | 错误原因 |
| created_at | 创建时间 |
| updated_at | 更新时间 |

### 6.2 原始素材表 `raw_asset`

| 字段 | 说明 |
| --- | --- |
| asset_id | 原始素材 ID |
| task_id | 关联任务 |
| file_url | 原始文件地址 |
| file_name | 文件名 |
| product_id | 产品 ID |
| duration | 时长 |
| status | 状态 |

### 6.3 片段表 `asset_clip`

| 字段 | 说明 |
| --- | --- |
| clip_id | 片段 ID |
| asset_id | 原始素材 ID |
| start_time | 起始时间 |
| end_time | 结束时间 |
| preview_url | 片段预览 |
| usable | 是否可用 |
| quality_score | 质量分 |
| tags | 标签 JSON |
| issues | 问题 JSON |
| summary | AI 摘要 |

### 6.4 镜头表 `script_shot`

| 字段 | 说明 |
| --- | --- |
| shot_id | 镜头 ID |
| task_id | 任务 ID |
| order | 顺序 |
| text | 字幕/配音文本 |
| required_tags | 必需标签 |
| preferred_tags | 偏好标签 |
| duration_min | 最小时长 |
| duration_max | 最大时长 |

### 6.5 timeline 表 `render_timeline`

| 字段 | 说明 |
| --- | --- |
| timeline_id | timeline ID |
| task_id | 任务 ID |
| shot_id | 镜头 ID |
| clip_id | 片段 ID |
| file_url | 文件地址 |
| start_time | 裁切起点 |
| end_time | 裁切终点 |
| match_score | 匹配分 |

## 7. n8n 工作流设计

### 7.1 素材入库工作流

触发方式：

- Webhook。
- 表单提交。
- 文件夹监听。
- 定时同步素材库。

流程：

```text
Webhook
→ 校验参数
→ 保存素材记录
→ 调用素材入库服务
→ 创建任务记录
→ 返回 task_id
```

### 7.2 素材分析工作流

流程：

```text
获取待分析素材
→ 调用预处理服务
→ Split In Batches 逐片段处理
→ 调用视觉识别服务
→ 写入片段标签
→ 更新素材状态
```

注意：

- 图片/关键帧可以通过 HTTP URL 或 base64 传给视觉模型。
- 不建议把大视频作为 n8n binary data 在多个节点间传递。
- 生产环境中，n8n 只传文件 URL 和 ID。

### 7.3 成片生成工作流

流程：

```text
接收脚本与模板
→ 脚本拆镜
→ 读取片段库
→ 镜头匹配
→ 生成 timeline
→ 调用 MoneyPrinterTurbo /timeline_videos
→ 轮询任务状态
→ 保存预览地址
```

### 7.4 审核发布工作流

流程：

```text
预览生成完成
→ 发送审核通知
→ 审核通过？
   → 是：生成最终视频/交付下载地址
   → 否：记录修改意见
        → 换片段/改字幕/重跑匹配
        → 重新生成预览
```

## 8. MVP 设计

### 8.1 MVP 输入

- 20-50 条客户原始视频。
- 1 个产品或 1 个明确品类。
- 1 条固定脚本。
- 1 套固定成片模板。
- 目标输出比例：优先 9:16。

### 8.2 MVP 输出

- 自动切片后的片段库。
- 每个片段的标签和可用性判断。
- 一条 15-30 秒产品展示视频。
- 字幕、配音、BGM。
- 预览视频链接。
- 缺素材提示。
- 简单审核机制。

### 8.3 MVP 不做

- 多模板自由切换。
- 批量多产品生产。
- 多角色权限后台。
- 复杂花字编辑器。
- 私有模型训练。
- 全自动审美判断。

### 8.4 MVP 验收标准

- 样本素材能够完成自动切片。
- 明显废片能被过滤。
- 可用片段能生成标签。
- 固定脚本能生成完整 timeline。
- MoneyPrinterTurbo 能按 timeline 输出预览视频。
- 任务失败时能看到明确错误原因。
- 生成结果支持人工审核和重新生成。

## 9. 生产版扩展

MVP 验证通过后，可以扩展：

- 多模板管理。
- 多产品/SKU 识别。
- 片段库复用。
- 品牌字幕样式。
- 音效点配置。
- 花字模板配置。
- 批量生成任务。
- 审核后台。
- 任务看板。
- 成本统计。
- 权限管理。
- 对象存储和 CDN。
- 更完整的数据库持久化。

## 10. 安全与稳定性

### 10.1 API 鉴权

MoneyPrinterTurbo 当前已有 `verify_token()`，但路由里鉴权依赖被注释。生产环境必须恢复：

```python
router = new_router(dependencies=[Depends(base.verify_token)])
```

n8n 调用 MoneyPrinterTurbo 时通过 `x-api-key` 传入密钥。

### 10.2 CORS

当前 CORS 默认允许 `*`。生产环境应通过 `CORS_ALLOWED_ORIGINS` 指定域名。

### 10.3 文件安全

继续沿用 `app/utils/file_security.py`，所有用户传入的文件名或路径必须限制在白名单目录内。

### 10.4 状态持久化

MVP 可以使用 Redis 保存任务状态。生产版建议增加数据库，保存任务、素材、片段、timeline、审核记录。

### 10.5 大文件处理

n8n 不直接搬运大视频文件。推荐所有服务之间传递：

- `asset_id`
- `clip_id`
- `file_url`
- `start_time`
- `end_time`

而不是直接传二进制视频内容。

## 11. 部署建议

### 11.1 MVP 部署

```text
一台服务器
  - n8n
  - MoneyPrinterTurbo API
  - Redis
  - 本地素材目录
  - FFmpeg
```

适合样本验证和低并发演示。

### 11.2 生产部署

```text
n8n 编排服务
MoneyPrinterTurbo 渲染服务
素材预处理服务
AI 打标服务
PostgreSQL
Redis
对象存储
CDN
监控与日志
```

视频预处理和渲染服务可独立扩容。

## 12. 交付阶段

### 阶段 1：样本验证

周期：5-7 天。

交付：

- 处理客户 20-50 条视频。
- 生成候选片段。
- 输出 AI 标签。
- 生成 1 条样片。
- 验证识别与成片质量。

### 阶段 2：MVP

周期：2-4 周。

交付：

- 素材入库。
- 自动切片。
- AI 打标。
- 镜头匹配。
- MoneyPrinterTurbo timeline 合成接口。
- n8n 编排工作流。
- 简单审核和重新生成。

### 阶段 3：生产版

周期：6-10 周。

交付：

- 多模板。
- 批量任务。
- 审核后台。
- 状态看板。
- 失败重试。
- 数据库持久化。
- 部署和培训。

## 13. 风险与应对

| 风险 | 说明 | 应对 |
| --- | --- | --- |
| 客户期待完全自动剪辑 | AI 无法稳定替代主观审美 | 合同中写明模板化成片和人工审核 |
| 素材质量差 | 模糊、抖动、主体不明显会影响结果 | 先做样本验证，输出缺素材提示 |
| 识别不稳定 | 视觉模型可能误判 | 使用多关键帧 + 规则评分 + 人工审核 |
| 渲染耗时长 | 视频生成消耗 CPU/内存 | 渲染服务独立部署，限制并发 |
| n8n 执行数据膨胀 | 大视频经过 n8n 会拖垮执行记录 | n8n 只传 URL 和 ID |
| 成本不可控 | 视觉模型、TTS、存储、渲染都有成本 | 第三方费用单列，任务级统计成本 |

## 14. 对客户的表达方式

可以这样对客户说明：

> 可以实现，但建议拆成两层来做。第一层是素材清洗和智能打标，先把原始视频里的废片、空镜、模糊片段过滤掉，并把可用片段按主体、产品、动作、镜头类型打标签。第二层才是按脚本镜头规则自动匹配素材并生成视频。n8n 负责流程编排，视频识别和视频合成由专门服务完成。第一阶段建议先做一个模板化 MVP，保留人工审核，这样稳定性更高，也更容易交付。

如果客户问能否基于 MoneyPrinterTurbo：

> 可以基于 MoneyPrinterTurbo 二开，它适合作为视频合成和渲染底座，可以复用 API、TTS、字幕、BGM 和 MoviePy/FFmpeg 合成能力。但客户真正需要的素材理解、废片过滤、镜头匹配和审核流程仍然需要定制开发。

## 15. 推荐报价口径

报价不要因为使用开源项目而大幅降低。MoneyPrinterTurbo 只能节省部分合成层开发，核心业务能力仍需定制。

建议：

- 样本验证：1.5-2.5 万。
- MVP：6-10 万。
- 生产版：15-30 万。
- 高级定制版：30 万起。

第三方费用单列：

- AI 视觉模型。
- TTS。
- 视频渲染资源。
- 云服务器。
- 对象存储。
- CDN。
- 字体/BGM/素材版权。

## 16. 参考资料

- n8n HTTP Request 节点：https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest/
- n8n binary data：https://docs.n8n.io/data/specific-data-types/binary-data/
- n8n Execute Command 节点：https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.executecommand/
- OpenAI Images and Vision：https://platform.openai.com/docs/guides/images-vision
- MoneyPrinterTurbo 本地代码：`app/services/task.py`、`app/services/video.py`、`app/controllers/v1/video.py`、`app/models/schema.py`
