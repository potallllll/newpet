# NewPet 正式需求

面向社区型、小型宠物店的免费多商户 SaaS 经营管理平台。

`potallllll/newpet` 的 `main` 是本项目 V1.0 现行正式需求的阅读入口。当前开发阶段、冻结状态和准入条件以状态页为准。

## 首次阅读

- AI / Codex 执行约束：[AGENTS.md](AGENTS.md)
- 文档地图与阅读顺序：[docs/README.md](docs/README.md)
- 当前阶段、状态例外与待决项：[docs/REQUIREMENTS-STATUS.md](docs/REQUIREMENTS-STATUS.md)
- DeepSeek执行标准与提示词：[执行标准](docs/execution/deepseek-execution-standard.md) · [可复制提示词](docs/execution/deepseek-start-prompt.md)
- 店员端：[正式需求及待决边界](docs/04-staff-miniapp.md)

具体业务规则只以 `docs/README.md` 指向的正式模块文档为准。本文件不复制当前阶段、业务结论或冲突处理规则，避免入口摘要与正式文档发生漂移。

来源基线为 `potallllll/pet-store-platform` 的整改提交 `3b4fa2dd32cab22978552f562cb941c333cea4e4`。该提交用于核对迁移来源。后续执行以本仓库当前正式文档及其确认范围为准。

## 计划组成

- 客户端微信小程序
- 店员端微信小程序（商户老板也可使用）
- Web 管理后台
- 统一后端 API 与数据库
- 多商户数据隔离体系
