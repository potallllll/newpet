# 12｜首批单仓初始化开工计划

> status: mixed
> status_scope: stage12_a1_core_kickoff_plan
> confirmed_scope: repository_layout_delivery_order_and_first_slice_acceptance
> pending_scope: formal_implementation_start_environment_and_delivery_owners
> development_readiness: partial
> blocked_by: [DEC-EXEC-01, DEC-EXEC-02]

首批在 `potallllll/newpet` 单仓推进，第一条可运行功能从客户预约到原账单回看。使用阶段 11 定稿及阶段 08 OpenAPI 0.3.0。建议从验收基线新建 `codex/a1-core-init` 实施分支，按下列顺序提交。正式开工前登记实际分支、环境和负责人。 [冻结清单](12-v1-acceptance-and-freeze.md) · [技术架构](11-technical-architecture-and-runtime.md)

## 1. 初始化与交付顺序

| 顺序 | 交付范围 | 达成条件 |
|---|---|---|
| K0 · 准备 | 在 GitHub `main` 锁定基线和迁移指纹；登记开发分支、前后端接口与验收负责人、开发／联调环境、目标部署及凭证注入方式。分开记录占位开发、有效测试号和正式发布。 | 按 DEC-EXEC-01／02 记录决策和授权。仅记录环境与凭证变量名，密钥由受保护环境注入。 |
| K1 · 单仓骨架 | `backend/` 的 Java 21、Spring Boot 3.5 系列、Maven Wrapper 和 Flyway；`apps/customer-miniapp/`、`apps/staff-miniapp/` 建 uni-app Vue 3 双入口，共用 API 类型和开发构建锁文件；给 `apps/platform-web/` 预留目录。MySQL 8.0、Redis 7.x 兼容；登记精确版本及实际构建命令。 | 可从干净检出构建双端及后端，依赖可复现。用仓库的 V001、V002 在空库和带存量演练，打开应用检查实际 Flyway 历史与校验和。开发集成环境启动数据库、Redis 与 API，有真实健康状态。 |
| K2 · 身份与原预约 | 两端会话与手机号校验；公开店铺与可预约洗护项目；顾客本人宠物；原预约提交、店员列表/详情及确认。 | 双端凭证受众、本店／本人范围、幂等回执与预约上屏；插入跨店和过期身份负例。若跨 AppID 可信证据未具备，按阶段 08/11 条件保持相应跨端换绑关闭。 |
| K3 · 到店、开始、完成 | 确认预约关联唯一原单；原预约到店转单，逐宠完成真实检查，再手动开始；完成时确认新增异常，走原站内通知规则。 | 状态、版本、检查、审计和事件同一事务提交。服务完成、账单未收款可从顾客端读回。多宠、快开或复杂路径按正式验收继续接入。 |
| K4 · 线下记账和回看 | 先实现单宠洗护、单笔线下渠道、原订单结算。复用原结算允许的金额与支付逻辑，再从顾客的原账单和服务记录读出一致结果。 | 付款事实、业绩归属、审计和原账单一致。金额或版本不符拒绝，重复收款不写第二笔。真实交易时间与录入时间分开，线下联调按合成环境或门店实际约定取证。 |
| K5 · 首条签收 | 关闭完整平台 Web，跑阶段 12 六步主链；重跑拒绝、停用、并发、重放、网络中断和异常检查。两个有效微信测试号的实际能力独立验证。 | 双端录像或步骤记录、接口请求 ID、脱敏事务证据、构建和迁移版本齐全。主链通过后，再扩 A1_CORE 的寄养、商品、退款等路径，再按依赖开 A2_ENABLER 和 A_DEPENDENT。 |

## 2. 首链路接口交接

路径和 DTO 直接从主仓 OpenAPI 生成。下表使用正式 `operationId`，具体方法、字段、响应及版本以现有契约为准。

| 参与端 | 实现批次 | 接口和业务守卫 |
|---|---|---|
| 双端 | K2 | `exchangeWeChat`、`verifyWeChatPhone`，相同平台身份与各端受众按凭证校验。公开目录 `listPublicStores`／`getPublicStore`／`listPublicAppointmentServices`；顾客宠物 `listOwnedPets`／`createOwnedPet`。 |
| 顾客 → 店员 | K2 | `createAppointment`、`getOwnAppointment`、`listStaffAppointments`、`getStaffAppointment`、`confirmAppointment`。选店及原顾客关系以服务端确定，同一提交按幂等键处理。 |
| 店员 | K3 | `convertAppointment`、`getStaffService`、`startService`、`completeService`。先转单再开始，按原预约和服务版本检查，服务结束后才进入收款。 |
| 店员 → 顾客 | K4 | `getStaffOrder`、`getStaffSettlement`、`recordInitialPayment`、`getOwnService`、`listOwnOrders`、`getOwnOrder`。表单展示应收，提交时用 `final_receivable_amount` 断言核对；外部渠道填 `payment_occurred_at`。 |

后端先查可信会话、门店／本人、父对象，再校验状态与版本；同一事务写业务事实、审计及待投递事件。双端前端遇断线先查原单或使用原幂等键，根据真实结果恢复；本地缓存按现有规则在提交成功或退出时清理。店员可在少量操作内办完，每次业务确认沿原规则，流程签收记录实际点击、重复录入和跳转。 [OpenAPI](../contracts/openapi.batch-a.json) · [授权矩阵](../contracts/authorization-matrix.csv) · [验收用例](08-acceptance-matrix.md)

## 3. 工程和环境准入

- 配置仅登记样板。开发 AppID 用 `YOUR_CUSTOMER_APPID` 和 `YOUR_STAFF_APPID`。未取得有效测试号时只能运行标记为本地／合成的认证用例；真实微信、跨端身份及通知的验收分别留证。发布校验两个实际构建、生产配置和摘要回执。
- CI 计划按顺序运行契约校验、迁移探针、后端测试、双端构建和 A1 冒烟。发布作业在受保护环境校验实际构建的 AppID。首批归档本地与 CI 可复跑的命令、可访问的真实集成环境、数据准备和恢复办法。
- 开工时使用 `python -B tests/verify_contract.py --standards --v001 backend/src/main/resources/db/migration/V001__newpet_batch_a_core.sql`、`python -B tests/verify_release_guard.py` 和迁移手册的命令回归现有底座。实际后端、双端与目标服务的执行命令随 K1 工程一起登记。
- `DEC-EXEC-01` 本次已明确首链范围和单仓计划，实际开发分支与开工授权待落实。 `DEC-EXEC-02` 本次明确 AppID 策略及配置入口，实际测试号／正式号分配、负责人与部署环境待登记。当前交付为正式技术基线和开工计划，应用验证状态随实际交付更新。 [执行标准](execution/deepseek-execution-standard.md) · [AppID 占位配置](../infra/wechat/development-appids.json) · [阶段 11 验证](11-runtime-verification.md)
