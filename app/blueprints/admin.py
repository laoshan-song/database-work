from flask import Blueprint, abort, flash, g, redirect, render_template, request, url_for

from ..db import query, query_one
from ..security import admin_required, is_institute_admin, login_required
from ..utils import as_int, flash_op

bp = Blueprint("admin", __name__)


def _scope():
    if g.user["is_system_admin"]:
        return None
    return g.user["admin_institutes"] or []


@bp.route("/admin")
@admin_required
def dashboard():
    scope = _scope()
    clause = "" if scope is None else " AND b.institute_id = ANY(%s)"
    params = [] if scope is None else [scope]

    batches = query(
        f"""
        SELECT b.*, p.title, i.name AS institute_name,
               (SELECT count(*) FROM confirmation c
                 WHERE c.batch_id = b.batch_id AND c.is_current AND c.action = 'CONFIRM') AS confirmed
          FROM submission_batch b
          JOIN paper p ON p.paper_id = b.paper_id
          JOIN institute i ON i.institute_id = b.institute_id
         WHERE b.status IN ('PENDING_ADMIN','UNDER_REVIEW') {clause}
         ORDER BY b.submitted_at
        """,
        params,
    )
    pending_access = query(
        f"""
        SELECT ar.*, per.name AS requester, m.name AS material_name, mv.version_no,
               p.title, p.paper_id, p.institute_id
          FROM access_request ar
          JOIN account a ON a.account_id = ar.requester_account_id
          JOIN person per ON per.person_id = a.person_id
          JOIN material_version mv ON mv.material_version_id = ar.material_version_id
          JOIN material m ON m.material_id = mv.material_id
          JOIN paper p ON p.paper_id = m.paper_id
         WHERE ar.status = 'PENDING' {clause.replace('b.institute_id', 'p.institute_id')}
         ORDER BY ar.created_at
        """,
        params,
    )
    stats = query_one(
        f"""
        SELECT
          count(*) FILTER (WHERE b.status = 'PENDING_ADMIN') AS pending,
          count(*) FILTER (WHERE b.status = 'UNDER_REVIEW') AS reviewing,
          count(*) FILTER (WHERE b.status = 'ARCHIVED') AS archived,
          count(*) FILTER (WHERE b.status = 'RETURNED') AS returned
        FROM submission_batch b
        WHERE 1 = 1 {clause}
        """,
        params,
    )
    return render_template("admin/dashboard.html", batches=batches,
                           pending_access=pending_access, stats=stats)


@bp.route("/admin/access")
@admin_required
def access_requests():
    scope = _scope()
    status = request.args.get("status") or "PENDING"
    clause = "" if scope is None else " AND p.institute_id = ANY(%s)"
    params = [] if scope is None else [scope]
    if status:
        clause += " AND ar.status = %s"
        params.append(status)
    rows = query(
        f"""
        SELECT ar.*, per.name AS requester, a.username,
               m.name AS material_name, m.material_type, mv.version_no,
               f.size_bytes, p.title, p.paper_id, p.institute_id, p.visibility_level,
               g.grant_id, g.valid_to, g.max_downloads
          FROM access_request ar
          JOIN account a ON a.account_id = ar.requester_account_id
          JOIN person per ON per.person_id = a.person_id
          JOIN material_version mv ON mv.material_version_id = ar.material_version_id
          JOIN material m ON m.material_id = mv.material_id
          JOIN file_object f ON f.file_id = mv.file_id
          JOIN paper p ON p.paper_id = m.paper_id
          LEFT JOIN access_grant g ON g.request_id = ar.request_id
         WHERE 1 = 1 {clause}
         ORDER BY ar.created_at DESC
        """,
        params,
    )
    return render_template("admin/access_requests.html", rows=rows, status=status)


@bp.route("/admin/access/<int:request_id>/decide", methods=("POST",))
@admin_required
def decide_access(request_id):
    approve = request.form.get("decision") == "approve"
    result = query_one(
        "SELECT * FROM sp_decide_access(%s, %s, %s, %s, %s, %s)",
        (request_id, g.user["person_id"], approve,
         request.form.get("comment") or None,
         as_int(request.form.get("days")) or 7,
         as_int(request.form.get("max_downloads"))),
    )
    flash_op(result)
    return redirect(request.referrer or url_for("admin.access_requests"))


@bp.route("/admin/audit")
@admin_required
def audit():
    object_type = request.args.get("object_type") or ""
    action = request.args.get("action") or ""
    keyword = (request.args.get("q") or "").strip()
    sql = [
        """
        SELECT al.*, per.name AS actor_name
          FROM audit_log al
          LEFT JOIN person per ON per.person_id = al.actor_person_id
         WHERE 1 = 1
        """
    ]
    params = []
    if object_type:
        sql.append(" AND al.object_type = %s")
        params.append(object_type)
    if action:
        sql.append(" AND al.action = %s")
        params.append(action)
    if keyword:
        sql.append(" AND (al.object_id ILIKE %s OR per.name ILIKE %s OR al.summary::text ILIKE %s)")
        params += [f"%{keyword}%", f"%{keyword}%", f"%{keyword}%"]
    sql.append(" ORDER BY al.created_at DESC LIMIT 300")
    rows = query("".join(sql), params)
    actions = query("SELECT DISTINCT action FROM audit_log ORDER BY action")
    object_types = query("SELECT DISTINCT object_type FROM audit_log ORDER BY object_type")
    return render_template("admin/audit.html", rows=rows, object_type=object_type,
                           action=action, keyword=keyword, actions=actions,
                           object_types=object_types)


@bp.route("/admin/mail")
@admin_required
def mail_outbox():
    rows = query(
        """
        SELECT * FROM mail_outbox
         ORDER BY mail_id DESC
         LIMIT 200
        """
    )
    return render_template("admin/mail.html", rows=rows)
