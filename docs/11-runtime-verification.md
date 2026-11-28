# 阶段 11｜工程验证记录

主仓阶段 08 基线为 `27906884d59fd04b090b1d5518a245e4d4333af2`，OpenAPI 版本为 0.3.0。阶段 11 R3 定稿修正了寄养健康资料的挂接约束。V001 的 SHA-256 为 `c340be6abd87501f07f57a169bb5895162f7f4bf46505196f7188eed9392f632`。

## 本机执行命令

从仓库根目录执行。Windows 演练使用两个新建的隔离命名管道实例。脚本创建随机名称的合成库，退出时仅删除本次创建的库。Linux 可使用脚本的 `--host`、`--port` 和 `--defaults-extra-file` 连接隔离实例。本地 PITR 要求 MySQL 启用 ROW binlog，并提供与源实例匹配的本地 binlog 目录。

```powershell
$mysqlBin = 'C:/Program Files/MySQL/MySQL Server 8.4/bin'
foreach ($engine in @('80','84')) {
  $stage11Logs = Join-Path $env:TEMP "newpet-stage11-main-integration/data$engine"
  python -B tests/verify_stage11.py --mysql-client "$mysqlBin/mysql.exe" `
    --mysqldump "$mysqlBin/mysqldump.exe" --mysqlbinlog "$mysqlBin/mysqlbinlog.exe" `
    --pipe "NewpetStage11Main$engine" --local-binlog-dir $stage11Logs
}
python -B tests/verify_release_guard.py
```

## 实际结果

| 执行项 | 结果 |
|---|---|
| MySQL 8.0.46 | **61 项通过**。逻辑备份 0.36 秒，备份至恢复及核对合计 2.69 秒，单段 binlog 重放验证 0.17 秒。 |
| MySQL 8.4.9 | **61 项通过**。逻辑备份 0.36 秒，备份至恢复及核对合计 2.53 秒，单段 binlog 重放验证 0.18 秒。 |
| 发布门禁 | **19 个合成用例通过**。包括占位／测试号、双端互换、生产配置缺失、私有覆盖、上传旧回执与产物篡改。 |
| 阶段 08 回归 | 在与上述主仓提交内容一致的工作树运行 `python -B tests/verify_contract.py --standards --v001 backend/src/main/resources/db/migration/V001__newpet_batch_a_core.sql`。OpenAPI 3.1、V001 对齐及 **308 个请求／响应样例通过**。 |
| 阶段 09 回归 | 沿用上轮阶段 09 终审记录。原 `tests/verify_stage09.py`，MySQL 8.0.46 与 8.4.9 各 **67 项 V001 探针通过**。 |

两套数据库均验证空库安装、含旧数据的增量升级和 63 张表。SQL 探针覆盖相同 UnionID 的作用域、挑战并发只消费一次、员工和门店恢复后旧会话仍失效、跨店媒体及错用途拒绝、门头 JPEG／PNG 与 3 MiB 限制、执照禁 WebP、其他合法用途仍可使用 WebP、入住健康附件与照护附件的用途和门店范围、邀请码密文过期后回执仍在、Outbox 双 worker 与旧租约保护、商品截止与结算竞争。逻辑恢复比较业务计数、约束、密封字节和摘要，定点恢复还从原库回放到指定事务，排除其后的更新。

在 MySQL 8.0.46 上先用 R2 的 V002 跑新增探针，存在真实入住且尚无照护事件时，挂健康照片触发 `ERROR 3819`（`private_media_attachment_chk_1`）。R3 两个版本均通过四个新增用例：入住健康照片直接挂接、照护照片误挂入住被拒绝、跨店附件作用域被拒绝、两种用途继续可挂合法照护事件。具体父记录、同宠及读取可见性的校验由应用联测验证。

[执行输出](../tests/stage11-verification-output.txt)保存逐项探针和回归结果。

## 部署前取证

本机结果使用合成数据和真实 MySQL 引擎。实际 Spring Boot 端点、Redis 故障、微信测试号、对象存储及 KMS、目标环境的跨段 PITR 和 RPO/RTO 按 [阶段 12 准入清单](11-stage12-admission.md)验证。上表用时是本机小库演练记录。
