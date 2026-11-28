# 阶段 08｜首批契约验证

## 实际执行

从仓库根目录运行。依赖见 [tests/requirements-contract.txt](../tests/requirements-contract.txt)。`$stage09V001` 指向阶段 09 终审包中的 V001 SQL。脚本校验文件指纹；仅复跑契约时可省略 `--v001`。

```powershell
$env:PYTHONPATH = Join-Path $env:TEMP 'newpet-stage08-openapi-validator'
python -m pip install --target $env:PYTHONPATH -r tests/requirements-contract.txt
python -B tests/verify_contract.py --standards --v001 $stage09V001
git diff --check
```

使用该目录中已安装的两项固定版本运行验证，输出如下。

```text
144 operations, 131 paths, 215 schemas, 314 traced properties, 3674 resolvable references.
Iteration: {'A1_CORE': 103, 'A2_ENABLER': 32, 'A_DEPENDENT': 9}
734 registered fields (45 retired), 28 traced header/query names, and recursive request model coverage verified.
Authorization matrix, route audiences, idempotency, error responses and private cache headers passed.
15 owner endpoints and 8 conditional owner permissions verified.
V001 SHA-256, appointment and settlement states, refund modes and tender uniqueness verified.
OpenAPI 3.1 standard validation passed.
308 JSON Schema request and response examples passed.
```

## 上游与证据范围

- 业务需求起始基线为 `2227fc03a698ee8f1180e04a4aa93c7c6bfe6ec1`。本轮用 GitHub `main` 的 `46f14684bc252d716549190d8cb30630a0e16793` 作为整改基线，本地契约版本升至 0.3.0。
- V001 SHA-256 为 `c340be6abd87501f07f57a169bb5895162f7f4bf46505196f7188eed9392f632`。新增比对结算范围状态和付款渠道唯一键。SQL 文件沿用阶段 09 终审版。
- 契约样例覆盖预约角色投影、两侧改期状态、20 个选填原因的六类输入、三种必填原因、券模板、原单收退款和补记、检查停止与寄养不接收、媒体用途限制、中止服务结果隐藏，以及通用 500。结构校验递归检查请求对象和数组上限，核对 734 个注册号及退役项，校验授权、参数、字段三份矩阵和私有响应头。
- [验收矩阵](08-acceptance-matrix.md)共有 59 条，后端授权、事务、网关、实际媒体解码和旧链接失效、Redis 及微信真机待可运行环境联测。契约声明和合成请求样例的通过记录详见上方。
