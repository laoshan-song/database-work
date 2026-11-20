from datetime import date

import psycopg
from flask import Blueprint, abort, flash, g, redirect, render_template, request, url_for
from werkzeug.security import generate_password_hash

from ..db import execute, query, query_one
from ..security import is_institute_admin, login_required
from ..utils import as_int

bp = Blueprint("org", __name__)


def _require_admin(institute_id):
    if not is_institute_admin(institute_id):
        abort(403)


@bp.route("/institutes")
@login_required
def institutes():
    rows = query(
        """
        SELECT i.*,
               (SELECT count(*) FROM person p
                 WHERE p.home_institute_id = i.institute_id AND p.status = 'ACTIVE') AS person_count,
               (SELECT count(*) FROM paper p WHERE p.institute_id = i.institute_id) AS paper_count,
               (SELECT count(*) FROM submission_batch b
                 WHERE b.institute_id = i.institute_id AND b.status = 'ARCHIVED') AS archived_count
          FROM institute i
         ORDER BY i.name
        """
    )
    return render_template("org/institutes.html", institutes=rows)


@bp.route("/institutes/<int:institute_id>")
@login_required
def institute_detail(institute_id):
    inst = query_one("SELECT * FROM institute WHERE institute_id = %s", (institute_id,))
    if not inst:
        abort(404)
    persons = query(
        """
        SELECT p.*, a.account_id, a.username, a.is_enabled,
               (SELECT count(*) FROM paper_author pa WHERE pa.person_id = p.person_id) AS paper_count
          FROM person p
          LEFT JOIN account a ON a.person_id = p.person_id
         WHERE p.home_institute_id = %s
         ORDER BY p.employee_no
        """,
        (institute_id,),
    )
    papers = query(
        "SELECT * FROM v_submission_overview WHERE institute_id = %s ORDER BY paper_id DESC",
        (institute_id,),
    )
    admins = query(
        """
        SELECT DISTINCT p.name, a.username, a.account_id
          FROM account_role ar
          JOIN account a ON a.account_id = ar.account_id
          JOIN person p ON p.person_id = a.person_id
         WHERE ar.role_code = 'INSTITUTE_ADMIN' AND ar.institute_id = %s AND ar.is_active
        """,
        (institute_id,),
    )
    pending_batches = query(
        """
        SELECT b.batch_id, b.round_no, b.status, b.submitted_at, p.title
          FROM submission_batch b
          JOIN paper p ON p.paper_id = b.paper_id
         WHERE b.institute_id = %s AND b.status IN ('PENDING_ADMIN','UNDER_REVIEW')
         ORDER BY b.submitted_at
        """,
        (institute_id,),
    )
    return render_template(
        "org/institute_detail.html",
        inst=inst,
        persons=persons,
        papers=papers,
        admins=admins,
        pending_batches=pending_batches,
        can_admin=is_institute_admin(institute_id),
    )


@bp.route("/persons/new", methods=("GET", "POST"))
@login_required
def person_new():
    institutes_all = query("SELECT institute_id, name FROM institute ORDER BY name")
    default_inst = as_int(request.args.get("institute_id")) or g.user["home_institute_id"]

    if request.method == "POST":
        inst_id = as_int(request.form.get("home_institute_id"))
        _require_admin(inst_id)
        try:
            person_id = query_one(
                """
                INSERT INTO person (employee_no, name, email, phone, person_category,
                                    title_grade, home_institute_id, join_date, status)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING person_id
                """,
                (
                    request.form["employee_no"].strip(),
                    request.form["name"].strip(),
                    request.form["email"].strip(),
                    request.form.get("phone") or None,
                    request.form.get("person_category") or "RESEARCHER",
                    request.form.get("title_grade") or None,
                    inst_id,
                    request.form.get("join_date") or None,
                    request.form.get("status") or "ACTIVE",
                ),
            )["person_id"]
            execute(
                """
                INSERT INTO person_affiliation (person_id, institute_id, role_title, valid_from, is_primary)
                VALUES (%s, %s, %s, COALESCE(%s::date, CURRENT_DATE), true)
                """,
                (person_id, inst_id, request.form.get("title_grade"),
                 request.form.get("join_date") or None),
            )
            flash("人员已创建", "success")
            return redirect(url_for("org.person_detail", person_id=person_id))
        except psycopg.errors.UniqueViolation:
            flash("工号或邮箱已存在", "danger")
        except Exception as exc:  # noqa: BLE001
            flash(f"创建失败：{exc}", "danger")

    return render_template("org/person_form.html", person=None, institutes=institutes_all,
                           default_inst=default_inst)


@bp.route("/persons/<int:person_id>/edit", methods=("GET", "POST"))
@login_required
def person_edit(person_id):
    person = query_one("SELECT * FROM person WHERE person_id = %s", (person_id,))
    if not person:
        abort(404)
    _require_admin(person["home_institute_id"] or 0)
    institutes_all = query("SELECT institute_id, name FROM institute ORDER BY name")

    if request.method == "POST":
        inst_id = as_int(request.form.get("home_institute_id")) or person["home_institute_id"]
        _require_admin(inst_id)
        try:
            execute(
                """
                UPDATE person
                   SET name = %s, email = %s, phone = %s, person_category = %s,
                       title_grade = %s, home_institute_id = %s, join_date = %s,
                       leave_date = %s, status = %s
                 WHERE person_id = %s
                """,
                (
                    request.form["name"].strip(),
                    request.form["email"].strip(),
                    request.form.get("phone") or None,
                    request.form.get("person_category") or "RESEARCHER",
                    request.form.get("title_grade") or None,
                    inst_id,
                    request.form.get("join_date") or None,
                    request.form.get("leave_date") or None,
                    request.form.get("status") or "ACTIVE",
                    person_id,
                ),
            )
            flash("人员信息已更新", "success")
            return redirect(url_for("org.person_detail", person_id=person_id))
        except psycopg.errors.UniqueViolation:
            flash("邮箱已被占用", "danger")

    return render_template("org/person_form.html", person=person, institutes=institutes_all,
                           default_inst=person["home_institute_id"])


@bp.route("/persons/<int:person_id>")
@login_required
def person_detail(person_id):
    person = query_one("SELECT * FROM person WHERE person_id = %s", (person_id,))
    if not person:
        abort(404)
    account = query_one("SELECT * FROM account WHERE person_id = %s", (person_id,))
    affiliations = query(
        """
        SELECT af.*, i.name AS institute_name
          FROM person_affiliation af
          JOIN institute i ON i.institute_id = af.institute_id
         WHERE af.person_id = %s
         ORDER BY af.valid_from DESC
        """,
        (person_id,),
    )
    roles = query(
        """
        SELECT ar.*, r.name AS role_name, i.name AS institute_name
          FROM account_role ar
          JOIN role r ON r.role_code = ar.role_code
          LEFT JOIN institute i ON i.institute_id = ar.institute_id
         WHERE ar.account_id = %s
         ORDER BY ar.granted_at DESC
        """,
        (account["account_id"],),
    ) if account else []
    papers = query(
        """
        SELECT v.*, pa.author_order, pa.is_corresponding
          FROM v_submission_overview v
          JOIN paper_author pa ON pa.paper_id = v.paper_id AND pa.person_id = %s
         ORDER BY v.paper_id DESC
        """,
        (person_id,),
    )
    owned = query(
        "SELECT * FROM v_submission_overview WHERE owner_person_id = %s",
        (person_id,),
    )
    return render_template(
        "org/person_detail.html",
        person=person,
        account=account,
        affiliations=affiliations,
        roles=roles,
        papers=papers,
        owned=owned,
        can_admin=is_institute_admin(person["home_institute_id"] or 0),
        institutes=query("SELECT institute_id, name FROM institute ORDER BY name"),
    )


@bp.route("/persons/<int:person_id>/accounts", methods=("POST",))
@login_required
def account_create(person_id):
    person = query_one("SELECT * FROM person WHERE person_id = %s", (person_id,))
    if not person:
        abort(404)
    _require_admin(person["home_institute_id"] or 0)
    username = (request.form.get("username") or "").strip()
    password = request.form.get("password") or ""
    if len(username) < 3 or len(password) < 6:
        flash("用户名至少 3 位，密码至少 6 位", "warning")
        return redirect(url_for("org.person_detail", person_id=person_id))
    try:
        execute(
            """
            INSERT INTO account (person_id, username, password_hash)
            VALUES (%s, %s, %s)
            """,
            (person_id, username, generate_password_hash(password, method="pbkdf2:sha256:600000")),
        )
        flash("账号已创建", "success")
    except psycopg.errors.UniqueViolation:
        flash("该人员已有账号或用户名已被占用", "danger")
    return redirect(url_for("org.person_detail", person_id=person_id))


@bp.route("/accounts/<int:account_id>/toggle", methods=("POST",))
@login_required
def account_toggle(account_id):
    account = query_one(
        "SELECT a.*, p.home_institute_id FROM account a JOIN person p ON p.person_id = a.person_id WHERE a.account_id = %s",
        (account_id,),
    )
    if not account:
        abort(404)
    _require_admin(account["home_institute_id"] or 0)
    enable = not account["is_enabled"]
    execute(
        "UPDATE account SET is_enabled = %s, disabled_reason = %s WHERE account_id = %s",
        (enable, None if enable else "管理员停用", account_id),
    )
    flash("账号已启用" if enable else "账号已停用", "success")
    return redirect(request.referrer or url_for("org.institutes"))


@bp.route("/accounts/<int:account_id>/password", methods=("POST",))
@login_required
def account_password(account_id):
    account = query_one(
        "SELECT a.*, p.home_institute_id FROM account a JOIN person p ON p.person_id = a.person_id WHERE a.account_id = %s",
        (account_id,),
    )
    if not account:
        abort(404)
    _require_admin(account["home_institute_id"] or 0)
    password = request.form.get("password") or ""
    if len(password) < 6:
        flash("密码至少 6 位", "warning")
    else:
        execute(
            "UPDATE account SET password_hash = %s WHERE account_id = %s",
            (generate_password_hash(password, method="pbkdf2:sha256:600000"), account_id),
        )
        flash("密码已重置", "success")
    return redirect(request.referrer or url_for("org.institutes"))


@bp.route("/accounts/<int:account_id>/roles", methods=("POST",))
@login_required
def role_grant(account_id):
    account = query_one(
        "SELECT a.*, p.home_institute_id FROM account a JOIN person p ON p.person_id = a.person_id WHERE a.account_id = %s",
        (account_id,),
    )
    if not account:
        abort(404)
    role_code = request.form.get("role_code")
    institute_id = as_int(request.form.get("institute_id"))
    if role_code == "INSTITUTE_ADMIN":
        _require_admin(institute_id)
    else:
        _require_admin(account["home_institute_id"] or 0)

    existing = query_one(
        """
        SELECT 1 FROM account_role
         WHERE account_id = %s AND role_code = %s AND is_active
           AND COALESCE(institute_id, 0) = COALESCE(%s, 0)
        """,
        (account_id, role_code, institute_id),
    )
    if existing:
        flash("该角色已生效，无需重复授予", "warning")
    else:
        execute(
            """
            INSERT INTO account_role (account_id, role_code, institute_id, granted_by, reason)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (account_id, role_code, institute_id, g.user["person_id"],
             request.form.get("reason") or "管理员授予"),
        )
        flash("角色已授予", "success")
    return redirect(request.referrer or url_for("org.person_detail", person_id=account["person_id"]))


@bp.route("/accounts/<int:account_id>/roles/<int:account_role_id>/revoke", methods=("POST",))
@login_required
def role_revoke(account_id, account_role_id):
    row = query_one(
        """
        SELECT ar.*, p.home_institute_id
          FROM account_role ar
          JOIN account a ON a.account_id = ar.account_id
          JOIN person p ON p.person_id = a.person_id
         WHERE ar.account_role_id = %s AND ar.account_id = %s
        """,
        (account_role_id, account_id),
    )
    if not row:
        abort(404)
    _require_admin(row["institute_id"] or row["home_institute_id"] or 0)
    execute(
        """
        UPDATE account_role
           SET is_active = false, revoked_at = now(), revoked_by = %s,
               reason = COALESCE(%s, reason)
         WHERE account_role_id = %s
        """,
        (g.user["person_id"], request.form.get("reason"), account_role_id),
    )
    flash("角色已撤销，历史记录已保留", "success")
    return redirect(request.referrer or url_for("org.institutes"))


@bp.route("/persons/<int:person_id>/affiliations", methods=("POST",))
@login_required
def affiliation_add(person_id):
    person = query_one("SELECT * FROM person WHERE person_id = %s", (person_id,))
    if not person:
        abort(404)
    institute_id = as_int(request.form.get("institute_id"))
    _require_admin(institute_id)
    execute(
        """
        INSERT INTO person_affiliation (person_id, institute_id, role_title, valid_from, valid_to, is_primary)
        VALUES (%s, %s, %s, COALESCE(%s::date, CURRENT_DATE), %s, false)
        """,
        (person_id, institute_id, request.form.get("role_title"),
         request.form.get("valid_from") or None, request.form.get("valid_to") or None),
    )
    flash("任职关系已添加", "success")
    return redirect(url_for("org.person_detail", person_id=person_id))
