from flask import Blueprint, flash, g, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash

from ..db import execute, query_one
from ..utils import safe_next

bp = Blueprint("auth", __name__)


@bp.route("/login", methods=("GET", "POST"))
def login():
    if g.user is not None:
        return redirect(url_for("main.dashboard"))

    if request.method == "POST":
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        account = query_one(
            """
            SELECT a.account_id, a.password_hash, a.is_enabled, p.name
              FROM account a
              JOIN person p ON p.person_id = a.person_id
             WHERE a.username = %s
            """,
            (username,),
        )
        if not account or not account["is_enabled"] or not check_password_hash(account["password_hash"], password):
            flash("用户名或密码错误，或账号已被停用", "danger")
        else:
            session.clear()
            session["account_id"] = account["account_id"]
            session.permanent = True
            execute("UPDATE account SET last_login_at = now() WHERE account_id = %s", (account["account_id"],))
            flash(f"欢迎回来，{account['name']}", "success")
            return redirect(safe_next(request.args.get("next")) or url_for("main.dashboard"))

    return render_template("login.html")


@bp.route("/logout", methods=("POST",))
def logout():
    session.clear()
    flash("已退出登录", "info")
    return redirect(url_for("auth.login"))
