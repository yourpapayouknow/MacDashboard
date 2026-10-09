// SHA256引用共用ASCII十六进制边界。
export function dgtref(value) {
  return typeof value === "string" && value.length === 64 && /^[0-9a-fA-F]+$/.test(value);
}

// 公开证书附件只接受完整十六进制指纹。
export function crtref(value) {
  return dgtref(value)
    ? `/api/v1/certificates/${value.toUpperCase()}/download` : undefined;
}

// 转换 HTTP ISO 日期与 Swift 本地编码日期。
export function dt(value) {
  return typeof value === "string"
    ? new Date(value)
    : new Date((value + 978307200) * 1000);
}

// 格式化字节与吞吐量。
export function fmtbyt(value, rate = false) {
  if (!Number.isFinite(value) || value < 0) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  const level =
    value === 0 ? 0 : Math.min(4, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** level).toFixed(level === 0 ? 0 : 1)} ${units[level]}${rate ? "/s" : ""}`;
}

// 格式化开机时长。
export function uptm(value) {
  const hours = Math.floor(value / 3600);
  return `${Math.floor(hours / 24)} 天 ${hours % 24} 小时`;
}

// 创建有限历史查询边界。
export function histqry(hours, now = Date.now()) {
  const to = Math.floor(now / 1000);
  return `from=${to - hours * 3600}&to=${to}&maxPoints=360`;
}

// 翻译原生网卡类型与用途，未知值不冒充普通网卡。
export function netlbl(kind, role) {
  const type = { physical: "物理网卡", tunnel: "隧道", loopback: "回环", bridge: "网桥", peer: "点对点", virtual: "虚拟", other: "其他" }[kind] ?? "未确认";
  const usage = { flClash: "FlClash", tailscale: "Tailscale", systemTunnel: "系统隧道" }[role] ?? "未确认";
  return role === "ordinary" || type === usage ? type : `${type}·${usage}`;
}

// 汇总物理网卡以避免隧道重复计数。
export function netttl(rates) {
  return rates
    .filter((rate) => rate.kind === "physical")
    .reduce(
      (sum, rate) => ({
        rx: sum.rx + rate.receivedBytesPerSecond,
        tx: sum.tx + rate.sentBytesPerSecond,
      }),
      { rx: 0, tx: 0 },
    );
}

// 保留宝塔的字节单位文案，复用原有1024换算。
export function fmtbt(value, rate = false) {
  return fmtbyt(value, rate).replace(/([KMGT])iB/g, "$1B");
}

// 防止迟到响应覆盖同一计划已确认的进度。
export function plnprg(current, next) {
  const states = ["pending", "queued", "authorized", "executing", "succeeded", "failed", "expired", "rolledBack"];
  return current?.id === next.id && (states.indexOf(current.state) >= 4
    || states.indexOf(next.state) < states.indexOf(current.state)) ? current : next;
}

// 文件表单和请求复用同一相对路径边界。
export function flpath(path) {
  return typeof path === "string" && !!path && !/[\0\r\n]/.test(path)
    && new TextEncoder().encode(path).length <= 512
    && path.split("/").every((part) => part && ![".", ".."].includes(part) && new TextEncoder().encode(part).length <= 255);
}

// 固定根目录标识与安全相对路径构成文件目标。
export function flref(root, path) {
  return /^[A-Za-z0-9_-]{1,64}$/.test(root ?? "") && flpath(path);
}

// 文本编辑保持原有预览字节上限并拒绝NUL。
export function txtok(value) {
  return typeof value === "string" && !value.includes("\0") && new TextEncoder().encode(value).length <= 262144;
}

// 文件请求和回归测试共用完整动作与参数校验。
export function flreq(id, action, parameters) {
  if (id !== `${parameters.rootID}:${parameters.relativePath}` || !flref(parameters.rootID, parameters.relativePath)) return false;
  const count = Object.keys(parameters).length;
  return ["createDirectory", "trash"].includes(action) && count === 2
    || action === "createFile" && count === 3 && txtok(parameters.content)
    || action === "move" && count === 4 && flref(parameters.destinationRootID, parameters.destinationRelativePath)
    || action === "write" && count === 4 && dgtref(parameters.digest) && txtok(parameters.content)
    || action === "restore" && count === 3 && bkpref(parameters.backupID);
}

// 软件请求只接受精确标识和已实现动作。
export function pkgreq(id, action, parameters) {
  if (parameters?.kind === "tap") return !Array.isArray(parameters) && typeof id === "string" && id.length <= 255
    && /^[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*$/.test(id) && !/[\r\n]/.test(id)
    && !/\/(homebrew-|linuxbrew-)/.test(id) && ["install", "remove"].includes(action)
    && Object.keys(parameters).length === 1;
  return typeof id === "string" && id.length <= 255 && /^[A-Za-z0-9][A-Za-z0-9_.+@-]*(\/[A-Za-z0-9][A-Za-z0-9_.+@-]*){0,2}$/.test(id)
    && !/[\r\n]/.test(id) && !!parameters && typeof parameters === "object" && !Array.isArray(parameters)
    && Object.keys(parameters).every((key) => ["kind", "backupID"].includes(key))
    && (parameters.kind === undefined || parameters.kind === "cask")
    && (["install", "remove", "pin", "unpin", "upgrade"].includes(action)
        && Object.keys(parameters).length === (parameters.kind === "cask" ? 1 : 0)
      || action === "restore" && Object.keys(parameters).length === (parameters.kind === "cask" ? 2 : 1) && bkpref(parameters.backupID));
}

// 仓库附件只属于已执行的源移除，不提供自动恢复。
export function tapbkpref(plan) {
  return plan?.domain === "package" && plan.action === "remove" && plan.parameters?.kind === "tap"
    && Object.keys(plan.parameters).length === 1 && ["succeeded", "failed"].includes(plan.state)
    && plan.backup?.kind === "homebrew-tap-repository" && bkpref(plan.rollbackToken);
}

// 容器请求只接受完整身份、规范本机连接及稳定引擎标识。
export function ctrreq(id, action, parameters) {
  if (typeof id !== "string" || !/^[a-f0-9]{64}$/.test(id) || !["start", "stop", "restart", "remove"].includes(action)
    || !parameters || typeof parameters !== "object" || Array.isArray(parameters)
    || Object.keys(parameters).length !== 2 || !Object.hasOwn(parameters, "endpoint") || !Object.hasOwn(parameters, "daemonID")) return false;
  const { endpoint, daemonID } = parameters;
  if (typeof endpoint !== "string" || !endpoint.startsWith("unix:///") || new TextEncoder().encode(endpoint).length > 512
    || /[\0\r\n%]/.test(endpoint)) return false;
  const path = endpoint.slice(8);
  return !!path && path.split("/").every((part) => part && ![".", ".."].includes(part))
    && typeof daemonID === "string" && /^[A-Za-z0-9:-]{1,128}$/.test(daemonID) && !/[\r\n]/.test(daemonID);
}

// 文本恢复复用原任务备份类型，不混用移动状态。
export function txtbkp(plan) {
  return plan?.domain === "file" && ["write", "restore"].includes(plan.action) && plan.backup?.kind === "file-text-state";
}

// 已执行文本任务保留原文附件用于人工恢复。
export function txtbkpref(plan) {
  return txtbkp(plan) && ["succeeded", "rolledBack", "failed"].includes(plan.state) && bkpref(plan.rollbackToken);
}

// 恢复请求只接收规范UUID备份标识。
export function bkpref(value) {
  return typeof value === "string" && value.length === 36 && /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value);
}

// 任务页只为可恢复的成功动作提供一个处理入口。
export function rstrbl(plan) {
  return plan?.state === "succeeded" && bkpref(plan.rollbackToken)
    && (plan.domain === "file" && (plan.action === "move" || plan.action === "trash" && plan.backup?.kind === "file-trash-state" || txtbkp(plan)) || plan.domain === "package" && ["pin", "unpin"].includes(plan.action)
      || dbbkpref(plan));
}

// 已成功或已用过的数据库快照保留下载入口。
export function dbbkpref(plan) {
  return plan?.domain === "database" && ["succeeded", "rolledBack"].includes(plan.state)
    && ["backup", "restore"].includes(plan.action) && bkpref(plan.rollbackToken);
}
