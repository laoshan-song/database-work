-- =============================================================================
--  科研论文原始数据汇交管理平台  (Scientific Research Data Deposit Platform)
--  01_schema.sql  —— 建库、建表、约束
--  目标数据库：PostgreSQL 17
--  执行方式：psql -d srdp -f 01_schema.sql
--  说明：本脚本可重复执行（先删 schema 再建），仅用于初始化/重置开发库。
-- =============================================================================

DROP SCHEMA IF EXISTS srdp CASCADE;
CREATE SCHEMA srdp;
SET search_path TO srdp, public;

-- -----------------------------------------------------------------------------
-- 1. 组织与人员
-- -----------------------------------------------------------------------------

CREATE TABLE institute (
    institute_id   bigserial     PRIMARY KEY,
    code           varchar(32)   NOT NULL UNIQUE,
    name           varchar(128)  NOT NULL UNIQUE,
    intro          text,
    contact_email  varchar(128),
    head_person_id bigint,                                -- 所长，FK 在 person 建好后补
    created_at     timestamptz   NOT NULL DEFAULT now()
);

CREATE TABLE person (
    person_id         bigserial    PRIMARY KEY,
    employee_no       varchar(32)  NOT NULL UNIQUE,       -- 工号/学号
    name              varchar(64)  NOT NULL,
    email             varchar(128) NOT NULL UNIQUE,
    phone             varchar(32),
    person_category   varchar(16)  NOT NULL DEFAULT 'RESEARCHER'
        CHECK (person_category IN ('RESEARCHER','STUDENT','STAFF','EXTERNAL')),
    title_grade       varchar(64),                        -- 职称 / 年级
    home_institute_id bigint       REFERENCES institute(institute_id),
    join_date         date,
    leave_date        date,
    status            varchar(16)  NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE','INACTIVE','LEFT')),
    created_at        timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT ck_person_dates CHECK (leave_date IS NULL OR join_date IS NULL OR leave_date >= join_date)
);

ALTER TABLE institute
    ADD CONSTRAINT fk_institute_head FOREIGN KEY (head_person_id) REFERENCES person(person_id);

-- 提高项：多研究所、跨所任职及有效期
CREATE TABLE person_affiliation (
    person_id    bigint      NOT NULL REFERENCES person(person_id) ON DELETE CASCADE,
    institute_id bigint      NOT NULL REFERENCES institute(institute_id),
    role_title   varchar(64),
    valid_from   date        NOT NULL DEFAULT CURRENT_DATE,
    valid_to     date,
    is_primary   boolean     NOT NULL DEFAULT false,
    PRIMARY KEY (person_id, institute_id, valid_from),
    CONSTRAINT ck_affiliation_dates CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

-- 同一人同一时刻最多一个"当前主要"任职
CREATE UNIQUE INDEX ux_affiliation_primary
    ON person_affiliation (person_id)
    WHERE is_primary AND valid_to IS NULL;

-- -----------------------------------------------------------------------------
-- 2. 账号与角色
--    人员档案（person）与登录账号（account）分离：离所人员可停用账号但保留历史
-- -----------------------------------------------------------------------------

CREATE TABLE account (
    account_id      bigserial    PRIMARY KEY,
    person_id       bigint       NOT NULL UNIQUE REFERENCES person(person_id),
    username        varchar(64)  NOT NULL UNIQUE,
    password_hash   text         NOT NULL,
    is_enabled      boolean      NOT NULL DEFAULT true,
    is_system_admin boolean      NOT NULL DEFAULT false,  -- 提高项：平台运维（不替代业务审核）
    disabled_reason text,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    last_login_at   timestamptz
);

CREATE TABLE role (
    role_code   varchar(32) PRIMARY KEY,
    name        varchar(64) NOT NULL,
    description text
);

INSERT INTO role (role_code, name, description) VALUES
    ('INSTITUTE_ADMIN', '研究所管理员', '维护本所人员账号，受理并审核本所论文汇交批次，审批材料访问申请'),
    ('DATA_USER',       '数据使用者',   '查看公开或已授权材料，提交访问申请并按授权范围下载'),
    ('MAINTAINER',      '授权维护成员', '在负责人授权范围内维护草稿、上传材料、登记实验'),
    ('SYS_ADMIN',       '平台运维',     '维护平台配置，不参与业务审核（提高项）');

-- 角色授予/撤销全部留痕，is_active 表示当前有效，撤销不删除历史
CREATE TABLE account_role (
    account_role_id bigserial   PRIMARY KEY,
    account_id      bigint      NOT NULL REFERENCES account(account_id) ON DELETE CASCADE,
    role_code       varchar(32) NOT NULL REFERENCES role(role_code),
    institute_id    bigint      REFERENCES institute(institute_id),  -- 所级角色必填，全局角色为空
    granted_by      bigint      REFERENCES person(person_id),
    granted_at      timestamptz NOT NULL DEFAULT now(),
    revoked_by      bigint      REFERENCES person(person_id),
    revoked_at      timestamptz,
    reason          text,
    is_active       boolean     NOT NULL DEFAULT true,
    CONSTRAINT ck_role_scope CHECK (role_code <> 'INSTITUTE_ADMIN' OR institute_id IS NOT NULL),
    CONSTRAINT ck_role_revoke CHECK ((is_active AND revoked_at IS NULL) OR (NOT is_active AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX ux_active_role
    ON account_role (account_id, role_code, COALESCE(institute_id, 0))
    WHERE is_active;

-- -----------------------------------------------------------------------------
-- 3. 论文、作者、项目维护成员
-- -----------------------------------------------------------------------------

CREATE TABLE paper (
    paper_id          bigserial    PRIMARY KEY,
    institute_id      bigint       NOT NULL REFERENCES institute(institute_id),  -- 主管研究所
    owner_person_id   bigint       NOT NULL REFERENCES person(person_id),        -- 负责人
    title             varchar(300) NOT NULL,
    abstract          text,
    keywords          varchar(300),
    research_field    varchar(128),
    venue             varchar(200),                                              -- 期刊/会议
    submission_status varchar(24)  NOT NULL DEFAULT 'DRAFT'
        CHECK (submission_status IN ('DRAFT','SUBMITTED','UNDER_REVIEW','ACCEPTED','PUBLISHED','REJECTED')),
    doi               varchar(128),
    visibility_level  varchar(16)  NOT NULL DEFAULT 'PROJECT'
        CHECK (visibility_level IN ('PUBLIC','INSTITUTE','PROJECT','RESTRICTED')),
    created_at        timestamptz  NOT NULL DEFAULT now(),
    updated_at        timestamptz  NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX ux_paper_doi ON paper (doi) WHERE doi IS NOT NULL;

CREATE TABLE paper_author (
    paper_id         bigint      NOT NULL REFERENCES paper(paper_id) ON DELETE CASCADE,
    person_id        bigint      NOT NULL REFERENCES person(person_id),
    author_order     integer     NOT NULL CHECK (author_order >= 1),
    is_corresponding boolean     NOT NULL DEFAULT false,
    is_external      boolean     NOT NULL DEFAULT false,   -- 其他单位作者
    affiliation_text varchar(200),
    PRIMARY KEY (paper_id, person_id),
    CONSTRAINT ux_paper_author_order UNIQUE (paper_id, author_order)
);

-- 负责人可授予他人"维护草稿/上传材料/登记实验"的权限；不授予作者确认权
CREATE TABLE paper_maintainer (
    paper_id   bigint      NOT NULL REFERENCES paper(paper_id) ON DELETE CASCADE,
    person_id  bigint      NOT NULL REFERENCES person(person_id),
    scope      varchar(16) NOT NULL DEFAULT 'ALL'
        CHECK (scope IN ('ALL','MATERIAL','EXPERIMENT')),
    granted_by bigint      NOT NULL REFERENCES person(person_id),
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    PRIMARY KEY (paper_id, person_id)
);

-- -----------------------------------------------------------------------------
-- 4. 物理文件、论文版本、材料与版本
--    大文件落文件系统，数据库只存元数据；SHA-256 用于完整性校验
-- -----------------------------------------------------------------------------

CREATE TABLE file_object (
    file_id       bigserial    PRIMARY KEY,
    storage_key   varchar(300) NOT NULL UNIQUE,   -- uploads/ 下的相对路径
    original_name varchar(255) NOT NULL,
    file_format   varchar(32),
    size_bytes    bigint       NOT NULL CHECK (size_bytes >= 0),
    sha256        char(64)     NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    uploaded_by   bigint       NOT NULL REFERENCES person(person_id),
    uploaded_at   timestamptz  NOT NULL DEFAULT now(),
    is_deleted    boolean      NOT NULL DEFAULT false
);

CREATE TABLE paper_version (
    paper_version_id bigserial   PRIMARY KEY,
    paper_id         bigint      NOT NULL REFERENCES paper(paper_id) ON DELETE CASCADE,
    version_no       integer     NOT NULL CHECK (version_no >= 1),
    stage            varchar(16) NOT NULL
        CHECK (stage IN ('DRAFT','SUBMISSION','REVISION','ACCEPTED','FINAL')),
    file_id          bigint      NOT NULL REFERENCES file_object(file_id),
    change_note      text,
    created_by       bigint      NOT NULL REFERENCES person(person_id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ux_paper_version_no UNIQUE (paper_id, version_no)
);

CREATE TABLE material (
    material_id    bigserial    PRIMARY KEY,
    paper_id       bigint       NOT NULL REFERENCES paper(paper_id) ON DELETE CASCADE,
    material_type  varchar(16)  NOT NULL
        CHECK (material_type IN ('PAPER','CODE','RAW_DATA','DATA_DICT','CONFIG','LOG','RESULT','FIGURE','NOTES')),
    name           varchar(200) NOT NULL,
    description    text,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT ux_material_name UNIQUE (paper_id, name)
);

CREATE TABLE material_version (
    material_version_id bigserial   PRIMARY KEY,
    material_id         bigint      NOT NULL REFERENCES material(material_id) ON DELETE CASCADE,
    version_no          integer     NOT NULL CHECK (version_no >= 1),
    file_id             bigint      NOT NULL REFERENCES file_object(file_id),
    sha256              char(64)    NOT NULL,     -- 冗余快照，由触发器从 file_object 同步
    change_note         text,
    created_by          bigint      NOT NULL REFERENCES person(person_id),
    created_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ux_material_version_no UNIQUE (material_id, version_no),
    CONSTRAINT ck_material_version_sha CHECK (sha256 ~ '^[0-9a-f]{64}$')
);

-- -----------------------------------------------------------------------------
-- 5. 实验任务、运行与结果
--    运行必须引用"确定的"代码/数据/日志版本，不得以最新版本替代
-- -----------------------------------------------------------------------------

CREATE TABLE experiment_task (
    task_id    bigserial    PRIMARY KEY,
    paper_id   bigint       NOT NULL REFERENCES paper(paper_id) ON DELETE CASCADE,
    title      varchar(200) NOT NULL,
    purpose    text,
    scheme     text,
    metrics    text,
    created_by bigint       NOT NULL REFERENCES person(person_id),
    created_at timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE experiment_run (
    run_id            bigserial   PRIMARY KEY,
    task_id           bigint      NOT NULL REFERENCES experiment_task(task_id) ON DELETE CASCADE,
    run_label         varchar(64) NOT NULL,
    code_version_id   bigint      NOT NULL REFERENCES material_version(material_version_id),
    data_version_id   bigint      NOT NULL REFERENCES material_version(material_version_id),
    config_version_id bigint      REFERENCES material_version(material_version_id),
    log_version_id    bigint      REFERENCES material_version(material_version_id),
    parameters        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    hardware_env      text,
    software_env      text,
    started_at        timestamptz NOT NULL,
    ended_at          timestamptz,
    status            varchar(16) NOT NULL DEFAULT 'RUNNING'
        CHECK (status IN ('RUNNING','SUCCESS','FAILED','ABORTED')),
    created_by        bigint      NOT NULL REFERENCES person(person_id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ux_run_label UNIQUE (task_id, run_label),
    CONSTRAINT ck_run_dates CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE TABLE experiment_result (
    result_id          bigserial   PRIMARY KEY,
    run_id             bigint      NOT NULL REFERENCES experiment_run(run_id) ON DELETE CASCADE,
    result_version_id  bigint      NOT NULL REFERENCES material_version(material_version_id),
    metric_summary     text,
    paper_figure_no    varchar(64),           -- 论文中的图表编号
    conclusion         text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ux_result_run_version UNIQUE (run_id, result_version_id)
);

-- -----------------------------------------------------------------------------
-- 6. 汇交批次：以快照冻结"这一次送审的确定内容"
-- -----------------------------------------------------------------------------

CREATE TABLE submission_batch (
    batch_id               bigserial    PRIMARY KEY,
    paper_id               bigint       NOT NULL REFERENCES paper(paper_id),
    round_no               integer      NOT NULL CHECK (round_no >= 1),
    institute_id           bigint       NOT NULL REFERENCES institute(institute_id),
    initiated_by           bigint       NOT NULL REFERENCES person(person_id),
    status                 varchar(24)  NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT','PENDING_AUTHORS','READY_TO_SUBMIT','PENDING_ADMIN',
                          'UNDER_REVIEW','DISPUTED','RETURNED','WITHDRAWN','ARCHIVED')),
    paper_version_id       bigint       REFERENCES paper_version(paper_version_id),

    -- 以下为冻结快照，发起确认后不可修改
    title_snapshot         varchar(300) NOT NULL,
    abstract_snapshot      text,
    keywords_snapshot      varchar(300),
    research_field_snapshot varchar(128),
    venue_snapshot         varchar(200),
    doi_snapshot           varchar(128),
    visibility_snapshot    varchar(16)  NOT NULL,
    owner_snapshot         bigint       NOT NULL REFERENCES person(person_id),
    author_count           integer      NOT NULL DEFAULT 0 CHECK (author_count >= 0),

    created_at             timestamptz  NOT NULL DEFAULT now(),
    frozen_at              timestamptz,
    submitted_at           timestamptz,
    ended_at               timestamptz,
    ended_reason           varchar(32),
    CONSTRAINT ux_batch_round UNIQUE (paper_id, round_no)
);

-- 每篇论文同一时间只允许一个未结束的批次
CREATE UNIQUE INDEX ux_batch_open
    ON submission_batch (paper_id)
    WHERE status IN ('DRAFT','PENDING_AUTHORS','READY_TO_SUBMIT','PENDING_ADMIN','UNDER_REVIEW');

CREATE TABLE batch_author (
    batch_id          bigint      NOT NULL REFERENCES submission_batch(batch_id) ON DELETE CASCADE,
    person_id         bigint      NOT NULL REFERENCES person(person_id),
    author_order      integer     NOT NULL CHECK (author_order >= 1),
    is_corresponding  boolean     NOT NULL DEFAULT false,
    is_external       boolean     NOT NULL DEFAULT false,
    is_owner          boolean     NOT NULL DEFAULT false,
    name_snapshot     varchar(64) NOT NULL,
    affiliation_snapshot varchar(200),
    PRIMARY KEY (batch_id, person_id),
    CONSTRAINT ux_batch_author_order UNIQUE (batch_id, author_order)
);

CREATE TABLE batch_material (
    batch_id              bigint       NOT NULL REFERENCES submission_batch(batch_id) ON DELETE CASCADE,
    material_version_id   bigint       NOT NULL REFERENCES material_version(material_version_id),
    material_type         varchar(16)  NOT NULL,
    material_name_snapshot varchar(200) NOT NULL,
    version_no_snapshot   integer      NOT NULL,
    sha256_snapshot       char(64)     NOT NULL,
    PRIMARY KEY (batch_id, material_version_id)
);

CREATE TABLE batch_experiment (
    batch_id bigint  NOT NULL REFERENCES submission_batch(batch_id) ON DELETE CASCADE,
    run_id   bigint  NOT NULL REFERENCES experiment_run(run_id),
    snapshot jsonb   NOT NULL,     -- 参数、环境、引用版本在发起确认时的快照
    PRIMARY KEY (batch_id, run_id)
);

-- -----------------------------------------------------------------------------
-- 7. 作者确认（历史 + 当前有效状态）
--    复合外键保证"确认人必须是本批次名单中的作者"
-- -----------------------------------------------------------------------------

CREATE TABLE confirmation (
    confirmation_id bigserial   PRIMARY KEY,
    batch_id        bigint      NOT NULL,
    person_id       bigint      NOT NULL,
    action          varchar(16) NOT NULL CHECK (action IN ('CONFIRM','WITHDRAW','DISPUTE')),
    comment         text,
    is_current      boolean     NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      bigint      NOT NULL REFERENCES person(person_id),
    CONSTRAINT fk_confirmation_batch_author
        FOREIGN KEY (batch_id, person_id) REFERENCES batch_author (batch_id, person_id) ON DELETE CASCADE,
    CONSTRAINT ck_dispute_reason CHECK (action <> 'DISPUTE' OR (comment IS NOT NULL AND btrim(comment) <> ''))
);

-- 同一批次同一作者至多一条当前有效确认
CREATE UNIQUE INDEX ux_confirmation_current
    ON confirmation (batch_id, person_id)
    WHERE is_current;

-- -----------------------------------------------------------------------------
-- 8. 管理员审核
-- -----------------------------------------------------------------------------

CREATE TABLE admin_review (
    review_id          bigserial   PRIMARY KEY,
    batch_id           bigint      NOT NULL REFERENCES submission_batch(batch_id) ON DELETE CASCADE,
    action             varchar(16) NOT NULL CHECK (action IN ('ACCEPT','APPROVE','RETURN')),
    reviewer_person_id bigint      NOT NULL REFERENCES person(person_id),
    comment            text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ux_batch_review_action UNIQUE (batch_id, action),
    CONSTRAINT ck_return_comment CHECK (action <> 'RETURN' OR (comment IS NOT NULL AND btrim(comment) <> ''))
);

-- -----------------------------------------------------------------------------
-- 9. 访问申请、授权、下载记录
-- -----------------------------------------------------------------------------

CREATE TABLE access_request (
    request_id           bigserial   PRIMARY KEY,
    requester_account_id bigint      NOT NULL REFERENCES account(account_id),
    material_version_id  bigint      NOT NULL REFERENCES material_version(material_version_id),
    reason               text        NOT NULL,
    status               varchar(16) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
    decided_by           bigint      REFERENCES person(person_id),
    decided_at           timestamptz,
    decision_comment     text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_request_decision CHECK (
        (status = 'PENDING' AND decided_by IS NULL AND decided_at IS NULL)
        OR (status IN ('APPROVED', 'REJECTED') AND decided_by IS NOT NULL AND decided_at IS NOT NULL)
        OR status = 'CANCELLED'
    ),
    CONSTRAINT ck_request_reason CHECK (btrim(reason) <> '')
);

-- 同一使用者对同一材料版本不能有两条待审批申请
CREATE UNIQUE INDEX ux_request_pending
    ON access_request (requester_account_id, material_version_id)
    WHERE status = 'PENDING';

CREATE TABLE access_grant (
    grant_id             bigserial   PRIMARY KEY,
    request_id           bigint      NOT NULL UNIQUE REFERENCES access_request(request_id),
    account_id           bigint      NOT NULL REFERENCES account(account_id),
    material_version_id  bigint      NOT NULL REFERENCES material_version(material_version_id),
    scope                varchar(16) NOT NULL DEFAULT 'DOWNLOAD' CHECK (scope IN ('VIEW','DOWNLOAD')),
    valid_from           timestamptz NOT NULL DEFAULT now(),
    valid_to             timestamptz NOT NULL,
    revoked_at           timestamptz,
    revoked_by           bigint      REFERENCES person(person_id),
    download_count       integer     NOT NULL DEFAULT 0 CHECK (download_count >= 0),
    max_downloads        integer     CHECK (max_downloads IS NULL OR max_downloads > 0),
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_grant_valid CHECK (valid_to > valid_from)
);

CREATE TABLE access_log (
    access_log_id       bigserial   PRIMARY KEY,
    account_id          bigint      NOT NULL REFERENCES account(account_id),
    material_version_id bigint      NOT NULL REFERENCES material_version(material_version_id),
    grant_id            bigint      REFERENCES access_grant(grant_id),
    action              varchar(16) NOT NULL CHECK (action IN ('VIEW','DOWNLOAD','DENIED')),
    detail              text,
    created_at          timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 10. 审计、通知、邮件发件箱（提高项：邮件提醒）
-- -----------------------------------------------------------------------------

CREATE TABLE audit_log (
    audit_id        bigserial   PRIMARY KEY,
    actor_person_id bigint      REFERENCES person(person_id),
    object_type     varchar(32) NOT NULL,
    object_id       varchar(64) NOT NULL,
    action          varchar(32) NOT NULL,
    summary         jsonb,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE notification (
    notification_id bigserial    PRIMARY KEY,
    account_id      bigint       NOT NULL REFERENCES account(account_id) ON DELETE CASCADE,
    category        varchar(32)  NOT NULL,
    title           varchar(200) NOT NULL,
    body            text,
    link_url        varchar(300),
    created_at      timestamptz  NOT NULL DEFAULT now(),
    read_at         timestamptz
);

CREATE TABLE mail_outbox (
    mail_id      bigserial    PRIMARY KEY,
    to_email     varchar(128) NOT NULL,
    subject      varchar(200) NOT NULL,
    body         text,
    related_type varchar(32),
    related_id   bigint,
    status       varchar(16)  NOT NULL DEFAULT 'QUEUED'
        CHECK (status IN ('QUEUED','SENT','FAILED')),
    created_at   timestamptz  NOT NULL DEFAULT now(),
    sent_at      timestamptz
);

-- -----------------------------------------------------------------------------
-- 表注释（数据字典摘录）
-- -----------------------------------------------------------------------------
COMMENT ON TABLE submission_batch IS '汇交批次：一次送审的冻结内容，终止状态不可再变';
COMMENT ON TABLE batch_author       IS '批次作者快照：确认资格与作者总人数以此为准';
COMMENT ON TABLE batch_material     IS '批次材料版本快照：不得引用最新版本';
COMMENT ON TABLE confirmation       IS '作者确认流水：is_current 标记当前有效状态，历史不可删除';
COMMENT ON TABLE admin_review       IS '管理员受理/通过/退回记录，每批次每种结论唯一';
COMMENT ON TABLE access_grant       IS '按材料版本的授权，新增版本不自动继承';
COMMENT ON COLUMN material_version.sha256 IS '冗余字段，由 trg_material_version_sha256 从 file_object 同步';
COMMENT ON COLUMN submission_batch.author_count IS '冻结时的作者总数，用于全员确认校验';
