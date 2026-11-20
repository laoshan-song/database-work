"""约束与触发器兜底测试：即使绕过应用层直接写库，也必须被数据库拒绝。"""
from __future__ import annotations

import psycopg
import pytest


def account_id(db, username):
    return db.execute(
        "SELECT account_id FROM account WHERE username = %s", (username,)
    ).fetchone()["account_id"]


def material_version_of(db, paper_id, material_type=None):
    sql = [
        """
        SELECT mv.material_version_id
          FROM material_version mv
          JOIN material m ON m.material_id = mv.material_id
         WHERE m.paper_id = %s
        """
    ]
    params = [paper_id]
    if material_type:
        sql.append(" AND m.material_type = %s")
        params.append(material_type)
    sql.append(" ORDER BY mv.version_no DESC LIMIT 1")
    return db.execute("".join(sql), params).fetchone()["material_version_id"]


# ---------------------------------------------------------------------------
# 冻结与状态机
# ---------------------------------------------------------------------------
def test_frozen_batch_snapshot_and_children_are_immutable(db, ready_batch):
    _, batch_id = ready_batch()

    with pytest.raises(psycopg.Error, match="冻结"):
        db.execute(
            "UPDATE submission_batch SET title_snapshot = '被篡改的标题' WHERE batch_id = %s",
            (batch_id,),
        )
    with pytest.raises(psycopg.Error, match="冻结"):
        db.execute(
            "UPDATE batch_author SET name_snapshot = '匿名' WHERE batch_id = %s",
            (batch_id,),
        )
    with pytest.raises(psycopg.Error, match="冻结"):
        db.execute("DELETE FROM batch_material WHERE batch_id = %s", (batch_id,))

    # 快照本身没有被改动
    title = db.execute(
        "SELECT title_snapshot FROM submission_batch WHERE batch_id = %s", (batch_id,)
    ).fetchone()["title_snapshot"]
    assert "被篡改" not in title


def test_illegal_status_transition_rejected(db, draft_batch):
    _, batch_id = draft_batch()
    with pytest.raises(psycopg.Error, match="非法的批次状态流转"):
        db.execute(
            "UPDATE submission_batch SET status = 'ARCHIVED', ended_at = now() WHERE batch_id = %s",
            (batch_id,),
        )

    # 已归档批次不可再被改回进行中（seed 批次 2 为已归档）
    with pytest.raises(psycopg.Error, match="已结束"):
        db.execute(
            "UPDATE submission_batch SET status = 'PENDING_AUTHORS' WHERE batch_id = 2"
        )

    # 非草稿批次不可删除
    with pytest.raises(psycopg.Error, match="只有草稿批次可以删除"):
        db.execute("DELETE FROM submission_batch WHERE batch_id = 2")


def test_only_one_open_batch_per_paper(db, draft_batch):
    paper_id, _ = draft_batch()
    result = db.execute(
        "SELECT * FROM sp_create_batch(%s, %s, NULL)", (paper_id, 2)
    ).fetchone()
    assert not result["ok"]
    assert result["code"] == "OPEN_BATCH_EXISTS"


# ---------------------------------------------------------------------------
# 历史记录只增不改
# ---------------------------------------------------------------------------
def test_material_version_is_immutable(db, make_paper):
    paper_id = make_paper()
    mv_id = material_version_of(db, paper_id)

    with pytest.raises(psycopg.Error, match="历史记录"):
        db.execute(
            "UPDATE material_version SET change_note = '改写历史' WHERE material_version_id = %s",
            (mv_id,),
        )
    with pytest.raises(psycopg.Error, match="历史记录"):
        db.execute(
            "DELETE FROM material_version WHERE material_version_id = %s", (mv_id,)
        )


def test_confirmation_history_is_append_only(db, ready_batch):
    _, batch_id = ready_batch()
    row = db.execute(
        "SELECT confirmation_id FROM confirmation WHERE batch_id = %s ORDER BY confirmation_id LIMIT 1",
        (batch_id,),
    ).fetchone()

    with pytest.raises(psycopg.Error, match="确认记录只能变更 is_current"):
        db.execute(
            "UPDATE confirmation SET comment = '改写意见' WHERE confirmation_id = %s",
            (row["confirmation_id"],),
        )
    with pytest.raises(psycopg.Error, match="确认记录不允许删除"):
        db.execute(
            "DELETE FROM confirmation WHERE confirmation_id = %s",
            (row["confirmation_id"],),
        )


def test_audit_log_is_immutable(db):
    audit_id = db.execute("SELECT audit_id FROM audit_log ORDER BY audit_id LIMIT 1").fetchone()[
        "audit_id"
    ]
    with pytest.raises(psycopg.Error, match="历史记录"):
        db.execute("UPDATE audit_log SET action = 'FAKE' WHERE audit_id = %s", (audit_id,))
    with pytest.raises(psycopg.Error, match="历史记录"):
        db.execute("DELETE FROM audit_log WHERE audit_id = %s", (audit_id,))


# ---------------------------------------------------------------------------
# 确认阶段的规则
# ---------------------------------------------------------------------------
def test_confirmation_rules(db, draft_batch):
    _, batch_id = draft_batch()
    assert db.execute(
        "SELECT * FROM sp_start_confirmation(%s, %s)", (batch_id, 2)
    ).fetchone()["ok"]

    # 非作者（数据使用者孙浩）不能确认
    result = db.execute(
        "SELECT * FROM sp_record_confirmation(%s, %s, 'CONFIRM', NULL)", (batch_id, 6)
    ).fetchone()
    assert not result["ok"] and result["code"] == "NOT_BATCH_AUTHOR"

    # 异议必须写理由
    result = db.execute(
        "SELECT * FROM sp_record_confirmation(%s, %s, 'DISPUTE', '  ')", (batch_id, 3)
    ).fetchone()
    assert not result["ok"] and result["code"] == "REASON_REQUIRED"

    # 未确认时不能撤回
    result = db.execute(
        "SELECT * FROM sp_record_confirmation(%s, %s, 'WITHDRAW', NULL)", (batch_id, 3)
    ).fetchone()
    assert not result["ok"] and result["code"] == "NOT_CONFIRMED"

    # 异议后本轮结束
    result = db.execute(
        "SELECT * FROM sp_record_confirmation(%s, %s, 'DISPUTE', '材料版本不对')",
        (batch_id, 3),
    ).fetchone()
    assert result["ok"] and result["code"] == "DISPUTED"
    status = db.execute(
        "SELECT status FROM submission_batch WHERE batch_id = %s", (batch_id,)
    ).fetchone()["status"]
    assert status == "DISPUTED"


def test_archived_batch_rejects_direct_confirmation_insert(db):
    with pytest.raises(psycopg.Error, match="不允许写入确认记录"):
        db.execute(
            """
            INSERT INTO confirmation (batch_id, person_id, action, is_current, created_by)
            VALUES (2, 2, 'CONFIRM', true, 2)
            """
        )


def test_submit_requires_all_material_types(db, draft_batch):
    _, batch_id = draft_batch()
    # 冻结前先删掉一类材料（冻结后子表写入会被触发器拒绝）
    db.execute(
        "DELETE FROM batch_material WHERE batch_id = %s AND material_type = 'CONFIG'",
        (batch_id,),
    )
    assert db.execute(
        "SELECT * FROM sp_start_confirmation(%s, %s)", (batch_id, 2)
    ).fetchone()["ok"]
    for person_id in (2, 3, 4, 5):
        result = db.execute(
            "SELECT * FROM sp_record_confirmation(%s, %s, 'CONFIRM', 'ok')",
            (batch_id, person_id),
        ).fetchone()
        assert result["ok"], result["message"]

    result = db.execute(
        "SELECT * FROM sp_submit_batch(%s, %s)", (batch_id, 2)
    ).fetchone()
    assert not result["ok"] and result["code"] == "MISSING_MATERIAL"
    assert "CONFIG" in result["message"]


def test_cross_paper_material_rejected(db, draft_batch, make_paper):
    paper_a, batch_id = draft_batch()
    paper_b = make_paper()
    mv_b = material_version_of(db, paper_b)

    with pytest.raises(psycopg.Error, match="不能把论文"):
        db.execute(
            """
            INSERT INTO batch_material (batch_id, material_version_id, material_type,
                                        material_name_snapshot, version_no_snapshot, sha256_snapshot)
            VALUES (%s, %s, 'CODE', 'x', 1, repeat('0', 64))
            """,
            (batch_id, mv_b),
        )


def test_snapshot_is_taken_from_real_material_version(db, draft_batch):
    """伪造的 sha/名称会被触发器用真实版本覆盖。"""
    paper_id, batch_id = draft_batch()
    mv = material_version_of(db, paper_id)
    db.execute("DELETE FROM batch_material WHERE batch_id = %s", (batch_id,))
    db.execute(
        """
        INSERT INTO batch_material (batch_id, material_version_id, material_type,
                                    material_name_snapshot, version_no_snapshot, sha256_snapshot)
        VALUES (%s, %s, 'CODE', '伪造名称', 99, repeat('f', 64))
        """,
        (batch_id, mv),
    )
    row = db.execute(
        """
        SELECT bm.material_name_snapshot, bm.version_no_snapshot, bm.sha256_snapshot,
               mv.version_no, mv.sha256
          FROM batch_material bm
          JOIN material_version mv ON mv.material_version_id = bm.material_version_id
         WHERE bm.batch_id = %s AND bm.material_version_id = %s
        """,
        (batch_id, mv),
    ).fetchone()
    assert row["material_name_snapshot"] != "伪造名称"
    assert row["version_no_snapshot"] == row["version_no"]
    assert row["sha256_snapshot"].strip() == row["sha256"]


# ---------------------------------------------------------------------------
# 访问申请 / 授权
# ---------------------------------------------------------------------------
def test_apply_access_rejects_duplicate_pending(db, make_paper):
    paper_id = make_paper(institute_id=2, owner=8, authors=(8,))
    mv = material_version_of(db, paper_id)
    acc = account_id(db, "sunhao")

    first = db.execute(
        "SELECT * FROM sp_apply_access(%s, %s, '用于方法对比')", (acc, mv)
    ).fetchone()
    assert first["ok"], first["message"]

    second = db.execute(
        "SELECT * FROM sp_apply_access(%s, %s, '重复申请')", (acc, mv)
    ).fetchone()
    assert not second["ok"]
    assert second["code"] == "ALREADY_PENDING"

    # 空理由被拒绝
    third = db.execute(
        "SELECT * FROM sp_apply_access(%s, %s, '   ')", (acc, mv)
    ).fetchone()
    assert not third["ok"] and third["code"] == "REASON_REQUIRED"


def test_grant_requires_approved_request(db, make_paper):
    paper_id = make_paper(institute_id=2, owner=8, authors=(8,))
    mv = material_version_of(db, paper_id)
    acc = account_id(db, "sunhao")
    request_id = db.execute(
        """
        INSERT INTO access_request (requester_account_id, material_version_id, reason)
        VALUES (%s, %s, '测试未批准授权') RETURNING request_id
        """,
        (acc, mv),
    ).fetchone()["request_id"]

    with pytest.raises(psycopg.Error, match="已批准的访问申请"):
        db.execute(
            """
            INSERT INTO access_grant (request_id, account_id, material_version_id, valid_to)
            VALUES (%s, %s, %s, now() + interval '1 day')
            """,
            (request_id, acc, mv),
        )


def test_access_approval_only_by_host_institute_admin(db, make_paper):
    paper_id = make_paper(institute_id=2, owner=8, authors=(8,))
    mv = material_version_of(db, paper_id)
    acc = account_id(db, "sunhao")
    request_id = db.execute(
        """
        INSERT INTO access_request (requester_account_id, material_version_id, reason)
        VALUES (%s, %s, '审批权限测试') RETURNING request_id
        """,
        (acc, mv),
    ).fetchone()["request_id"]

    # 论文属于 INST-02，INST-01 管理员（张伟）无权审批
    denied = db.execute(
        "SELECT * FROM sp_decide_access(%s, %s, true, '越权', 7, 3)", (request_id, 1)
    ).fetchone()
    assert not denied["ok"] and denied["code"] == "FORBIDDEN"

    # INST-02 管理员（郑凯）审批通过
    approved = db.execute(
        "SELECT * FROM sp_decide_access(%s, %s, true, '同意', 3, 2)", (request_id, 9)
    ).fetchone()
    assert approved["ok"], approved["message"]

    grant = db.execute(
        """
        SELECT * FROM v_access_grant_status
         WHERE request_id = %s
        """,
        (request_id,),
    ).fetchone()
    assert grant["grant_status"] == "ACTIVE"
    assert grant["max_downloads"] == 2
    assert grant["download_count"] == 0
    assert grant["valid_to"] > grant["valid_from"]

    # 超过次数后被拒绝
    for _ in range(2):
        result = db.execute(
            "SELECT * FROM sp_register_download(%s, '10.0.0.1')", (grant["grant_id"],)
        ).fetchone()
        assert result["ok"], result["message"]
    exhausted = db.execute(
        "SELECT * FROM sp_register_download(%s, '10.0.0.1')", (grant["grant_id"],)
    ).fetchone()
    assert not exhausted["ok"] and exhausted["code"] == "EXHAUSTED"

    # 撤销后不可再下载
    revoked = db.execute(
        "SELECT * FROM sp_revoke_grant(%s, %s, '测试撤销')", (grant["grant_id"], 9)
    ).fetchone()
    assert revoked["ok"]
    after = db.execute(
        "SELECT * FROM sp_register_download(%s, '10.0.0.1')", (grant["grant_id"],)
    ).fetchone()
    assert not after["ok"] and after["code"] == "REVOKED"


def test_maintainer_cannot_confirm(db, draft_batch):
    """维护成员可以整理材料，但没有作者确认权。"""
    paper_id, batch_id = draft_batch()
    assert db.execute(
        "SELECT * FROM sp_grant_maintainer(%s, %s, 'ALL', %s)", (paper_id, 6, 2)
    ).fetchone()["ok"]
    assert db.execute(
        "SELECT * FROM sp_start_confirmation(%s, %s)", (batch_id, 2)
    ).fetchone()["ok"]

    result = db.execute(
        "SELECT * FROM sp_record_confirmation(%s, %s, 'CONFIRM', NULL)", (batch_id, 6)
    ).fetchone()
    assert not result["ok"] and result["code"] == "NOT_BATCH_AUTHOR"


# ---------------------------------------------------------------------------
# 页面权限：授权使用者可直接查看材料详情与下载
# ---------------------------------------------------------------------------
def test_grant_holder_can_view_and_download_material(client, login, db):
    mv = db.execute(
        """
        SELECT mv.material_version_id
          FROM material_version mv
          JOIN material m ON m.material_id = mv.material_id
         WHERE m.paper_id = 1 AND m.material_type = 'RAW_DATA'
         ORDER BY mv.version_no DESC LIMIT 1
        """
    ).fetchone()["material_version_id"]

    login("sunhao")
    resp = client.get(f"/materials/{mv}")
    assert resp.status_code == 200
    body = resp.get_data(as_text=True)
    assert "GRANT:DOWNLOAD" in body or "已授权" in body

    resp = client.get(f"/materials/{mv}/download")
    assert resp.status_code == 200
    assert resp.headers["Content-Disposition"].startswith("attachment")


def test_unrelated_user_cannot_view_restricted_material(client, login, db):
    mv = db.execute(
        """
        SELECT mv.material_version_id
          FROM material_version mv
          JOIN material m ON m.material_id = mv.material_id
         WHERE m.paper_id = 1 AND m.material_type = 'RAW_DATA'
         ORDER BY mv.version_no DESC LIMIT 1
        """
    ).fetchone()["material_version_id"]

    login("liumin")
    resp = client.get(f"/materials/{mv}")
    assert resp.status_code == 403
    resp = client.get(f"/materials/{mv}/download")
    assert resp.status_code == 403
