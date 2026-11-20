-- =============================================================================
--  05_indexes.sql  —— 性能索引
--  设计思路（详见 docs/项目报告.md 第 8 节）：
--    * 论文列表：按研究所 + 时间、按负责人过滤
--    * 作者待办：按作者查"当前有效确认"，使用部分索引
--    * 批次进度：按论文、按研究所 + 状态
--    * 实验追溯：结果 -> 运行 -> 版本，双向索引
--  说明：约束性唯一索引已随 01_schema.sql 建立，这里只补充查询索引。
-- =============================================================================
SET search_path TO srdp, public;

-- 论文列表：研究所内按创建时间倒序；负责人视角
CREATE INDEX ix_paper_institute_created ON paper (institute_id, created_at DESC);
CREATE INDEX ix_paper_owner             ON paper (owner_person_id, created_at DESC);
CREATE INDEX ix_paper_title_lower       ON paper (lower(title));

-- 论文列表按汇交状态筛选：借助批次状态
CREATE INDEX ix_batch_status_paper      ON submission_batch (status, paper_id);

-- 作者视角："我参与的论文"
CREATE INDEX ix_paper_author_person     ON paper_author (person_id, paper_id);

-- 作者待办：批次内当前确认状态（覆盖索引式部分索引）
CREATE INDEX ix_confirmation_current_batch
    ON confirmation (batch_id, person_id)
    WHERE is_current;

-- 工作台“我的待确认”：按人查当前确认状态
CREATE INDEX ix_confirmation_current_person
    ON confirmation (person_id, batch_id)
    WHERE is_current;

CREATE INDEX ix_confirmation_person_history
    ON confirmation (person_id, created_at DESC);

-- 批次进度：研究所看板
CREATE INDEX ix_batch_institute_status ON submission_batch (institute_id, status, created_at DESC);
CREATE INDEX ix_batch_paper_round      ON submission_batch (paper_id, round_no DESC);

-- 批次材料类型校验（提交时按类型 EXISTS 判断）
CREATE INDEX ix_batch_material_type    ON batch_material (batch_id, material_type);

-- 批次作者列表
CREATE INDEX ix_batch_author_person    ON batch_author (person_id, batch_id);

-- 材料 / 版本：一个材料取最新版
CREATE INDEX ix_material_paper_type    ON material (paper_id, material_type);
CREATE INDEX ix_material_version_latest ON material_version (material_id, version_no DESC);

-- 实验追溯：结果 -> 运行
CREATE INDEX ix_result_run             ON experiment_result (run_id);
CREATE INDEX ix_result_version         ON experiment_result (result_version_id, run_id);

-- 实验追溯：运行 -> 引用的版本（反向查"某版本被哪些运行使用"）
CREATE INDEX ix_run_task_started       ON experiment_run (task_id, started_at DESC);
CREATE INDEX ix_run_code_version       ON experiment_run (code_version_id);
CREATE INDEX ix_run_data_version       ON experiment_run (data_version_id);
CREATE INDEX ix_run_config_version     ON experiment_run (config_version_id);
CREATE INDEX ix_run_log_version        ON experiment_run (log_version_id);

-- 访问控制
CREATE INDEX ix_access_request_requester ON access_request (requester_account_id, status, created_at DESC);
CREATE INDEX ix_access_request_pending   ON access_request (created_at DESC) WHERE status = 'PENDING';
CREATE INDEX ix_access_grant_account_mv  ON access_grant (account_id, material_version_id);
CREATE INDEX ix_access_grant_active
    ON access_grant (account_id, material_version_id)
    WHERE revoked_at IS NULL;

-- 下载统计
CREATE INDEX ix_access_log_download ON access_log (grant_id) WHERE action = 'DOWNLOAD';
CREATE INDEX ix_access_log_mv       ON access_log (material_version_id, created_at DESC);

-- 审计与待办
CREATE INDEX ix_audit_object   ON audit_log (object_type, object_id, created_at DESC);
CREATE INDEX ix_audit_created  ON audit_log (created_at DESC);
CREATE INDEX ix_notification_unread ON notification (account_id, created_at DESC) WHERE read_at IS NULL;
CREATE INDEX ix_mail_queue     ON mail_outbox (status, created_at);

ANALYZE;
