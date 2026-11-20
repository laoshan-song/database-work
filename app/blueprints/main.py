from flask import Blueprint, g, redirect, render_template, request, url_for

from ..db import execute, query, query_one, scalar
from ..security import login_required

bp = Blueprint("main", __name__)


@bp.route("/")
@login_required
def dashboard():
    person_id = g.user["person_id"]
    account_id = g.user["account_id"]

    todos = query(
        "SELECT * FROM v_author_todo WHERE person_id = %s ORDER BY frozen_at DESC",
        (person_id,),
    )
    authored = query(
        """
        SELECT v.*
          FROM v_submission_overview v
          JOIN paper_author pa ON pa.paper_id = v.paper_id AND pa.person_id = %s
         ORDER BY v.last_updated_at DESC NULLS LAST
        """,
        (person_id,),
    )
    owned = query(
        "SELECT * FROM v_submission_overview WHERE owner_person_id = %s ORDER BY paper_id DESC",
        (person_id,),
    )
    notifications = query(
        "SELECT * FROM notification WHERE account_id = %s ORDER BY created_at DESC LIMIT 12",
        (account_id,),
    )
    unread = scalar(
        "SELECT count(*) FROM notification WHERE account_id = %s AND read_at IS NULL",
        (account_id,),
    )
    my_requests = query(
        """
        SELECT ar.*, m.name AS material_name, mv.version_no, p.title,
               s.grant_status
          FROM access_request ar
          JOIN material_version mv ON mv.material_version_id = ar.material_version_id
          JOIN material m ON m.material_id = mv.material_id
          JOIN paper p ON p.paper_id = m.paper_id
          LEFT JOIN v_access_grant_status s ON s.request_id = ar.request_id
         WHERE ar.requester_account_id = %s
         ORDER BY ar.created_at DESC
         LIMIT 8
        """,
        (account_id,),
    )

    admin_batches = []
    pending_access = []
    stats = None
    if g.user["is_system_admin"] or g.user["admin_institutes"]:
        scopes = g.user["admin_institutes"]
        if g.user["is_system_admin"]:
            admin_batches = query(
                """
                SELECT b.*, p.title, i.name AS institute_name,
                       (SELECT count(*) FROM confirmation c WHERE c.batch_id = b.batch_id
                         AND c.is_current AND c.action = 'CONFIRM') AS confirmed
                  FROM submission_batch b
                  JOIN paper p ON p.paper_id = b.paper_id
                  JOIN institute i ON i.institute_id = b.institute_id
                 WHERE b.status IN ('PENDING_ADMIN','UNDER_REVIEW')
                 ORDER BY b.submitted_at
                """
            )
            pending_access = query(
                """
                SELECT ar.*, per.name AS requester, m.name AS material_name, p.title
                  FROM access_request ar
                  JOIN account a ON a.account_id = ar.requester_account_id
                  JOIN person per ON per.person_id = a.person_id
                  JOIN material_version mv ON mv.material_version_id = ar.material_version_id
                  JOIN material m ON m.material_id = mv.material_id
                  JOIN paper p ON p.paper_id = m.paper_id
                 WHERE ar.status = 'PENDING'
                 ORDER BY ar.created_at
                """
            )
        else:
            admin_batches = query(
                """
                SELECT b.*, p.title, i.name AS institute_name,
                       (SELECT count(*) FROM confirmation c WHERE c.batch_id = b.batch_id
                         AND c.is_current AND c.action = 'CONFIRM') AS confirmed
                  FROM submission_batch b
                  JOIN paper p ON p.paper_id = b.paper_id
                  JOIN institute i ON i.institute_id = b.institute_id
                 WHERE b.institute_id = ANY(%s)
                   AND b.status IN ('PENDING_ADMIN','UNDER_REVIEW')
                 ORDER BY b.submitted_at
                """,
                (scopes,),
            )
            pending_access = query(
                """
                SELECT ar.*, per.name AS requester, m.name AS material_name, p.title
                  FROM access_request ar
                  JOIN account a ON a.account_id = ar.requester_account_id
                  JOIN person per ON per.person_id = a.person_id
                  JOIN material_version mv ON mv.material_version_id = ar.material_version_id
                  JOIN material m ON m.material_id = mv.material_id
                  JOIN paper p ON p.paper_id = m.paper_id
                 WHERE ar.status = 'PENDING' AND p.institute_id = ANY(%s)
                 ORDER BY ar.created_at
                """,
                (scopes,),
            )
        stats = {
            "pending_batches": len(admin_batches),
            "pending_access": len(pending_access),
        }

    return render_template(
        "dashboard.html",
        todos=todos,
        authored=authored,
        owned=owned,
        notifications=notifications,
        unread=unread,
        my_requests=my_requests,
        admin_batches=admin_batches,
        pending_access=pending_access,
        stats=stats,
    )


@bp.route("/notifications/read", methods=("POST",))
@login_required
def read_notifications():
    execute(
        "UPDATE notification SET read_at = now() WHERE account_id = %s AND read_at IS NULL",
        (g.user["account_id"],),
    )
    return redirect(request.referrer or url_for("main.dashboard"))


@bp.route("/notifications/<int:notification_id>/open")
@login_required
def open_notification(notification_id):
    row = query_one(
        "SELECT * FROM notification WHERE notification_id = %s AND account_id = %s",
        (notification_id, g.user["account_id"]),
    )
    if row:
        execute("UPDATE notification SET read_at = COALESCE(read_at, now()) WHERE notification_id = %s",
                (notification_id,))
        if row["link_url"]:
            return redirect(row["link_url"])
    return redirect(url_for("main.dashboard"))
