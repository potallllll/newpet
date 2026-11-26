# 阶段 08｜首批契约验证

## 实际执行

从仓库根目录运行。Python 使用 `openapi-spec-validator==0.7.2` 及其 JSON Schema 依赖。V001 参数使用阶段 09 终审包中的 SQL 路径，脚本会核对文件指纹。

首次复跑可用 `python -m pip install --target (Join-Path $env:TEMP 'newpet-stage08-openapi-validator') 'openapi-spec-validator==0.7.2'` 安装依赖。若只检验本仓库契约，运行 `python -B tests/verify_contract.py --standards`。

```powershell
$env:PYTHONPATH = Join-Path $env:TEMP 'newpet-stage08-openapi-validator'
python -B tests/verify_contract.py --standards --v001 $stage09V001
```

```text
144 operations, 131 paths, 203 schemas, 312 traced properties, 2226 resolvable references.
Iteration: {'A1_CORE': 103, 'A2_ENABLER': 32, 'A_DEPENDENT': 9}
Authorization matrix, route audiences, idempotency and retired field checks passed.
15 owner endpoints and 7 conditional owner permissions verified.
V001 SHA-256, appointment status projection and recharge refund modes verified.
OpenAPI 3.1 standard validation passed.
161 JSON Schema request and response examples passed.
```

## 上游与证据范围

- 已核对正式需求基线 `2227fc03a698ee8f1180e04a4aa93c7c6bfe6ec1` 为本次定稿前的 `main`。
- 已核对 V001 SHA256 为 c340be6abd87501f07f57a169bb5895162f7f4bf46505196f7188eed9392f632，与终审包输入一致。本包引用该数据库版本。
- 定稿时核对了 24 个相对链接、49 个验收编号和全部 734 个字段的永久号、逻辑名及状态。OpenAPI 操作与 Schema 与 R2 终审包一致。
- 校验覆盖 15 个选填原因 DTO 的省略、null、空串、全空白、合法文字和非法数字，以及 3 个必填原因、预约投影、显式充值退款模式、实际退款时间和业务错误响应形状。
- 本轮执行的是契约和 DDL 文本校验。49 条联测用例覆盖 Spring Boot 鉴权、实际事务与并发、Redis 会话和微信真机，待服务可运行后执行。
