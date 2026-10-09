// 仅提供无凭据的HTTP管理入口。
export function mgmtlnk(value) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) &&
      !url.username &&
      !url.password
      ? url.href
      : undefined;
  } catch {
    return undefined;
  }
}

// 按完整监听端点搜索，保留一个进程对应一项。
export function sitflt(rows, query, kind = "all") {
  const needle = query.trim().toLowerCase();
  return rows.filter(
    (row) =>
      (kind === "all" || row.kind === kind) &&
      `${row.process} ${row.pid} ${row.kind} ${row.listeners.map((item) => `${item.protocolName} ${item.address}:${item.port}`).join(" ")}`
        .toLowerCase()
        .includes(needle),
  );
}

// 保留服务类型的原生替换名称。
export function sitkind(value) {
  return (
    {
      web: "Web项目",
      dns: "DNS服务",
      reverseProxy: "反向代理",
      system: "系统服务",
      other: "其他项目",
    }[value] ?? value
  );
}

// 精确关联启动标签和配置来源，拒绝按程序名猜测。
export function defrt(rows, definition) {
  if (!definition) return undefined;
  return rows.find(
    (row) =>
      row.manager === "launchd" &&
      row.id === definition.label &&
      row.source === definition.source &&
      row.definitionPath === definition.definitionPath,
  );
}

// 计划任务只关联同一来源及配置位置的唯一launchd服务。
export function schdsvc(rows, task) {
  if (task?.manager !== "launchd" || !task.source || !task.definitionPath) return undefined;
  const matches = rows.filter((row) => row.manager === "launchd" && row.id === task.id);
  return matches.length === 1 ? defrt(matches, { label: task.id, source: task.source, definitionPath: task.definitionPath }) : undefined;
}

// 按完整启动定义读取备注。
export function notefnd(rows, definition) {
  if (!definition) return undefined;
  return rows.find((row) => row.label === definition.label &&
    row.source === definition.source && row.definitionPath === definition.definitionPath);
}

// 按父进程关系收集项目进程，阻止循环和重复PID。
export function prctree(rows, pid) {
  const root = rows.find((row) => row.pid === pid);
  if (!root) return [];
  const children = new Map();
  for (const row of rows) {
    const list = children.get(row.parentPID) ?? [];
    list.push(row);
    children.set(row.parentPID, list);
  }
  const result = [root];
  const seen = new Set([pid]);
  for (let index = 0; index < result.length; index++) {
    for (const row of children.get(result[index].pid) ?? []) {
      if (!seen.has(row.pid)) { seen.add(row.pid); result.push(row); }
    }
  }
  return result;
}

// 区分实际运行、等待调度、退出和未知状态。
export function srvstt(value) {
  return (
    {
      running: "运行中",
      stopped: "已停止",
      scheduled: "等待运行",
      error: "异常",
      unloaded: "未加载",
      unknown: "未知",
    }[value] ?? "未知"
  );
}

// 分离原生IPv4、IPv6和通配监听端点，保留未知值。
export function endpt(value) {
  const match = typeof value === "string" && value.match(/^(.*):(\d+)$/);
  if (!match || Number(match[2]) > 65535) return { address: value || "—", port: "—" };
  return { address: match[1].replace(/^\[(.*)\]$/, "$1"), port: Number(match[2]) };
}
