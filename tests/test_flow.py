"""端到端业务流程测试：草稿 -> 4 位作者确认 -> 提交 -> 受理 -> 退回 -> 归档。

使用 06_seed.sql 中的演示论文（paper 3）与草稿批次（batch 3）：
作者为 李娜(负责人) / 王强 / 陈静 / 赵磊(外部)，覆盖“3 内部 + 1 外部”。
"""
from __future__ import annotations

import psycopg
import pytest

BATCH_ID = 3
PAPER_ID = 3


def batch_status(db, batch_id=BATCH_ID):
    return db.execute(
        "SELECT status FROM submission_batch WHERE batch_id = %s", (batch_id,)
    ).fetchone()["status"]


def confirmed_persons(db, batch_id=BATCH_ID):
    rows = db.execute(
        """
        SELECT person_id FROM confirmation
         WHERE batch_id = %s AND is_current AND action = 'CONFIRM'
         ORDER BY person_id
        """,
        (batch_id,),
    ).fetchall()
    return {r["person_id"] for r in rows}


def page(resp):
    return resp.get_data(as_text=True)


def test_full_flow_from_draft_to_archive(client, login, db):
    # --- 1. 负责人发起确认：内容冻结 -----------------------------------------
    login("lina")
    resp = client.post(f"/batches/{BATCH_ID}/start", follow_redirects=True)
    assert resp.status_code == 200
    assert batch_status(db) == "PENDING_AUTHORS"
    frozen_at = db.execute(
        "SELECT frozen_at FROM submission_batch WHERE batch_id = %s", (BATCH_ID,)
    ).fetchone()["frozen_at"]
    assert frozen_at is not None

    # --- 2. 负责人确认，进度 1/4 --------------------------------------------
    client.post(
        f"/batches/{BATCH_ID}/confirm",
        data={"action": "CONFIRM", "comment": "作者与材料确认无误"},
        follow_redirects=True,
    )
    assert confirmed_persons(db) == {2}
    assert batch_status(db) == "PENDING_AUTHORS"

    # --- 3. 内部作者陆续确认到 3/4，此时提交必须被拒绝 ----------------------
    for username in ("wangqiang", "chenjing"):
        login(username)
        client.post(
            f"/batches/{BATCH_ID}/confirm",
            data={"action": "CONFIRM"},
            follow_redirects=True,
        )
    assert confirmed_persons(db) == {2, 3, 4}

    login("lina")
    resp = client.post(f"/batches/{BATCH_ID}/submit", follow_redirects=True)
    assert "仍有作者未确认" in page(resp)
    assert batch_status(db) == "PENDING_AUTHORS"

    # --- 4. 外部作者确认后，批次变为可提交 ----------------------------------
    login("zhaolei")
    client.post(
        f"/batches/{BATCH_ID}/confirm",
        data={"action": "CONFIRM"},
        follow_redirects=True,
    )
    assert confirmed_persons(db) == {2, 3, 4, 5}
    assert batch_status(db) == "READY_TO_SUBMIT"

    # --- 5. 负责人正式提交 ---------------------------------------------------
    login("lina")
    resp = client.post(f"/batches/{BATCH_ID}/submit", follow_redirects=True)
    assert "已提交" in page(resp)
    assert batch_status(db) == "PENDING_ADMIN"
    assert db.execute(
        "SELECT submitted_at FROM submission_batch WHERE batch_id = %s", (BATCH_ID,)
    ).fetchone()["submitted_at"] is not None

    # --- 6. 对照研究所管理员受理被拒（跨所隔离） ----------------------------
    login("zhengkai")
    resp = client.post(f"/batches/{BATCH_ID}/accept", follow_redirects=True)
    assert "只有主管研究所管理员" in page(resp)
    assert batch_status(db) == "PENDING_ADMIN"

    # --- 7. 主管研究所管理员受理 --------------------------------------------
    login("admin")
    resp = client.post(f"/batches/{BATCH_ID}/accept", follow_redirects=True)
    assert "已受理" in page(resp)
    assert batch_status(db) == "UNDER_REVIEW"

    # --- 8. 退回必须填写意见 -------------------------------------------------
    resp = client.post(
        f"/batches/{BATCH_ID}/review",
        data={"decision": "RETURN", "comment": ""},
        follow_redirects=True,
    )
    assert "退回必须填写审核意见" in page(resp)
    assert batch_status(db) == "UNDER_REVIEW"

    # --- 9. 通过并归档 -------------------------------------------------------
    resp = client.post(
        f"/batches/{BATCH_ID}/review",
        data={"decision": "APPROVE", "comment": "材料齐全，同意归档"},
        follow_redirects=True,
    )
    assert "已归档" in page(resp) or "审核通过" in page(resp)
    assert batch_status(db) == "ARCHIVED"
    ended = db.execute(
        "SELECT ended_at, ended_reason FROM submission_batch WHERE batch_id = %s",
        (BATCH_ID,),
    ).fetchone()
    assert ended["ended_at"] is not None
    assert ended["ended_reason"] == "APPROVE"


def test_audit_trail_recorded_for_flow(db):
    """流程结束后，关键动作都应留下审计记录（触发器 + 存储过程双保险）。"""
    actions = {
        r["action"]
        for r in db.execute(
            "SELECT action FROM audit_log WHERE object_type = 'submission_batch' AND object_id = %s",
            (str(BATCH_ID),),
        ).fetchall()
    }
    assert {"CREATE", "START_CONFIRMATION", "SUBMIT", "ACCEPT", "APPROVE"} <= actions

    # 4 位作者的确认各留一条审计（由 trg_audit_confirmation 写入）
    confirms = db.execute(
        """
        SELECT count(*) AS n FROM audit_log
         WHERE object_type = 'confirmation' AND object_id LIKE %s
        """,
        (f"{BATCH_ID}:%",),
    ).fetchone()["n"]
    assert confirms == 4

    # 审核记录完整：受理 + 通过（退回未成功，不应留痕）
    reviews = db.execute(
        "SELECT action FROM admin_review WHERE batch_id = %s ORDER BY review_id",
        (BATCH_ID,),
    ).fetchall()
    assert [r["action"] for r in reviews] == ["ACCEPT", "APPROVE"]


def test_archived_batch_rejects_further_writes(db):
    """归档后：过程返回 BAD_STATE，直接写确认记录被触发器拒绝。"""
    result = db.execute(
        "SELECT * FROM sp_submit_batch(%s, %s)", (BATCH_ID, 2)
    ).fetchone()
    assert not result["ok"] and result["code"] == "BAD_STATE"

    result = db.execute(
        "SELECT * FROM sp_review_batch(%s, %s, 'APPROVE', '重复审核')", (BATCH_ID, 1)
    ).fetchone()
    assert not result["ok"] and result["code"] == "BAD_STATE"

    with pytest.raises(psycopg.Error, match="不允许写入确认记录"):
        db.execute(
            """
            INSERT INTO confirmation (batch_id, person_id, action, is_current, created_by)
            VALUES (%s, 2, 'CONFIRM', true, 2)
            """,
            (BATCH_ID,),
        )


def test_archived_paper_appears_in_shared_browse(client, login, db):
    """论文 3 公开范围为 PROJECT：归档后出现在共享列表，但未授权不能下载。"""
    mv = db.execute(
        """
        SELECT mv.material_version_id
          FROM material_version mv
          JOIN material m ON m.material_id = mv.material_id
         WHERE m.paper_id = %s AND m.material_type = 'RAW_DATA'
         ORDER BY mv.version_no DESC LIMIT 1
        """,
        (PAPER_ID,),
    ).fetchone()["material_version_id"]

    login("sunhao")
    resp = client.get("/access/browse?q=演示论文")
    assert resp.status_code == 200
    body = page(resp)
    assert "演示论文：可重复实验与版本引用" in body
    assert "需申请" in body

    resp = client.get(f"/materials/{mv}/download")
    assert resp.status_code == 403


def test_author_can_view_batch_page_after_archive(client, login):
    login("zhaolei")
    resp = client.get(f"/batches/{BATCH_ID}")
    assert resp.status_code == 200
    assert "第 1 轮汇交批次" in page(resp)
