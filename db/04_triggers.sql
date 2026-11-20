-- =============================================================================
--  04_triggers.sql  —— 触发器
--  职责划分：
--    * 存储过程：业务流程、权限、状态机
--    * 触发器 ：不可绕过的数据完整性（冻结、快照一致性、类型校验、审计留痕）
--  即使有人直接写 SQL，也必须满足以下约束。
-- =============================================================================
SET search_path TO srdp, public;

-- -----------------------------------------------------------------------------
-- 1. 论文 updated_at 自动维护
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_paper_touch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_paper_touch
    BEFORE UPDATE ON paper
    FOR EACH ROW EXECUTE FUNCTION trg_paper_touch();

-- -----------------------------------------------------------------------------
-- 2. 材料版本 SHA-256 冗余字段：强制与 file_object 一致
--    （体现"采用冗余字段时的维护方法"）
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_material_version_sha256() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_sha char(64);
BEGIN
    SELECT sha256 INTO v_sha FROM file_object WHERE file_id = NEW.file_id;
    IF v_sha IS NULL THEN
        RAISE EXCEPTION '文件 % 不存在', NEW.file_id;
    END IF;
    IF NEW.sha256 IS NULL THEN
        NEW.sha256 := v_sha;
    ELSIF NEW.sha256 <> v_sha THEN
        RAISE EXCEPTION '材料版本 SHA-256 与文件不一致（% <> %）', NEW.sha256, v_sha;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_material_version_sha256
    BEFORE INSERT ON material_version
    FOR EACH ROW EXECUTE FUNCTION trg_material_version_sha256();

-- -----------------------------------------------------------------------------
-- 3. 历史不可原地覆盖：论文版本 / 材料版本 / 审核记录 / 审计日志 只增不改
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_immutable_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% 为历史记录，不允许 %（请新增版本或新增记录）', TG_TABLE_NAME,
        CASE TG_OP WHEN 'UPDATE' THEN '修改' ELSE '删除' END;
END;
$$;

CREATE TRIGGER trg_paper_version_immutable
    BEFORE UPDATE OR DELETE ON paper_version
    FOR EACH ROW EXECUTE FUNCTION trg_immutable_guard();

CREATE TRIGGER trg_material_version_immutable
    BEFORE UPDATE OR DELETE ON material_version
    FOR EACH ROW EXECUTE FUNCTION trg_immutable_guard();

CREATE TRIGGER trg_admin_review_immutable
    BEFORE UPDATE OR DELETE ON admin_review
    FOR EACH ROW EXECUTE FUNCTION trg_immutable_guard();

CREATE TRIGGER trg_audit_log_immutable
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION trg_immutable_guard();

-- 确认记录只允许 is_current 变化，业务字段不可改
CREATE OR REPLACE FUNCTION trg_confirmation_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '确认记录不允许删除';
    END IF;
    IF (NEW.batch_id, NEW.person_id, NEW.action, NEW.comment, NEW.created_at, NEW.created_by)
       IS DISTINCT FROM
       (OLD.batch_id, OLD.person_id, OLD.action, OLD.comment, OLD.created_at, OLD.created_by) THEN
        RAISE EXCEPTION '确认记录只能变更 is_current，历史内容不可修改';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_confirmation_immutable
    BEFORE UPDATE OR DELETE ON confirmation
    FOR EACH ROW EXECUTE FUNCTION trg_confirmation_immutable();

-- -----------------------------------------------------------------------------
-- 4. 同一批次同一作者仅一条当前有效确认（触发器兜底，唯一索引再次兜底）
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_confirmation_single_current() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.is_current THEN
        UPDATE confirmation SET is_current = false
         WHERE batch_id = NEW.batch_id
           AND person_id = NEW.person_id
           AND is_current
           AND confirmation_id <> NEW.confirmation_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_confirmation_single_current
    BEFORE INSERT ON confirmation
    FOR EACH ROW EXECUTE FUNCTION trg_confirmation_single_current();

-- 确认只能发生在确认阶段；批次结束后不得再改确认
CREATE OR REPLACE FUNCTION trg_confirmation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM submission_batch WHERE batch_id = NEW.batch_id;
    IF v_status NOT IN ('PENDING_AUTHORS', 'READY_TO_SUBMIT') THEN
        RAISE EXCEPTION '批次状态 % 不允许写入确认记录', v_status;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_confirmation_guard
    BEFORE INSERT ON confirmation
    FOR EACH ROW EXECUTE FUNCTION trg_confirmation_guard();

-- -----------------------------------------------------------------------------
-- 5. 批次状态机：非法流转在任何入口都会被拒绝
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_batch_status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status IN ('DISPUTED','RETURNED','WITHDRAWN','ARCHIVED') THEN
        RAISE EXCEPTION '批次已结束（%），不得再改变状态', OLD.status;
    END IF;

    IF NOT (
           (OLD.status = 'DRAFT'          AND NEW.status IN ('PENDING_AUTHORS','WITHDRAWN'))
        OR (OLD.status = 'PENDING_AUTHORS' AND NEW.status IN ('READY_TO_SUBMIT','PENDING_AUTHORS','DISPUTED','WITHDRAWN'))
        OR (OLD.status = 'READY_TO_SUBMIT' AND NEW.status IN ('PENDING_AUTHORS','PENDING_ADMIN','DISPUTED','WITHDRAWN'))
        OR (OLD.status = 'PENDING_ADMIN'   AND NEW.status IN ('UNDER_REVIEW','WITHDRAWN'))
        OR (OLD.status = 'UNDER_REVIEW'    AND NEW.status IN ('ARCHIVED','RETURNED'))
    ) THEN
        RAISE EXCEPTION '非法的批次状态流转：% -> %', OLD.status, NEW.status;
    END IF;

    IF NEW.status IN ('DISPUTED','RETURNED','WITHDRAWN','ARCHIVED') AND NEW.ended_at IS NULL THEN
        RAISE EXCEPTION '批次进入终止状态时必须记录结束时间';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_status_guard
    BEFORE UPDATE OF status ON submission_batch
    FOR EACH ROW EXECUTE FUNCTION trg_batch_status_guard();

-- -----------------------------------------------------------------------------
-- 6. 冻结保护：发起确认后快照不可修改
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_batch_frozen_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'DRAFT' OR OLD.frozen_at IS NULL THEN
        RETURN NEW;
    END IF;

    IF (NEW.paper_id, NEW.round_no, NEW.institute_id, NEW.paper_version_id,
        NEW.title_snapshot, NEW.abstract_snapshot, NEW.keywords_snapshot,
        NEW.research_field_snapshot, NEW.venue_snapshot, NEW.doi_snapshot,
        NEW.visibility_snapshot, NEW.owner_snapshot, NEW.author_count,
        NEW.initiated_by, NEW.frozen_at, NEW.created_at)
       IS DISTINCT FROM
       (OLD.paper_id, OLD.round_no, OLD.institute_id, OLD.paper_version_id,
        OLD.title_snapshot, OLD.abstract_snapshot, OLD.keywords_snapshot,
        OLD.research_field_snapshot, OLD.venue_snapshot, OLD.doi_snapshot,
        OLD.visibility_snapshot, OLD.owner_snapshot, OLD.author_count,
        OLD.initiated_by, OLD.frozen_at, OLD.created_at) THEN
        RAISE EXCEPTION '批次已冻结，快照内容不可修改；如需变更请创建新批次';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_frozen_guard
    BEFORE UPDATE ON submission_batch
    FOR EACH ROW EXECUTE FUNCTION trg_batch_frozen_guard();

-- 只允许删除草稿批次
CREATE OR REPLACE FUNCTION trg_batch_delete_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'DRAFT' THEN
        RAISE EXCEPTION '只有草稿批次可以删除，历史批次必须保留';
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_batch_delete_guard
    BEFORE DELETE ON submission_batch
    FOR EACH ROW EXECUTE FUNCTION trg_batch_delete_guard();

-- 论文版本必须属于同一篇论文
CREATE OR REPLACE FUNCTION trg_batch_paper_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.paper_version_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM paper_version
         WHERE paper_version_id = NEW.paper_version_id AND paper_id = NEW.paper_id
    ) THEN
        RAISE EXCEPTION '论文版本 % 不属于论文 %', NEW.paper_version_id, NEW.paper_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_paper_version_guard
    BEFORE INSERT OR UPDATE OF paper_version_id ON submission_batch
    FOR EACH ROW EXECUTE FUNCTION trg_batch_paper_version_guard();

-- -----------------------------------------------------------------------------
-- 7. 批次子表（作者/材料/实验）：仅草稿可改
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_batch_child_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_batch_id bigint;
    v_status   text;
BEGIN
    v_batch_id := COALESCE(NEW.batch_id, OLD.batch_id);
    SELECT status INTO v_status FROM submission_batch WHERE batch_id = v_batch_id;
    IF v_status IS NULL THEN
        RAISE EXCEPTION '批次 % 不存在', v_batch_id;
    END IF;
    IF v_status <> 'DRAFT' THEN
        RAISE EXCEPTION '批次已冻结（%），不能修改作者、材料或实验清单', v_status;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_batch_author_guard
    BEFORE INSERT OR UPDATE OR DELETE ON batch_author
    FOR EACH ROW EXECUTE FUNCTION trg_batch_child_guard();

CREATE TRIGGER trg_batch_material_guard
    BEFORE INSERT OR UPDATE OR DELETE ON batch_material
    FOR EACH ROW EXECUTE FUNCTION trg_batch_child_guard();

CREATE TRIGGER trg_batch_experiment_guard
    BEFORE INSERT OR UPDATE OR DELETE ON batch_experiment
    FOR EACH ROW EXECUTE FUNCTION trg_batch_child_guard();

-- -----------------------------------------------------------------------------
-- 8. 批次材料快照必须来自同一论文的真实版本（快照字段不可伪造）
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_batch_material_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v record;
    v_paper bigint;
BEGIN
    SELECT mv.version_no, mv.sha256, m.material_type, m.name, m.paper_id
      INTO v
      FROM material_version mv
      JOIN material m ON m.material_id = mv.material_id
     WHERE mv.material_version_id = NEW.material_version_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '材料版本 % 不存在', NEW.material_version_id;
    END IF;

    SELECT paper_id INTO v_paper FROM submission_batch WHERE batch_id = NEW.batch_id;
    IF v.paper_id <> v_paper THEN
        RAISE EXCEPTION '不能把论文 % 的材料 % 放入论文 % 的批次',
            v.paper_id, NEW.material_version_id, v_paper;
    END IF;

    NEW.material_type         := v.material_type;
    NEW.material_name_snapshot := v.name;
    NEW.version_no_snapshot   := v.version_no;
    NEW.sha256_snapshot       := v.sha256;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_material_snapshot
    BEFORE INSERT OR UPDATE ON batch_material
    FOR EACH ROW EXECUTE FUNCTION trg_batch_material_snapshot();

-- -----------------------------------------------------------------------------
-- 9. 实验引用类型与论文一致性
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_run_material_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_paper bigint;
    v_type  text;
BEGIN
    SELECT paper_id INTO v_paper FROM experiment_task WHERE task_id = NEW.task_id;

    SELECT m.paper_id, m.material_type INTO v_paper, v_type
      FROM material_version mv JOIN material m ON m.material_id = mv.material_id
     WHERE mv.material_version_id = NEW.code_version_id;
    IF v_type IS DISTINCT FROM 'CODE' THEN
        RAISE EXCEPTION '代码版本类型必须为 CODE，实际为 %', v_type;
    END IF;
    IF (SELECT paper_id FROM experiment_task WHERE task_id = NEW.task_id) <> v_paper THEN
        RAISE EXCEPTION '代码版本不属于该实验所属论文';
    END IF;

    SELECT m.paper_id, m.material_type INTO v_paper, v_type
      FROM material_version mv JOIN material m ON m.material_id = mv.material_id
     WHERE mv.material_version_id = NEW.data_version_id;
    IF v_type IS DISTINCT FROM 'RAW_DATA' THEN
        RAISE EXCEPTION '数据版本类型必须为 RAW_DATA，实际为 %', v_type;
    END IF;
    IF (SELECT paper_id FROM experiment_task WHERE task_id = NEW.task_id) <> v_paper THEN
        RAISE EXCEPTION '数据版本不属于该实验所属论文';
    END IF;

    IF NEW.config_version_id IS NOT NULL THEN
        SELECT m.paper_id, m.material_type INTO v_paper, v_type
          FROM material_version mv JOIN material m ON m.material_id = mv.material_id
         WHERE mv.material_version_id = NEW.config_version_id;
        IF v_type IS DISTINCT FROM 'CONFIG' OR v_paper <> (SELECT paper_id FROM experiment_task WHERE task_id = NEW.task_id) THEN
            RAISE EXCEPTION '配置版本类型或所属论文不正确';
        END IF;
    END IF;

    IF NEW.log_version_id IS NOT NULL THEN
        SELECT m.paper_id, m.material_type INTO v_paper, v_type
          FROM material_version mv JOIN material m ON m.material_id = mv.material_id
         WHERE mv.material_version_id = NEW.log_version_id;
        IF v_type IS DISTINCT FROM 'LOG' OR v_paper <> (SELECT paper_id FROM experiment_task WHERE task_id = NEW.task_id) THEN
            RAISE EXCEPTION '日志版本类型或所属论文不正确';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_run_material_guard
    BEFORE INSERT OR UPDATE ON experiment_run
    FOR EACH ROW EXECUTE FUNCTION trg_run_material_guard();

CREATE OR REPLACE FUNCTION trg_result_material_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_paper bigint;
    v_type  text;
BEGIN
    SELECT m.paper_id, m.material_type INTO v_paper, v_type
      FROM material_version mv JOIN material m ON m.material_id = mv.material_id
     WHERE mv.material_version_id = NEW.result_version_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '结果材料版本不存在';
    END IF;
    IF v_type NOT IN ('RESULT','FIGURE') THEN
        RAISE EXCEPTION '结果材料类型必须为 RESULT 或 FIGURE，实际为 %', v_type;
    END IF;
    IF v_paper <> (SELECT t.paper_id FROM experiment_run r
                     JOIN experiment_task t ON t.task_id = r.task_id
                    WHERE r.run_id = NEW.run_id) THEN
        RAISE EXCEPTION '结果文件不属于该实验所属论文';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_result_material_guard
    BEFORE INSERT OR UPDATE ON experiment_result
    FOR EACH ROW EXECUTE FUNCTION trg_result_material_guard();

-- -----------------------------------------------------------------------------
-- 10. 审核记录必须与批次状态匹配
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_review_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM submission_batch WHERE batch_id = NEW.batch_id;
    IF NEW.action = 'ACCEPT' AND v_status <> 'PENDING_ADMIN' THEN
        RAISE EXCEPTION '只有待审核批次可以受理（当前 %）', v_status;
    END IF;
    IF NEW.action IN ('APPROVE','RETURN') AND v_status <> 'UNDER_REVIEW' THEN
        RAISE EXCEPTION '只有审核中的批次可以作出审核结论（当前 %）', v_status;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_review_guard
    BEFORE INSERT ON admin_review
    FOR EACH ROW EXECUTE FUNCTION trg_review_guard();

-- -----------------------------------------------------------------------------
-- 11. 授权必须来自已批准的申请
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_grant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_req access_request%ROWTYPE;
BEGIN
    SELECT * INTO v_req FROM access_request WHERE request_id = NEW.request_id;
    IF NOT FOUND OR v_req.status <> 'APPROVED' THEN
        RAISE EXCEPTION '授权只能基于已批准的访问申请';
    END IF;
    IF v_req.material_version_id <> NEW.material_version_id
       OR v_req.requester_account_id <> NEW.account_id THEN
        RAISE EXCEPTION '授权范围必须与申请一致';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_grant_guard
    BEFORE INSERT ON access_grant
    FOR EACH ROW EXECUTE FUNCTION trg_grant_guard();

-- -----------------------------------------------------------------------------
-- 12. 审计触发器：确认、材料新增版本、审核结论
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit_confirmation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (actor_person_id, object_type, object_id, action, summary)
    VALUES (NEW.created_by, 'confirmation',
            NEW.batch_id::text || ':' || NEW.person_id::text,
            NEW.action,
            jsonb_build_object('confirmation_id', NEW.confirmation_id,
                               'is_current', NEW.is_current,
                               'comment', NEW.comment));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_confirmation
    AFTER INSERT ON confirmation
    FOR EACH ROW EXECUTE FUNCTION trg_audit_confirmation();

CREATE OR REPLACE FUNCTION trg_audit_material_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (actor_person_id, object_type, object_id, action, summary)
    VALUES (NEW.created_by, 'material_version', NEW.material_version_id::text, 'NEW_VERSION',
            jsonb_build_object('material_id', NEW.material_id,
                               'version_no', NEW.version_no,
                               'sha256', NEW.sha256,
                               'file_id', NEW.file_id));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_material_version
    AFTER INSERT ON material_version
    FOR EACH ROW EXECUTE FUNCTION trg_audit_material_version();

CREATE OR REPLACE FUNCTION trg_audit_review() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (actor_person_id, object_type, object_id, action, summary)
    VALUES (NEW.reviewer_person_id, 'admin_review', NEW.review_id::text, NEW.action,
            jsonb_build_object('batch_id', NEW.batch_id, 'comment', NEW.comment));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_review
    AFTER INSERT ON admin_review
    FOR EACH ROW EXECUTE FUNCTION trg_audit_review();

-- 角色授予 / 撤销留痕
CREATE OR REPLACE FUNCTION trg_audit_role() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (actor_person_id, object_type, object_id, action, summary)
    VALUES (COALESCE(NEW.granted_by, OLD.granted_by),
            'account_role',
            COALESCE(NEW.account_role_id, OLD.account_role_id)::text,
            CASE WHEN TG_OP = 'INSERT' THEN 'GRANT' ELSE 'UPDATE' END,
            jsonb_build_object('account_id', COALESCE(NEW.account_id, OLD.account_id),
                               'role_code', COALESCE(NEW.role_code, OLD.role_code),
                               'institute_id', COALESCE(NEW.institute_id, OLD.institute_id),
                               'is_active', COALESCE(NEW.is_active, OLD.is_active)));
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_audit_role
    AFTER INSERT OR UPDATE ON account_role
    FOR EACH ROW EXECUTE FUNCTION trg_audit_role();

-- 访问申请审批留痕（除存储过程外，任何直接更新也留痕）
CREATE OR REPLACE FUNCTION trg_audit_access_decision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> OLD.status AND NEW.status IN ('APPROVED','REJECTED') THEN
        INSERT INTO audit_log (actor_person_id, object_type, object_id, action, summary)
        VALUES (NEW.decided_by, 'access_request', NEW.request_id::text, NEW.status,
                jsonb_build_object('comment', NEW.decision_comment));
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_access_decision
    AFTER UPDATE ON access_request
    FOR EACH ROW EXECUTE FUNCTION trg_audit_access_decision();
