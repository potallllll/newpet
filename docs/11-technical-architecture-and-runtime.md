# 11｜NewPet 技术架构与运行设计

> status: mixed
> status_scope: stage11_batch_a_architecture_and_runtime
> confirmed_scope: monorepo_technology_stack_v002_r3_runtime_design_and_release_policy
> pending_scope: target_environment_configuration_calibration_and_stage12_evidence
> development_readiness: partial
> blocked_by: [DEC-EXEC-01, DEC-EXEC-02]
> requirements_ref: 27906884d59fd04b090b1d5518a245e4d4333af2
> api_contract: 0.3.0
> api_contract_review_state: merged_to_main
> migration_baseline: V001_and_V002_R3
> v001_sha256: c340be6abd87501f07f57a169bb5895162f7f4bf46505196f7188eed9392f632

## 1. 首批范围

服务对象以一到三人的社区宠物店为主。顾客从小程序提交预约或商品需求，店员在原单内确认、服务、结算和处理退款。线下收付款可事后按原单登记，店员端继续按真实状态办理业务。阶段 08 的双端核心链路先验收，平台 Web 随后接入。新能力按阶段 08 §9 逐个开启，故障时保留双端可办理的高频业务。 [主仓状态](https://github.com/potallllll/newpet/blob/27906884d59fd04b090b1d5518a245e4d4333af2/docs/REQUIREMENTS-STATUS.md) · [阶段 08 契约](https://github.com/potallllll/newpet/blob/27906884d59fd04b090b1d5518a245e4d4333af2/docs/08-api-and-authorization.md)

## 2. 单仓、构建与模块边界

| 仓库路径 | 职责和构建入口 |
|---|---|
| `apps/customer-miniapp/` | uni-app Vue 3 顾客端，独立 AppID 与 CI 构建。 |
| `apps/staff-miniapp/` | uni-app Vue 3 店员端，包含老板菜单，独立 AppID 与 CI 构建。 |
| `apps/platform-web/` | 后置 Vue 3 平台 Web，独立发布及账号凭证，先预留构建位置。 |
| `backend/` | Java 21 LTS、Spring Boot 3.5 系列、Maven Wrapper。按领域分包的单一代码库，API 与 Worker 使用同一版本镜像、各自启动配置。 |
| `backend/src/main/resources/db/migration/` | Flyway 迁移。以阶段 09 V001 和阶段 11 V002 按顺序安装，部署时由单独迁移作业使用独立数据库身份执行。 |
| `contracts/` | 阶段 08 OpenAPI、授权矩阵和字段追踪。由 CI 校验声明并生成只读 TypeScript 类型；请求封装按各端认证、文件和重试语义维护。 |
| `docs/`、`infra/`、`scripts/`、`tests/` | 正式文档、部署配置、发布检查脚本及验证入口。 |

- 服务端按 identity、store、booking、service、boarding、catalog、inventory、ledger、wallet、coupon、media、notification 划分包。每个业务包拥有实体及事务入口，跨包组合由用例服务控制同一数据库本地事务。接口保留统一 `/api/v1` 和阶段 08 的错误对象、角色、版本与幂等约定。
- 数据主库 MySQL 8.0。在生产兼容版本验证 V001/V002、备份及 SQL 模式。Redis 7.x 兼容模式，TLS 和按进程账号授权。Node.js 22 LTS，锁定 uni-app Vue 3 与 Vite 的兼容版本，双端共用 lockfile。Spring Boot、Connector/J、Flyway（含 MySQL 模块）、Redis 客户端和 DCloud 的精确补丁由初始化 PR 记录，按支持周期与依赖扫描结果批准。
- 数据库存 UTC 毫秒时间，连接显式设置 UTC，HTTP 时间用 RFC3339。03:00 寄养截点、经营统计和自然月限频按 Asia/Shanghai 计算。金额按原账本使用 BigDecimal 与 DECIMAL，API 保留两位十进制字符串。所有状态切换、余额、库存、券和权限以 MySQL 当前事务为准。
- 数据写权限仅授予所属 API 或 Worker。查询先按可信会话限定店铺、本人和父对象，再验证业务状态；事务内对鉴权版本和原单版本再次核对。平台 REST、平台 Cookie、数据库角色及发布环境独立，平台人员使用原定的账号密码及一致权限，随阶段 05 接入。

## 3. AppID 与发布拦截

| 环境 | 小程序构建 | 服务端受众及凭证 |
|---|---|---|
| local | 顾客端内置 `YOUR_CUSTOMER_APPID`，店员端内置 `YOUR_STAFF_APPID`。供本地构建与合成数据演练。 | 合成认证与测试数据隔离，微信能力按不可用展示。 |
| integration | 两端分别注入微信分配的有效测试 AppID。编译时写入 uni-app 产物的 `project.config.json`。 | 测试 AppID/Secret 从受保护变量或 KMS 注入。真实微信权限按该测试号实测。 |
| production | 每端独立的正式 AppID。批准名单维护在受保护的 CI 环境。 | 配置只允许正式 AppID 与登记的受众；服务端启动时核对配置、数据库应用登记及开关。 |

客户端请求头只选择可信配置项。服务器使用对应 AppID 与密钥向微信验真，再发出固定受众的凭证。构建物、后台有效配置及最终上传工具必须核对同一 AppID；双端 AppID 不得相同。CI 对**两个实际产物**执行 [AppID 检查](../scripts/check_miniapp_release.py)，要求 release 模式、生产配置、准确的双端正式名单和已知测试 AppID 清单。拒绝占位符、试用值、已知测试号、受众互换、私有项目配置覆盖及构建物／后台不一致。build 阶段输出每端内容树 SHA-256。upload 阶段从受信的构建工件读取已批准回执，复算摘要并核对两个实际上传 AppID，最终上传工具只读该次验证过的工件。回执真实性由受保护流水线签名及来源校验保证。CI 上传账号和 AppSecret 仅从 Secret Manager 取用。

仓库提供[本地开发占位配置](../infra/wechat/development-appids.json)。有效测试号及正式号须完成微信侧登记后才能运行相应联调或发布。AppID 格式检查无法判定一个尚未登记的号码究竟是测试号还是正式号，正式分类由受保护的发布名单及微信后台证据确认。

## 4. 身份、会话和权限

### 4.1 可信分组与换绑

1. 服务端用配置的 AppID 换取微信登录证明。OpenID 只在 AppID 内有效。只有服务器从微信收到的 UnionID，且经管理员验证两端同属一个开放平台命名空间，才可写跨 AppID 分组。摘要使用稳定域名和长度编码构造 SHA-256；客户端字段、手机号、相同 OpenID 或账号昵称均不能作为分组凭证。跨端分组快捷识别也须先有明确的本端 `wechat_binding`，本端首次关联须通过有效可信微信证明及当前账号核验。
2. 同一命名空间一个 UnionID 一个永久分组；一个平台用户最多一个活动分组。V001 已绑定的记录按原 AppID 继续读取。历史记录未见可信证据保持未分组。碰到多用户归并冲突、目标已关联其他有业务历史的账号、旧绑定不能明确安全撤销或拿不到跨 AppID 证据时，关闭跨端换绑并提示核对。可继续在原合法 AppID 登录。
3. 未完成认证时签发 256 位随机 `phone` 挑战，5 分钟有效。手机验证码向微信验真，正规化号码后查唯一 Platform User。手机号冲突时消费原挑战并在同事务生成 3 分钟的 `rebind` 挑战，绑定签发 AppID、目标 User、旧 `auth_version` 和本次认证证明摘要。跨实例取 MySQL 当前时间。等于截止即失效，锁行消费一次，关闭或换号重新认证。请求只提交阶段 08 允许的字段。
4. 换绑确认时校验挑战、当前会话纪元、手机号证明、旧绑定归属及全部相关绑定。按平台用户 ID 升序锁账号及对应分组、绑定，重验当前 `auth_version`，事务内先撤旧关联再绑定本次新微信、提升 `auth_version`、消费挑战并写审计。另一端的同一新微信在真实证据和本端核验完成后才关联本端 OpenID。旧两端会话在下一受保护请求即失效。缺少可信分组的跨端换绑须等待证据。用户、门店 Customer、订单和余额保持原 ID。
5. 登录短码和手机凭证只在受控调用中短时使用。挑战只持 token 摘要和加密上下文；加密上下文绑定挑战摘要、AppID、阶段、纪元与截止时间。消费时清空加密上下文与密钥引用。客户端重试丢失认证响应时，重新拿登录短码或手机证明查真实结果。身份接口限频、日志字段及恢复策略见 [运行手册](11-operations-and-recovery.md)。

### 4.2 小程序会话

- 访问 token 由服务端生成 256 位随机数。MySQL 保存 token 摘要、AppID、固定受众、User、`auth_version`、灾备签发纪元、可能存在的员工／门店代次以及时间。拿到店员 AppID 的已认证自然人未必有经营资格，完成建店或受邀确认后重新签发带正确任职的会话。顾客会话只用本人和指定店资料。
- 每个受保护请求按 token 摘要在主库核验有效会话、启用的 AppID、双截止、当前 `auth_version`、签发纪元及角色。经营请求另外校验当前 `active_staff_membership`、员工状态、当前门店状态和两级代次。Redis 缓存可快速拒绝明确过期或撤销，允许决定来自本次的 MySQL 权威读。账号或数据库无法核验时返回暂不可用。
- 绝对有效期 12 小时，闲置 2 小时。成功鉴权续闲置到较小者 `min(主库当前时间 + 2h, hard_expires_at)`，续期条件先验证尚未过期及撤销标记。Redis 写入的截止不得超过数据库阈值。退出只撤销当前会话。
- 停用、移出、重新入职／恢复员工在同事务更新有效任职并提升员工代次；门店停用和恢复提升门店代次，避免逐个更新员工。临时休息沿营业设置办理。代次旧的会话不能复活。更新权限与受保护写入遵循同一锁顺序，获得锁后重验当前状态。

## 5. 私有媒体

1. `createMediaUploadIntent` 按用途及发起者建立意图。服务器选择私有桶和随机对象键，小程序只获得该对象的限时上传能力。有效 10 分钟，限制单对象、文件大小、声明类型和内容校验。门头和营业执照均只接受 JPEG/PNG，分别不超过 3 MiB、10 MiB。实际解码需核对类型和大小，门头还需核验 1:1。其余首发图片上限候选 10 MiB，后端仍按业务模块更小上限校验。未经检查的原件只进入隔离路径。
2. `completeMediaUpload` 重验意图发起者、受众和用途，确认实际对象版本、哈希、真实字节数、图片解码、尺寸并完成内容安全扫描。用不可变对象版本，任何晚到 PUT 都不会替换已验证版本。验证失败按原接口错误返回；没有图的正常服务仍可完成。
3. 已验证且同归属同用途的媒体才可附带到当前业务对象。附件挂接在原写事务内使用服务端业务类型和 ID。建店前的门头／营业执照使用用户意图；建店成功时先锁原上传者与未挂接媒体，同事务改为新店及当前老板，再附入原资料。门头公开用独立批准后的派生图；营业执照仅老板及后期获授权平台审核读取。
4. `getAuthorizedMediaDownload` 返回 60 秒有效的受保护网关地址。下载时重验当前用户及会话、用途、挂接、原服务是否可见和实际对象版本；停用、附件替换、撤回授权或终止服务后旧地址无法开启新的读取。文件经网关传输，短签不交付对象存储 GET 地址。没有数据库和原 ACL 时拒绝私有发链。服务照片缺失或旧媒体未获可信映射时保留业务事实，页面显示媒体不可用。已中止服务的顾客视图隐藏本次过程说明、结果版本、媒体及其缩略图，下载网关同样拒绝顾客读取此次过程。

| 用途 | 挂接对象和当前读取范围 |
|---|---|
| 主人宠物图 `owner_pet` | 本人 `owner_pet`。门店资格不能直接取得主人原件；现有允许的业务投影仍按对应模块授权。 |
| 服务照片 `service_photo` | 本店 `service_record`。本店有权人员读取；顾客只看本人服务中允许展示的照片，中止服务过程照片不向顾客展示。 |
| 寄养照护照片 `boarding_care` | 本店 `boarding_care_event`。顾客只看本人寄养中标为可见的照护照片。 |
| 寄养健康资料 `boarding_health` | 接宠核对时的疫苗、健康资料照片按 F-BOARD-032 选填，直接挂本宠 `boarding_stay`。既有健康相关照护事件可继续挂 `boarding_care_event`。两类均须按原业务、同店同宠和私有媒体授权重验；事件可见不自动公开健康资料。 |
| 入库原单 `intake_document` | 本店原入库单及有效经营资格。 |
| 门头、商品图 | 本店原资料或 SKU；公开页面只用审核生效或合法上架的派生图。 |
| 营业执照 `business_license` | 本店原资料或有效待审对象，仅本店老板及后续正式平台审核身份。普通店员、顾客及公开投影均不读取。 |

## 6. 业务事务与异步任务

- 预约、服务、寄养、商品、钱包、结算及退款继续执行阶段 08、09，V002 沿用原账和状态。跨域一次事务使用服务端确定的身份、店铺、原单及不可变业务事实。锁顺序从当前账号的鉴权变更路径到门店、原预约或原订单、结算范围、权益和按 ID 排序的 SKU。外部服务调用置于锁外，回写再核版本。
- 业务事实、审计、幂等回执和需异步处理的 Outbox 行一次提交。退款、库存、钱包不由消息回调重新执行。Redis 加速只读缓存、限频与唤醒。租约、重试、商品超时、幂等清理、日志及灾备见 [运行手册](11-operations-and-recovery.md)。
- 以可核实的回执和业务版本作为重试依据。响应丢失由同一操作键查询；业务状态变化须重新获取当前详情。收款应收断言保持阶段 08 的 409 规则。真实线下合并转账继续按各独立原单登记分摊。

## 7. 本次决策与阶段边界

- V002 四组缺口的 DDL、字段追踪、升级和回退见[迁移手册](11-v002-migration-runbook.md)。微信渠道记录随 V002 就绪，在真实渠道验收后开启。
- TTL、限频、并发参数、RPO/RTO 为阶段 11 定稿的首发配置和运行目标。阶段 12 以[验收与冻结清单](12-v1-acceptance-and-freeze.md)及[技术准入清单](11-stage12-admission.md)收口目标环境证据。正式 AppID、环境、供应商配置和正式开工授权继续按 DEC-EXEC-01／02 办理。
