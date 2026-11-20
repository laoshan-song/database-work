from flask import Blueprint, abort, flash, g, redirect, render_template, request, url_for

from ..db import execute, query, query_one
from ..security import (can_view_paper, is_institute_admin, login_required,
                        paper_permissions, require_paper_view)
from ..utils import as_int, flash_op

bp = Blueprint("batches", __name__)

OPEN_STATUSES = ("DRAFT", "PENDING_AUTHORS", "READY_TO_SUBMIT", "PENDING_ADMIN", "UNDER_REVIEW")


def get_batch(batch_id):
    row = query_one(
        """
        SELECT b.*, p.paper_id, p.title AS paper_title, p.visibility_level,
               i.name AS institute_name, op.name AS owner_name, ip.name AS initiator_name
          FROM submission_batch b
          JOIN paper p ON p.paper_id = b.paper_id
          JOIN institute i ON i.institute_id = b.institute_id
          JOIN person op ON op.person_id = b.owner_snapshot
          JOIN person ip ON ip.person_id = b.initiated_by
         WHERE b.batch_id = %s
        """,
        (batch_id,),
    )
    if not row:
        abort(404)
    return row


@bp.route("/papers/<int:paper_id>/batches", methods=("POST",))
@login_required
def create_batch(paper_id):
    paper = query_one("SELECT * FROM paper WHERE paper_id = %s", (paper_id,))
    if not paper:
        abort(404)
    perms = paper_permissions(paper)
    if not (perms["owner"] or perms["maintainer"]):
        abort(403)
    result = query_one(
        "SELECT * FROM sp_create_batch(%s, %s, %s)",
        (paper_id, g.user["person_id"], as_int(request.form.get("paper_version_id"))),
    )
    flash_op(result)
    if result["ok"]:
        batch_id = query_one(
            "SELECT max(batch_id) AS id FROM submission_batch WHERE paper_id = %s",
            (paper_id,),
        )["id"]
        return redirect(url_for("batches.batch_detail", batch_id=batch_id))
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/batches/<int:batch_id>")
@login_required
def batch_detail(batch_id):
    batch = get_batch(batch_id)
    paper = query_one("SELECT * FROM paper WHERE paper_id = %s", (batch["paper_id"],))
    require_paper_view(paper)
    perms = paper_permissions(paper)

    authors = query(
        "SELECT * FROM v_confirmation_detail WHERE batch_id = %s ORDER BY author_order",
        (batch_id,),
    )
    history = query(
        """
        SELECT c.*, per.name
          FROM confirmation c
          JOIN person per ON per.person_id = c.created_by
         WHERE c.batch_id = %s
         ORDER BY c.created_at, c.confirmation_id
        """,
        (batch_id,),
    )
    reviews = query(
        """
        SELECT r.*, per.name AS reviewer
          FROM admin_review r
          JOIN person per ON per.person_id = r.reviewer_person_id
         WHERE r.batch_id = %s
         ORDER BY r.created_at
        """,
        (batch_id,),
    )
    materials = query(
        """
        SELECT bm.*, mv.material_version_id, m.material_id, m.material_type AS current_type,
               f.original_name, f.size_bytes,
               (SELECT x.version_no FROM material_version x
                 WHERE x.material_id = m.material_id ORDER BY x.version_no DESC LIMIT 1) AS latest_version
          FROM batch_material bm
          JOIN material_version mv ON mv.material_version_id = bm.material_version_id
          JOIN material m ON m.material_id = mv.material_id
          JOIN file_object f ON f.file_id = mv.file_id
         WHERE bm.batch_id = %s
         ORDER BY bm.material_type, bm.material_name_snapshot
        """,
        (batch_id,),
    )
    experiments = query(
        """
        SELECT be.*, r.run_label, r.parameters, r.hardware_env, r.software_env,
               r.started_at, r.ended_at, r.status AS run_status, t.title AS task_title
          FROM batch_experiment be
          JOIN experiment_run r ON r.run_id = be.run_id
          JOIN experiment_task t ON t.task_id = r.task_id
         WHERE be.batch_id = %s
         ORDER BY r.started_at
        """,
        (batch_id,),
    )
    my_author = next((a for a in authors if a["person_id"] == g.user["person_id"]), None)
    can_confirm = bool(
        my_author and batch["status"] in ("PENDING_AUTHORS", "READY_TO_SUBMIT")
    )
    admin_can_review = is_institute_admin(batch["institute_id"])
    can_remind = bool(
        batch["status"] in ("PENDING_AUTHORS", "READY_TO_SUBMIT")
        and (perms["owner"] or perms["maintainer"] or admin_can_review)
    )

    # 草稿阶段可调整材料：列出论文全部材料及是否已包含
    draft_materials = []
    if batch["status"] == "DRAFT":
        draft_materials = query(
            """
            SELECT m.material_id, m.name, m.material_type,
                   mv.material_version_id, mv.version_no,
                   EXISTS (SELECT 1 FROM batch_material bm
                            WHERE bm.batch_id = %s
                              AND bm.material_version_id = mv.material_version_id) AS included
              FROM material m
              JOIN LATERAL (SELECT x.* FROM material_version x
                             WHERE x.material_id = m.material_id
                             ORDER BY x.version_no DESC LIMIT 1) mv ON true
             WHERE m.paper_id = %s
             ORDER BY m.material_type, m.name
            """,
            (batch_id, batch["paper_id"]),
        )

    other_batches = query(
        "SELECT batch_id, round_no, status FROM submission_batch WHERE paper_id = %s ORDER BY round_no DESC",
        (batch["paper_id"],),
    )

    return render_template(
        "batches/detail.html",
        batch=batch,
        paper=paper,
        perms=perms,
        authors=authors,
        history=history,
        reviews=reviews,
        materials=materials,
        experiments=experiments,
        my_author=my_author,
        can_confirm=can_confirm,
        admin_can_review=admin_can_review,
        can_remind=can_remind,
        draft_materials=draft_materials,
        other_batches=other_batches,
        confirmed_count=sum(1 for a in authors if a["current_state"] == "CONFIRM"),
    )


@bp.route("/batches/<int:batch_id>/refresh", methods=("POST",))
@login_required
def refresh_draft(batch_id):
    batch = get_batch(batch_id)
    flash_op(query_one("SELECT * FROM sp_refresh_batch_draft(%s, %s)",
                       (batch_id, g.user["person_id"])))
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/start", methods=("POST",))
@login_required
def start_confirmation(batch_id):
    result = query_one("SELECT * FROM sp_start_confirmation(%s, %s)",
                       (batch_id, g.user["person_id"]))
    flash_op(result)
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/confirm", methods=("POST",))
@login_required
def confirm(batch_id):
    action = request.form.get("action") or "CONFIRM"
    result = query_one(
        "SELECT * FROM sp_record_confirmation(%s, %s, %s, %s)",
        (batch_id, g.user["person_id"], action, request.form.get("comment") or None),
    )
    flash_op(result)
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/submit", methods=("POST",))
@login_required
def submit(batch_id):
    flash_op(query_one("SELECT * FROM sp_submit_batch(%s, %s)",
                       (batch_id, g.user["person_id"])))
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/withdraw", methods=("POST",))
@login_required
def withdraw(batch_id):
    flash_op(query_one("SELECT * FROM sp_withdraw_batch(%s, %s)",
                       (batch_id, g.user["person_id"])))
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/remind", methods=("POST",))
@login_required
def remind(batch_id):
    flash_op(query_one("SELECT * FROM sp_remind_batch(%s, %s)",
                       (batch_id, g.user["person_id"])))
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/materials", methods=("POST",))
@login_required
def toggle_material(batch_id):
    mv_id = as_int(request.form.get("material_version_id"))
    include = request.form.get("include") == "1"
    if not mv_id:
        abort(400)
    flash_op(query_one(
        "SELECT * FROM sp_set_batch_material(%s, %s, %s, %s)",
        (batch_id, mv_id, g.user["person_id"], include),
    ))
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/accept", methods=("POST",))
@login_required
def accept(batch_id):
    flash_op(query_one("SELECT * FROM sp_accept_batch(%s, %s)",
                       (batch_id, g.user["person_id"])))
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/review", methods=("POST",))
@login_required
def review(batch_id):
    decision = request.form.get("decision")
    flash_op(query_one(
        "SELECT * FROM sp_review_batch(%s, %s, %s, %s)",
        (batch_id, g.user["person_id"], decision, request.form.get("comment") or None),
    ))
    return redirect(url_for("batches.batch_detail", batch_id=batch_id))


@bp.route("/batches/<int:batch_id>/compare/<int:other_id>")
@login_required
def compare(batch_id, other_id):
    left = get_batch(batch_id)
    right = get_batch(other_id)
    if left["paper_id"] != right["paper_id"]:
        abort(400)
    paper = query_one("SELECT * FROM paper WHERE paper_id = %s", (left["paper_id"],))
    require_paper_view(paper)

    def authors_of(bid):
        rows = query(
            "SELECT person_id, name_snapshot, author_order FROM batch_author WHERE batch_id = %s",
            (bid,),
        )
        return {r["person_id"]: r for r in rows}

    def materials_of(bid):
        rows = query(
            """
            SELECT material_version_id, material_name_snapshot, material_type, version_no_snapshot
              FROM batch_material WHERE batch_id = %s
            """,
            (bid,),
        )
        return {r["material_version_id"]: r for r in rows}

    la, ra = authors_of(batch_id), authors_of(other_id)
    lm, rm = materials_of(batch_id), materials_of(other_id)
    diff = []
    for pid in sorted(set(la) | set(ra), key=lambda x: (la.get(x) or ra[x])["author_order"]):
        l, r = la.get(pid), ra.get(pid)
        if l and not r:
            diff.append(("作者", l["name_snapshot"], "仅在上一批次"))
        elif r and not l:
            diff.append(("作者", r["name_snapshot"], "仅在本批次"))
        elif l["author_order"] != r["author_order"]:
            diff.append(("作者", l["name_snapshot"], f"顺序 {l['author_order']} -> {r['author_order']}"))
    for mid in set(lm) | set(rm):
        l, r = lm.get(mid), rm.get(mid)
        if l and not r:
            diff.append(("材料", l["material_name_snapshot"], f"移除（V{l['version_no_snapshot']}）"))
        elif r and not l:
            diff.append(("材料", r["material_name_snapshot"], f"新增（V{r['version_no_snapshot']}）"))
    return render_template("batches/compare.html", left=left, right=right, diff=diff)
