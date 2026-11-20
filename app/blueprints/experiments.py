import json
from datetime import datetime

import psycopg
from flask import Blueprint, abort, flash, g, redirect, render_template, request, url_for

from ..db import execute, query, query_one
from ..security import login_required, paper_permissions, require_paper_view
from ..utils import as_int

bp = Blueprint("experiments", __name__)


def _paper(paper_id):
    paper = query_one("SELECT * FROM paper WHERE paper_id = %s", (paper_id,))
    if not paper:
        abort(404)
    return paper


def _parse_dt(value):
    if not value:
        return None
    value = value.replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    raise ValueError(f"无法解析时间：{value}")


@bp.route("/papers/<int:paper_id>/experiments/new", methods=("GET", "POST"))
@login_required
def task_new(paper_id):
    paper = _paper(paper_id)
    if not paper_permissions(paper)["experiment"]:
        abort(403)
    if request.method == "POST":
        task_id = query_one(
            """
            INSERT INTO experiment_task (paper_id, title, purpose, scheme, metrics, created_by)
            VALUES (%s, %s, %s, %s, %s, %s) RETURNING task_id
            """,
            (paper_id, request.form["title"].strip(), request.form.get("purpose") or None,
             request.form.get("scheme") or None, request.form.get("metrics") or None,
             g.user["person_id"]),
        )["task_id"]
        flash("实验任务已创建", "success")
        return redirect(url_for("experiments.task_detail", task_id=task_id))
    return render_template("experiments/task_form.html", paper=paper, task=None)


@bp.route("/experiments/<int:task_id>")
@login_required
def task_detail(task_id):
    task = query_one(
        """
        SELECT t.*, p.title AS paper_title, p.paper_id, p.institute_id, per.name AS creator
          FROM experiment_task t
          JOIN paper p ON p.paper_id = t.paper_id
          JOIN person per ON per.person_id = t.created_by
         WHERE t.task_id = %s
        """,
        (task_id,),
    )
    if not task:
        abort(404)
    paper = _paper(task["paper_id"])
    require_paper_view(paper)
    perms = paper_permissions(paper)

    runs = query(
        """
        SELECT r.*,
               mc.name AS code_name, vc.version_no AS code_version,
               md.name AS data_name, vd.version_no AS data_version,
               mf.name AS config_name, vf.version_no AS config_version,
               ml.name AS log_name, vl.version_no AS log_version,
               (SELECT count(*) FROM experiment_result x WHERE x.run_id = r.run_id) AS result_count
          FROM experiment_run r
          JOIN material_version vc ON vc.material_version_id = r.code_version_id
          JOIN material mc ON mc.material_id = vc.material_id
          JOIN material_version vd ON vd.material_version_id = r.data_version_id
          JOIN material md ON md.material_id = vd.material_id
          LEFT JOIN material_version vf ON vf.material_version_id = r.config_version_id
          LEFT JOIN material mf ON mf.material_id = vf.material_id
          LEFT JOIN material_version vl ON vl.material_version_id = r.log_version_id
          LEFT JOIN material ml ON ml.material_id = vl.material_id
         WHERE r.task_id = %s
         ORDER BY r.started_at DESC, r.run_id DESC
        """,
        (task_id,),
    )
    results = query(
        """
        SELECT r.*, run.run_label, m.name AS result_name, mv.version_no,
               f.original_name
          FROM experiment_result r
          JOIN experiment_run run ON run.run_id = r.run_id
          JOIN material_version mv ON mv.material_version_id = r.result_version_id
          JOIN material m ON m.material_id = mv.material_id
          JOIN file_object f ON f.file_id = mv.file_id
         WHERE run.task_id = %s
         ORDER BY r.result_id DESC
        """,
        (task_id,),
    )
    versions = query(
        """
        SELECT mv.material_version_id, mv.version_no, m.name, m.material_type
          FROM material_version mv
          JOIN material m ON m.material_id = mv.material_id
         WHERE m.paper_id = %s
         ORDER BY m.material_type, m.name, mv.version_no DESC
        """,
        (paper["paper_id"],),
    )
    return render_template(
        "experiments/task_detail.html",
        task=task,
        paper=paper,
        perms=perms,
        runs=runs,
        results=results,
        versions=versions,
    )


@bp.route("/experiments/<int:task_id>/runs", methods=("POST",))
@login_required
def run_new(task_id):
    task = query_one("SELECT * FROM experiment_task WHERE task_id = %s", (task_id,))
    if not task:
        abort(404)
    paper = _paper(task["paper_id"])
    if not paper_permissions(paper)["experiment"]:
        abort(403)
    try:
        params = json.loads(request.form.get("parameters") or "{}")
        if not isinstance(params, dict):
            raise ValueError("参数必须是 JSON 对象")
    except (ValueError, json.JSONDecodeError) as exc:
        flash(f"参数格式错误：{exc}", "danger")
        return redirect(url_for("experiments.task_detail", task_id=task_id))
    try:
        execute(
            """
            INSERT INTO experiment_run (task_id, run_label, code_version_id, data_version_id,
                                        config_version_id, log_version_id, parameters,
                                        hardware_env, software_env, started_at, ended_at,
                                        status, created_by)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                task_id,
                request.form["run_label"].strip(),
                as_int(request.form["code_version_id"]),
                as_int(request.form["data_version_id"]),
                as_int(request.form.get("config_version_id")),
                as_int(request.form.get("log_version_id")),
                json.dumps(params, ensure_ascii=False),
                request.form.get("hardware_env") or None,
                request.form.get("software_env") or None,
                _parse_dt(request.form.get("started_at")),
                _parse_dt(request.form.get("ended_at")),
                request.form.get("status") or "SUCCESS",
                g.user["person_id"],
            ),
        )
        flash("实验运行已登记（引用的版本已固定，不随材料更新变化）", "success")
    except (psycopg.errors.UniqueViolation, psycopg.errors.RaiseException,
            psycopg.errors.CheckViolation) as exc:
        flash(str(exc).splitlines()[0], "danger")
    except ValueError as exc:
        flash(str(exc), "danger")
    return redirect(url_for("experiments.task_detail", task_id=task_id))


@bp.route("/runs/<int:run_id>/results", methods=("POST",))
@login_required
def result_new(run_id):
    run = query_one(
        """
        SELECT r.*, t.paper_id FROM experiment_run r
          JOIN experiment_task t ON t.task_id = r.task_id
         WHERE r.run_id = %s
        """,
        (run_id,),
    )
    if not run:
        abort(404)
    paper = _paper(run["paper_id"])
    if not paper_permissions(paper)["experiment"]:
        abort(403)
    try:
        execute(
            """
            INSERT INTO experiment_result (run_id, result_version_id, metric_summary,
                                           paper_figure_no, conclusion)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (run_id, as_int(request.form["result_version_id"]),
             request.form.get("metric_summary") or None,
             request.form.get("paper_figure_no") or None,
             request.form.get("conclusion") or None),
        )
        flash("实验结果已登记并关联到具体运行", "success")
    except (psycopg.errors.UniqueViolation, psycopg.errors.RaiseException,
            psycopg.errors.CheckViolation) as exc:
        flash(str(exc).splitlines()[0], "danger")
    return redirect(url_for("experiments.task_detail", task_id=run["task_id"]))


@bp.route("/trace")
@login_required
def trace():
    figure = (request.args.get("figure") or "").strip()
    keyword = (request.args.get("keyword") or "").strip()
    sql = ["SELECT * FROM v_result_trace WHERE 1 = 1"]
    params = []
    if figure:
        sql.append(" AND paper_figure_no ILIKE %s")
        params.append(f"%{figure}%")
    if keyword:
        sql.append(" AND (result_name ILIKE %s OR conclusion ILIKE %s OR metric_summary ILIKE %s)")
        params += [f"%{keyword}%", f"%{keyword}%", f"%{keyword}%"]
    sql.append(" ORDER BY started_at DESC")
    rows = query("".join(sql), params)
    return render_template("experiments/trace.html", rows=rows,
                           figure=figure, keyword=keyword)


@bp.route("/trace/<int:result_id>")
@login_required
def trace_detail(result_id):
    row = query_one("SELECT * FROM v_result_trace WHERE result_id = %s", (result_id,))
    if not row:
        abort(404)
    return render_template("experiments/trace_detail.html", r=row)
