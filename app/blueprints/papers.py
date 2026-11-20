from pathlib import Path

import psycopg
from flask import (Blueprint, abort, current_app, flash, g, redirect, render_template,
                   request, send_file, url_for)

from ..db import execute, query, query_one, transaction
from ..security import (can_view_paper, is_institute_admin, login_required,
                        paper_permissions, require_paper_manage, require_paper_view)
from ..utils import as_int, client_ip, flash_op, record_access, save_upload

bp = Blueprint("papers", __name__)

PAGE_SIZE = 20


def get_paper(paper_id):
    row = query_one(
        """
        SELECT p.*, i.name AS institute_name, op.name AS owner_name
          FROM paper p
          JOIN institute i ON i.institute_id = p.institute_id
          JOIN person op ON op.person_id = p.owner_person_id
         WHERE p.paper_id = %s
        """,
        (paper_id,),
    )
    if not row:
        abort(404)
    return row


@bp.route("/papers")
@login_required
def list_papers():
    q = (request.args.get("q") or "").strip()
    institute_id = as_int(request.args.get("institute_id"))
    owner = (request.args.get("owner") or "").strip()
    status = request.args.get("status") or ""
    visibility = request.args.get("visibility") or ""
    mine = request.args.get("mine") == "1"

    sql = [
        """
        SELECT v.*, p.updated_at, p.doi
          FROM v_submission_overview v
          JOIN paper p ON p.paper_id = v.paper_id
         WHERE 1 = 1
        """
    ]
    params = []
    if q:
        sql.append(" AND (v.title ILIKE %s OR p.keywords ILIKE %s OR v.owner_name ILIKE %s)")
        params += [f"%{q}%", f"%{q}%", f"%{q}%"]
    if institute_id:
        sql.append(" AND v.institute_id = %s")
        params.append(institute_id)
    if owner:
        sql.append(" AND v.owner_name ILIKE %s")
        params.append(f"%{owner}%")
    if status == "NONE":
        sql.append(" AND v.current_batch_id IS NULL")
    elif status:
        sql.append(" AND v.batch_status = %s")
        params.append(status)
    if visibility:
        sql.append(" AND v.visibility_level = %s")
        params.append(visibility)
    if mine:
        sql.append(
            """ AND (v.owner_person_id = %s OR EXISTS (
                       SELECT 1 FROM paper_author pa
                        WHERE pa.paper_id = v.paper_id AND pa.person_id = %s))"""
        )
        params += [g.user["person_id"], g.user["person_id"]]
    sql.append(" ORDER BY v.paper_id DESC")

    rows = query("".join(sql), params)
    institutes = query("SELECT institute_id, name FROM institute ORDER BY name")
    return render_template(
        "papers/list.html",
        papers=rows,
        institutes=institutes,
        filters={"q": q, "institute_id": institute_id, "owner": owner,
                 "status": status, "visibility": visibility, "mine": mine},
    )


@bp.route("/papers/new", methods=("GET", "POST"))
@login_required
def create_paper():
    institutes = query("SELECT institute_id, name FROM institute ORDER BY name")

    if request.method == "POST":
        institute_id = as_int(request.form.get("institute_id")) or g.user["home_institute_id"]
        if institute_id is None:
            flash("请选择主管研究所", "warning")
            return render_template("papers/form.html", paper=None, institutes=institutes)
        owner_id = as_int(request.form.get("owner_person_id")) or g.user["person_id"]
        if owner_id != g.user["person_id"] and not is_institute_admin(institute_id):
            abort(403)
        try:
            paper_id = query_one(
                """
                INSERT INTO paper (institute_id, owner_person_id, title, abstract, keywords,
                                   research_field, venue, submission_status, doi, visibility_level)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING paper_id
                """,
                (
                    institute_id, owner_id,
                    request.form["title"].strip(),
                    request.form.get("abstract") or None,
                    request.form.get("keywords") or None,
                    request.form.get("research_field") or None,
                    request.form.get("venue") or None,
                    request.form.get("submission_status") or "DRAFT",
                    request.form.get("doi") or None,
                    request.form.get("visibility_level") or "PROJECT",
                ),
            )["paper_id"]
            # 负责人默认作为第一作者，可在详情页调整
            execute(
                """
                INSERT INTO paper_author (paper_id, person_id, author_order,
                                          is_corresponding, is_external, affiliation_text)
                SELECT %s, %s, 1, true, (p.person_category = 'EXTERNAL'), i.name
                  FROM person p LEFT JOIN institute i ON i.institute_id = p.home_institute_id
                 WHERE p.person_id = %s
                """,
                (paper_id, owner_id, owner_id),
            )
            flash("论文已创建，请继续维护作者与材料", "success")
            return redirect(url_for("papers.paper_detail", paper_id=paper_id))
        except psycopg.errors.UniqueViolation:
            flash("DOI 已被其他论文使用", "danger")

    return render_template("papers/form.html", paper=None, institutes=institutes)


@bp.route("/papers/<int:paper_id>/edit", methods=("GET", "POST"))
@login_required
def edit_paper(paper_id):
    paper = get_paper(paper_id)
    perms = paper_permissions(paper)
    if not perms["manage"]:
        abort(403)
    institutes = query("SELECT institute_id, name FROM institute ORDER BY name")

    if request.method == "POST":
        try:
            execute(
                """
                UPDATE paper
                   SET title = %s, abstract = %s, keywords = %s, research_field = %s,
                       venue = %s, submission_status = %s, doi = %s, visibility_level = %s
                 WHERE paper_id = %s
                """,
                (
                    request.form["title"].strip(),
                    request.form.get("abstract") or None,
                    request.form.get("keywords") or None,
                    request.form.get("research_field") or None,
                    request.form.get("venue") or None,
                    request.form.get("submission_status") or "DRAFT",
                    request.form.get("doi") or None,
                    request.form.get("visibility_level") or "PROJECT",
                    paper_id,
                ),
            )
            # 同步已有开放批次中的公开范围？冻结后不可改，此处只改论文当前信息
            flash("论文信息已更新（已冻结的批次快照不受影响）", "success")
            return redirect(url_for("papers.paper_detail", paper_id=paper_id))
        except psycopg.errors.UniqueViolation:
            flash("DOI 已被其他论文使用", "danger")

    return render_template("papers/form.html", paper=paper, institutes=institutes)


@bp.route("/papers/<int:paper_id>")
@login_required
def paper_detail(paper_id):
    paper = get_paper(paper_id)
    require_paper_view(paper)
    perms = paper_permissions(paper)

    authors = query(
        """
        SELECT pa.*, per.name, per.employee_no, per.email,
               COALESCE(pa.affiliation_text, i.name) AS affiliation
          FROM paper_author pa
          JOIN person per ON per.person_id = pa.person_id
          LEFT JOIN institute i ON i.institute_id = per.home_institute_id
         WHERE pa.paper_id = %s
         ORDER BY pa.author_order
        """,
        (paper_id,),
    )
    versions = query(
        """
        SELECT pv.*, f.original_name, f.size_bytes, f.sha256, per.name AS uploader
          FROM paper_version pv
          JOIN file_object f ON f.file_id = pv.file_id
          JOIN person per ON per.person_id = pv.created_by
         WHERE pv.paper_id = %s
         ORDER BY pv.version_no DESC
        """,
        (paper_id,),
    )
    materials = query(
        """
        SELECT m.*, mv.material_version_id, mv.version_no, mv.created_at AS version_created_at,
               f.original_name, f.size_bytes, mv.sha256,
               (SELECT count(*) FROM material_version x WHERE x.material_id = m.material_id) AS version_count,
               (SELECT count(*) FROM batch_material bm WHERE bm.material_version_id = mv.material_version_id) AS used_in_batches
          FROM material m
          JOIN LATERAL (SELECT x.* FROM material_version x
                         WHERE x.material_id = m.material_id
                         ORDER BY x.version_no DESC LIMIT 1) mv ON true
          JOIN file_object f ON f.file_id = mv.file_id
         WHERE m.paper_id = %s
         ORDER BY m.material_type, m.name
        """,
        (paper_id,),
    )
    batches = query(
        """
        SELECT b.*, r.name AS initiator_name,
               (SELECT count(*) FROM confirmation c WHERE c.batch_id = b.batch_id
                 AND c.is_current AND c.action = 'CONFIRM') AS confirmed_count
          FROM submission_batch b
          JOIN person r ON r.person_id = b.initiated_by
         WHERE b.paper_id = %s
         ORDER BY b.round_no DESC
        """,
        (paper_id,),
    )
    maintainers = query(
        """
        SELECT pm.*, per.name, per.employee_no
          FROM paper_maintainer pm
          JOIN person per ON per.person_id = pm.person_id
         WHERE pm.paper_id = %s
         ORDER BY pm.granted_at DESC
        """,
        (paper_id,),
    )
    tasks = query(
        "SELECT * FROM experiment_task WHERE paper_id = %s ORDER BY task_id DESC",
        (paper_id,),
    )
    runs = query(
        """
        SELECT r.*, t.title AS task_title,
               (SELECT count(*) FROM experiment_result x WHERE x.run_id = r.run_id) AS result_count
          FROM experiment_run r
          JOIN experiment_task t ON t.task_id = r.task_id
         WHERE t.paper_id = %s
         ORDER BY r.started_at DESC
        """,
        (paper_id,),
    )
    candidates = query(
        """
        SELECT p.person_id, p.name, p.employee_no,
               CASE WHEN p.person_category = 'EXTERNAL' THEN true ELSE false END AS external
          FROM person p
         WHERE p.status <> 'LEFT'
           AND NOT EXISTS (SELECT 1 FROM paper_author pa
                            WHERE pa.paper_id = %s AND pa.person_id = p.person_id)
         ORDER BY p.name
        """,
        (paper_id,),
    )
    open_batch = next((b for b in batches if b["status"] in
                       ("DRAFT", "PENDING_AUTHORS", "READY_TO_SUBMIT", "PENDING_ADMIN", "UNDER_REVIEW")), None)
    archived_batch = next((b for b in batches if b["status"] == "ARCHIVED"), None)

    return render_template(
        "papers/detail.html",
        paper=paper,
        perms=perms,
        authors=authors,
        versions=versions,
        materials=materials,
        batches=batches,
        maintainers=maintainers,
        tasks=tasks,
        runs=runs,
        candidates=candidates,
        open_batch=open_batch,
        archived_batch=archived_batch,
    )


@bp.route("/papers/<int:paper_id>/authors", methods=("POST",))
@login_required
def add_author(paper_id):
    paper = get_paper(paper_id)
    require_paper_manage(paper)
    person_id = as_int(request.form.get("person_id"))
    if not person_id:
        flash("请选择人员", "warning")
        return redirect(url_for("papers.paper_detail", paper_id=paper_id))
    try:
        execute(
            """
            INSERT INTO paper_author (paper_id, person_id, author_order,
                                      is_corresponding, is_external, affiliation_text)
            SELECT %s, p.person_id,
                   COALESCE((SELECT max(author_order) + 1 FROM paper_author WHERE paper_id = %s), 1),
                   %s,
                   (p.person_category = 'EXTERNAL'
                    OR COALESCE(p.home_institute_id, -1) <> %s),
                   COALESCE(%s, i.name)
              FROM person p LEFT JOIN institute i ON i.institute_id = p.home_institute_id
             WHERE p.person_id = %s
            """,
            (paper_id, paper_id, bool(request.form.get("is_corresponding")),
             paper["institute_id"], request.form.get("affiliation_text") or None, person_id),
        )
        flash("作者已添加。作者名单变更后需创建新批次才能生效", "success")
    except psycopg.errors.UniqueViolation:
        flash("该作者已在名单中，或作者顺序冲突", "danger")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/papers/<int:paper_id>/authors/<int:person_id>/remove", methods=("POST",))
@login_required
def remove_author(paper_id, person_id):
    paper = get_paper(paper_id)
    require_paper_manage(paper)
    execute("DELETE FROM paper_author WHERE paper_id = %s AND person_id = %s", (paper_id, person_id))
    flash("作者已移除（已冻结批次中的作者快照不受影响）", "success")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/papers/<int:paper_id>/authors/reorder", methods=("POST",))
@login_required
def reorder_authors(paper_id):
    paper = get_paper(paper_id)
    require_paper_manage(paper)
    authors = query("SELECT person_id FROM paper_author WHERE paper_id = %s", (paper_id,))
    try:
        with transaction() as cur:
            # 两阶段更新，避免唯一约束在交换顺序时冲突
            cur.execute("UPDATE paper_author SET author_order = author_order + 1000 WHERE paper_id = %s", (paper_id,))
            for row in authors:
                pid = row["person_id"]
                order = as_int(request.form.get(f"order_{pid}"))
                if order:
                    cur.execute(
                        "UPDATE paper_author SET author_order = %s WHERE paper_id = %s AND person_id = %s",
                        (order, paper_id, pid),
                    )
            cur.execute(
                "UPDATE paper_author SET is_corresponding = (person_id = %s) WHERE paper_id = %s",
                (as_int(request.form.get("corresponding_person_id")) or -1, paper_id),
            )
        flash("作者顺序与通讯作者已更新", "success")
    except psycopg.errors.UniqueViolation:
        flash("作者顺序不能重复", "danger")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/papers/<int:paper_id>/maintainers", methods=("POST",))
@login_required
def grant_maintainer(paper_id):
    paper = get_paper(paper_id)
    if not paper_permissions(paper)["owner"]:
        abort(403)
    person_id = as_int(request.form.get("person_id"))
    if not person_id:
        flash("请选择人员", "warning")
        return redirect(url_for("papers.paper_detail", paper_id=paper_id))
    execute(
        """
        INSERT INTO paper_maintainer (paper_id, person_id, scope, granted_by, revoked_at)
        VALUES (%s, %s, %s, %s, NULL)
        ON CONFLICT (paper_id, person_id)
        DO UPDATE SET scope = EXCLUDED.scope, granted_by = EXCLUDED.granted_by,
                      granted_at = now(), revoked_at = NULL
        """,
        (paper_id, person_id, request.form.get("scope") or "ALL", g.user["person_id"]),
    )
    flash("维护权限已授予", "success")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/papers/<int:paper_id>/maintainers/<int:person_id>/revoke", methods=("POST",))
@login_required
def revoke_maintainer(paper_id, person_id):
    paper = get_paper(paper_id)
    if not paper_permissions(paper)["owner"]:
        abort(403)
    execute(
        "UPDATE paper_maintainer SET revoked_at = now() WHERE paper_id = %s AND person_id = %s",
        (paper_id, person_id),
    )
    flash("维护权限已撤销", "success")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/papers/<int:paper_id>/versions", methods=("POST",))
@login_required
def upload_paper_version(paper_id):
    paper = get_paper(paper_id)
    require_paper_manage(paper)
    try:
        meta = save_upload(request.files.get("file"))
    except ValueError as exc:
        flash(str(exc), "warning")
        return redirect(url_for("papers.paper_detail", paper_id=paper_id))
    with transaction() as cur:
        cur.execute("SELECT paper_id FROM paper WHERE paper_id = %s FOR UPDATE", (paper_id,))
        version_no = 1 + (query_one(
            "SELECT COALESCE(max(version_no), 0) AS v FROM paper_version WHERE paper_id = %s",
            (paper_id,))["v"])
        cur.execute(
            """
            INSERT INTO file_object (storage_key, original_name, file_format, size_bytes, sha256, uploaded_by)
            VALUES (%s, %s, %s, %s, %s, %s) RETURNING file_id
            """,
            (meta["storage_key"], meta["original_name"], meta["file_format"],
             meta["size_bytes"], meta["sha256"], g.user["person_id"]),
        )
        file_id = cur.fetchone()["file_id"]
        cur.execute(
            """
            INSERT INTO paper_version (paper_id, version_no, stage, file_id, change_note, created_by)
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (paper_id, version_no, request.form.get("stage") or "SUBMISSION", file_id,
             request.form.get("change_note") or None, g.user["person_id"]),
        )
    flash(f"论文版本 V{version_no} 已上传（SHA-256 已记录）", "success")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/papers/<int:paper_id>/materials", methods=("POST",))
@login_required
def create_material(paper_id):
    paper = get_paper(paper_id)
    if not paper_permissions(paper)["material"]:
        abort(403)
    name = (request.form.get("name") or "").strip()
    if not name:
        flash("请填写材料名称", "warning")
        return redirect(url_for("papers.paper_detail", paper_id=paper_id))
    try:
        meta = save_upload(request.files.get("file"))
    except ValueError as exc:
        flash(str(exc), "warning")
        return redirect(url_for("papers.paper_detail", paper_id=paper_id))
    try:
        with transaction() as cur:
            cur.execute(
                """
                INSERT INTO material (paper_id, material_type, name, description)
                VALUES (%s, %s, %s, %s) RETURNING material_id
                """,
                (paper_id, request.form.get("material_type") or "CODE", name,
                 request.form.get("description") or None),
            )
            material_id = cur.fetchone()["material_id"]
            cur.execute(
                """
                INSERT INTO file_object (storage_key, original_name, file_format, size_bytes, sha256, uploaded_by)
                VALUES (%s, %s, %s, %s, %s, %s) RETURNING file_id
                """,
                (meta["storage_key"], meta["original_name"], meta["file_format"],
                 meta["size_bytes"], meta["sha256"], g.user["person_id"]),
            )
            file_id = cur.fetchone()["file_id"]
            cur.execute(
                """
                INSERT INTO material_version (material_id, version_no, file_id, sha256, change_note, created_by)
                VALUES (%s, 1, %s, NULL, %s, %s)
                """,
                (material_id, file_id, request.form.get("change_note") or "初始版本", g.user["person_id"]),
            )
        flash(f"材料「{name}」V1 已上传", "success")
    except psycopg.errors.UniqueViolation:
        flash("该论文下已存在同名材料", "danger")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/papers/<int:paper_id>/materials/<int:material_id>/versions", methods=("POST",))
@login_required
def upload_material_version(paper_id, material_id):
    paper = get_paper(paper_id)
    if not paper_permissions(paper)["material"]:
        abort(403)
    material = query_one(
        "SELECT * FROM material WHERE material_id = %s AND paper_id = %s",
        (material_id, paper_id),
    )
    if not material:
        abort(404)
    try:
        meta = save_upload(request.files.get("file"))
    except ValueError as exc:
        flash(str(exc), "warning")
        return redirect(url_for("papers.paper_detail", paper_id=paper_id))
    with transaction() as cur:
        cur.execute("SELECT material_id FROM material WHERE material_id = %s FOR UPDATE", (material_id,))
        version_no = 1 + (query_one(
            "SELECT COALESCE(max(version_no), 0) AS v FROM material_version WHERE material_id = %s",
            (material_id,))["v"])
        cur.execute(
            """
            INSERT INTO file_object (storage_key, original_name, file_format, size_bytes, sha256, uploaded_by)
            VALUES (%s, %s, %s, %s, %s, %s) RETURNING file_id
            """,
            (meta["storage_key"], meta["original_name"], meta["file_format"],
             meta["size_bytes"], meta["sha256"], g.user["person_id"]),
        )
        file_id = cur.fetchone()["file_id"]
        cur.execute(
            """
            INSERT INTO material_version (material_id, version_no, file_id, sha256, change_note, created_by)
            VALUES (%s, %s, %s, NULL, %s, %s)
            """,
            (material_id, version_no, file_id, request.form.get("change_note") or None,
             g.user["person_id"]),
        )
    flash(f"材料「{material['name']}」V{version_no} 已上传，历史版本仍可查询", "success")
    return redirect(url_for("papers.paper_detail", paper_id=paper_id))


@bp.route("/materials/<int:material_version_id>")
@login_required
def material_detail(material_version_id):
    mv = query_one(
        """
        SELECT mv.*, m.paper_id, m.name AS material_name, m.material_type,
               f.original_name, f.file_format, f.size_bytes, f.storage_key,
               per.name AS uploader
          FROM material_version mv
          JOIN material m ON m.material_id = mv.material_id
          JOIN file_object f ON f.file_id = mv.file_id
          JOIN person per ON per.person_id = mv.created_by
         WHERE mv.material_version_id = %s
        """,
        (material_version_id,),
    )
    if not mv:
        abort(404)
    paper = get_paper(mv["paper_id"])
    # 已获授权（含仅查看）的使用者可以看这个材料版本的详情，不必是论文成员
    mode = query_one(
        "SELECT fn_access_mode(%s, %s) AS mode",
        (g.user["account_id"], material_version_id),
    )["mode"]
    if mode is None:
        require_paper_view(paper)
    versions = query(
        """
        SELECT mv.version_no, mv.material_version_id, mv.created_at, mv.change_note,
               (SELECT count(*) FROM batch_material bm
                 WHERE bm.material_version_id = mv.material_version_id) AS used_in_batches
          FROM material_version mv
         WHERE mv.material_id = %s
         ORDER BY mv.version_no DESC
        """,
        (mv["material_id"],),
    )
    return render_template("papers/material_detail.html", mv=mv, paper=paper,
                           mode=mode, versions=versions)


@bp.route("/materials/<int:material_version_id>/download")
@login_required
def download_material(material_version_id):
    mv = query_one(
        """
        SELECT mv.*, m.name AS material_name, m.paper_id,
               f.storage_key, f.original_name
          FROM material_version mv
          JOIN material m ON m.material_id = mv.material_id
          JOIN file_object f ON f.file_id = mv.file_id
         WHERE mv.material_version_id = %s
        """,
        (material_version_id,),
    )
    if not mv:
        abort(404)

    mode = query_one(
        "SELECT fn_access_mode(%s, %s) AS mode",
        (g.user["account_id"], material_version_id),
    )["mode"]
    if mode is None or mode == "GRANT:VIEW":
        record_access(g.user["account_id"], material_version_id, "DENIED",
                      f"mode={mode}, ip={client_ip()}")
        abort(403)

    if mode.startswith("GRANT:"):
        grant = query_one(
            """
            SELECT grant_id FROM v_access_grant_status
             WHERE account_id = %s AND material_version_id = %s AND grant_status = 'ACTIVE'
             ORDER BY grant_id DESC LIMIT 1
            """,
            (g.user["account_id"], material_version_id),
        )
        if not grant:
            abort(403)
        result = query_one("SELECT * FROM sp_register_download(%s, %s)", (grant["grant_id"], client_ip()))
        flash_op(result)
        if not result["ok"]:
            return redirect(url_for("papers.material_detail", material_version_id=material_version_id))
    else:
        record_access(g.user["account_id"], material_version_id, "DOWNLOAD",
                      f"mode={mode}, ip={client_ip()}")

    path = Path(current_app.config["UPLOAD_DIR"]) / mv["storage_key"]
    if not path.exists():
        flash("文件不存在，请重新上传", "danger")
        return redirect(url_for("papers.material_detail", material_version_id=material_version_id))
    return send_file(path, as_attachment=True, download_name=mv["original_name"])
