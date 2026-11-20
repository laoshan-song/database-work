"""登录态、角色与论文级权限判断。"""
from functools import wraps

from flask import abort, flash, g, redirect, request, session, url_for

from .db import query, query_one


def init_app(app):
    app.before_request(load_user)


def load_user():
    g.user = None
    account_id = session.get("account_id")
    if not account_id:
        return
    row = query_one(
        """
        SELECT a.account_id, a.person_id, a.username, a.is_system_admin, a.is_enabled,
               p.name, p.email, p.person_category, p.home_institute_id
          FROM account a
          JOIN person p ON p.person_id = a.person_id
         WHERE a.account_id = %s
        """,
        (account_id,),
    )
    if not row or not row["is_enabled"]:
        session.clear()
        return
    row["admin_institutes"] = [
        r["institute_id"]
        for r in query(
            """
            SELECT institute_id FROM account_role
             WHERE account_id = %s AND role_code = 'INSTITUTE_ADMIN'
               AND is_active AND institute_id IS NOT NULL
            """,
            (account_id,),
        )
    ]
    g.user = row


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if g.user is None:
            flash("请先登录", "warning")
            return redirect(url_for("auth.login", next=request.full_path))
        return view(*args, **kwargs)

    return wrapped


def admin_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if g.user is None:
            return redirect(url_for("auth.login", next=request.full_path))
        if not (g.user["is_system_admin"] or g.user["admin_institutes"]):
            abort(403)
        return view(*args, **kwargs)

    return wrapped


def is_sys_admin():
    return bool(g.user and g.user["is_system_admin"])


def is_institute_admin(institute_id):
    if not g.user:
        return False
    if g.user["is_system_admin"]:
        return True
    return institute_id in g.user["admin_institutes"]


def paper_permissions(paper):
    """返回当前用户对论文的细粒度权限。"""
    perms = {
        "owner": False,
        "admin": False,
        "author": False,
        "maintainer": False,
        "manage": False,     # 论文信息、作者名单
        "material": False,   # 上传材料
        "experiment": False, # 登记实验
    }
    if not g.user or not paper:
        return perms

    person_id = g.user["person_id"]
    perms["owner"] = paper["owner_person_id"] == person_id
    perms["admin"] = is_institute_admin(paper["institute_id"])

    perms["author"] = bool(
        query_one(
            "SELECT 1 FROM paper_author WHERE paper_id = %s AND person_id = %s",
            (paper["paper_id"], person_id),
        )
    )
    maint = query_one(
        """
        SELECT scope FROM paper_maintainer
         WHERE paper_id = %s AND person_id = %s AND revoked_at IS NULL
        """,
        (paper["paper_id"], person_id),
    )
    if maint:
        perms["maintainer"] = True
        perms["material"] = maint["scope"] in ("ALL", "MATERIAL")
        perms["experiment"] = maint["scope"] in ("ALL", "EXPERIMENT")

    if perms["owner"] or perms["admin"]:
        perms["manage"] = perms["material"] = perms["experiment"] = True
    if g.user["is_system_admin"]:
        perms.update(owner=True, admin=True, manage=True, material=True, experiment=True)
    return perms


def can_view_paper(paper):
    if not g.user or not paper:
        return False
    perms = paper_permissions(paper)
    if perms["owner"] or perms["admin"] or perms["author"] or perms["maintainer"]:
        return True

    archived = query_one(
        "SELECT 1 FROM submission_batch WHERE paper_id = %s AND status = 'ARCHIVED'",
        (paper["paper_id"],),
    )
    if not archived:
        return False

    if paper["visibility_level"] == "PUBLIC":
        return True
    if paper["visibility_level"] == "INSTITUTE":
        return bool(
            query_one(
                """
                SELECT 1 FROM person_affiliation
                 WHERE person_id = %s AND institute_id = %s
                   AND valid_from <= CURRENT_DATE
                   AND (valid_to IS NULL OR valid_to >= CURRENT_DATE)
                """,
                (g.user["person_id"], paper["institute_id"]),
            )
        )
    return False


def require_paper_view(paper):
    if not can_view_paper(paper):
        abort(403)


def require_paper_manage(paper):
    if not paper_permissions(paper)["manage"]:
        abort(403)
