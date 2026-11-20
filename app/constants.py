"""状态、类型的中文标签与配色，供模板统一使用。"""

BATCH_STATUS = {
    "DRAFT": "草稿",
    "PENDING_AUTHORS": "待共同作者确认",
    "READY_TO_SUBMIT": "确认完成待提交",
    "PENDING_ADMIN": "待管理员审核",
    "UNDER_REVIEW": "审核中",
    "DISPUTED": "存在异议",
    "RETURNED": "退回修改",
    "WITHDRAWN": "已撤回",
    "ARCHIVED": "已归档",
}

STATUS_COLOR = {
    "DRAFT": "secondary",
    "PENDING_AUTHORS": "warning",
    "READY_TO_SUBMIT": "info",
    "PENDING_ADMIN": "primary",
    "UNDER_REVIEW": "primary",
    "DISPUTED": "danger",
    "RETURNED": "danger",
    "WITHDRAWN": "secondary",
    "ARCHIVED": "success",
}

CONFIRM_STATE = {
    "PENDING": "待确认",
    "CONFIRM": "已确认",
    "WITHDRAW": "已撤回",
    "DISPUTE": "已提出异议",
}

CONFIRM_COLOR = {
    "PENDING": "secondary",
    "CONFIRM": "success",
    "WITHDRAW": "warning",
    "DISPUTE": "danger",
}

MATERIAL_TYPES = {
    "PAPER": "论文文件",
    "CODE": "代码",
    "RAW_DATA": "原始数据",
    "DATA_DICT": "数据字典",
    "CONFIG": "实验配置",
    "LOG": "运行日志",
    "RESULT": "实验结果",
    "FIGURE": "图表",
    "NOTES": "说明文件",
}

MATERIAL_COLOR = {
    "PAPER": "dark",
    "CODE": "primary",
    "RAW_DATA": "success",
    "DATA_DICT": "info",
    "CONFIG": "warning",
    "LOG": "secondary",
    "RESULT": "danger",
    "FIGURE": "info",
    "NOTES": "secondary",
}

PAPER_STAGE = {
    "DRAFT": "初稿",
    "SUBMISSION": "投稿稿",
    "REVISION": "修改稿",
    "ACCEPTED": "录用稿",
    "FINAL": "最终发表稿",
}

SUBMISSION_STATUS = {
    "DRAFT": "未投稿",
    "SUBMITTED": "已投稿",
    "UNDER_REVIEW": "审稿中",
    "ACCEPTED": "已录用",
    "PUBLISHED": "已发表",
    "REJECTED": "被拒稿",
}

VISIBILITY = {
    "PUBLIC": "公开",
    "INSTITUTE": "研究所内部",
    "PROJECT": "项目成员",
    "RESTRICTED": "指定人员",
}

VISIBILITY_COLOR = {
    "PUBLIC": "success",
    "INSTITUTE": "info",
    "PROJECT": "primary",
    "RESTRICTED": "danger",
}

PERSON_CATEGORY = {
    "RESEARCHER": "研究人员",
    "STUDENT": "学生",
    "STAFF": "职员",
    "EXTERNAL": "外部人员",
}

PERSON_STATUS = {"ACTIVE": "在岗", "INACTIVE": "停用", "LEFT": "已离所"}

ROLE_NAMES = {
    "INSTITUTE_ADMIN": "研究所管理员",
    "DATA_USER": "数据使用者",
    "MAINTAINER": "授权维护成员",
    "SYS_ADMIN": "平台运维",
}

GRANT_STATUS = {
    "ACTIVE": "生效中",
    "EXPIRED": "已过期",
    "REVOKED": "已撤销",
    "NOT_YET": "未生效",
    "EXHAUSTED": "次数用尽",
}

GRANT_COLOR = {
    "ACTIVE": "success",
    "EXPIRED": "secondary",
    "REVOKED": "danger",
    "NOT_YET": "info",
    "EXHAUSTED": "warning",
}

REVIEW_ACTION = {"ACCEPT": "受理", "APPROVE": "通过", "RETURN": "退回"}
