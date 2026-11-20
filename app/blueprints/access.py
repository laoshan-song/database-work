from flask import Blueprint, abort, flash, g, redirect, render_template, request, url_for

from ..db import execute, query, query_one
from ..security import login_required
from ..utils import as_int, flash_op

bp = Blueprint("access", __name__)


@bp.route("/access")
@login_required
def my_access():
    requests = query(
        """
        SELECT ar.*, m.name AS material_name, m.material_type, mv.version_no,
               p.paper_id, p.title,
               s.grant_id, s.grant_status, s.valid_to, s.download_count,
               s.max_downloads, s.scope
          FROM access_request ar
          JOIN material_version mv ON mv.material_version_id = ar.material_version_id
          JOIN material m ON m.material_id = mv.material_id
          JOIN paper p ON p.paper_id = m.paper_id
          LEFT JOIN v_access_grant_status s ON s.request_id = ar.request_id
         WHERE ar.requester_account_id = %s
         ORDER BY ar.created_at DESC
        """,
        (g.user["account_id"],),
    )
    grants = query(
        """
        SELECT s.*, m.name AS material_name, m.material_type, mv.version_no,
               p.paper_id, p.title
          FROM v_access_grant_status s
          JOIN material_version mv ON mv.material_version_id = s.material_version_id
          JOIN material m ON m.material_id = mv.material_id
          JOIN paper p ON p.paper_id = m.paper_id
         WHERE s.account_id = %s
         ORDER BY s.grant_id DESC
        """,
        (g.user["account_id"],),
    )
    return render_template("access/my_access.html", requests=requests, grants=grants)


@bp.route("/access/browse")
@login_required
def browse():
    q = (request.args.get("q") or "").strip()
    material_type = request.args.get("type") or ""
    sql = [
        """
        SELECT p.paper_id, p.title AS paper_title, p.visibility_level,
               i.name AS institute_name,
               m.material_id, m.name AS material_name, m.material_type,
               mv.material_version_id, mv.version_no, mv.created_at,
               f.size_bytes,
               fn_access_mode(%s, mv.material_version_id) AS mode
          FROM material m
          JOIN paper p ON p.paper_id = m.paper_id
          JOIN institute i ON i.institute_id = p.institute_id
          JOIN material_version mv ON mv.material_version_id = (
                SELECT x.material_version_id FROM material_version x
                 WHERE x.material_id = m.material_id
                 ORDER BY x.version_no DESC LIMIT 1)
          JOIN file_object f ON f.file_id = mv.file_id
         WHERE EXISTS (SELECT 1 FROM submission_batch b
                        WHERE b.paper_id = p.paper_id AND b.status = 'ARCHIVED')
        """
    ]
    params = [g.user["account_id"]]
    if q:
        sql.append(" AND (p.title ILIKE %s OR m.name ILIKE %s)")
        params += [f"%{q}%", f"%{q}%"]
    if material_type:
        sql.append(" AND m.material_type = %s")
        params.append(material_type)
    sql.append(" ORDER BY p.title, m.material_type, m.name")
    rows = query("".join(sql), params)
    return render_template("access/browse.html", rows=rows, q=q, material_type=material_type)


@bp.route("/access/apply/<int:material_version_id>", methods=("POST",))
@login_required
def apply(material_version_id):
    result = query_one(
        "SELECT * FROM sp_apply_access(%s, %s, %s)",
        (g.user["account_id"], material_version_id, request.form.get("reason") or ""),
    )
    flash_op(result)
    return redirect(request.referrer or url_for("access.browse"))


@bp.route("/access/requests/<int:request_id>/cancel", methods=("POST",))
@login_required
def cancel(request_id):
    row = query_one(
        "SELECT * FROM access_request WHERE request_id = %s AND requester_account_id = %s",
        (request_id, g.user["account_id"]),
    )
    if not row:
        abort(404)
    if row["status"] != "PENDING":
        flash("只有待审批的申请可以撤回", "warning")
    else:
        execute("UPDATE access_request SET status = 'CANCELLED' WHERE request_id = %s", (request_id,))
        flash("申请已撤回", "success")
    return redirect(url_for("access.my_access"))


@bp.route("/access/grants/<int:grant_id>/revoke", methods=("POST",))
@login_required
def revoke_grant(grant_id):
    result = query_one(
        "SELECT * FROM sp_revoke_grant(%s, %s, %s)",
        (grant_id, g.user["person_id"], request.form.get("reason") or None),
    )
    flash_op(result)
    return redirect(request.referrer or url_for("access.my_access"))
