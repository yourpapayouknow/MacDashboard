import { useQuery } from "./head";
import { bkpref, ctrreq, flref, flreq, histqry, pkgreq } from "./format.mjs";
import type { Plan, SiteNote, Svcop } from "./types";

// 复用同源JSON写请求，禁止自动重试。
async function wrtapi<T>(path: string, value: unknown): Promise<T> {
  const response = await fetch(`/api/v1/${path}`, {
    method: "POST", signal: AbortSignal.timeout(15000), credentials: "same-origin",
    headers: { Accept: "application/json", "Content-Type": "application/json" }, body: JSON.stringify(value),
  });
  if (!response.ok) throw new Error(`请求失败：HTTP${response.status}`);
  return response.json();
}

// 复用实际管理域的精确计划创建入口。
export async function plnpost(domain: string, id: string, action: string, parameters: Record<string, string> = {}): Promise<Plan> {
  const valid = domain === "package"
    ? pkgreq(id, action, parameters)
    : domain === "container" ? ctrreq(id, action, parameters)
    : domain === "database" ? id === `${parameters.rootID}:${parameters.relativePath}` && flref(parameters.rootID, parameters.relativePath)
      && (action === "backup" && Object.keys(parameters).length === 2
        || action === "restore" && Object.keys(parameters).length === 3 && bkpref(parameters.backupID))
    : domain === "file" && flreq(id, action, parameters);
  if (!valid) throw new Error("目标或操作无效");
  return wrtapi("environments/plans", { domain, action, target: id, parameters,
    confirmation: `${domain}:${action}:${id}` });
}

// 对同一计划精确确认，重试不会创建第二次操作。
export async function planexec(plan: Plan): Promise<Plan> {
  return wrtapi(`environments/plans/${encodeURIComponent(plan.id)}/execute`,
    { confirmation: `${plan.domain}:${plan.action}:${plan.target}` });
}

// 仅保存面板备注，不请求管理员权限或修改启动配置。
export async function noteput(value: SiteNote): Promise<SiteNote> {
  return wrtapi("sites/notes", value);
}

// 提交固定服务操作，管理员授权留在本机系统界面。
export async function svcpost(id: string, action: string): Promise<Svcop> {
  if (
    !/^[A-Za-z0-9_.-]{1,255}$/.test(id) ||
    [".", ".."].includes(id) ||
    !["start", "stop", "restart"].includes(action)
  )
    throw new Error("项目或操作无效");
  return wrtapi(`services/${encodeURIComponent(id)}/${action}`, { id, action, confirmation: id });
}

// 请求同源只读 API 并限制等待时间。
export async function rdapi<T>(path: string, signal?: AbortSignal): Promise<T> {
  const timeout = AbortSignal.timeout(15000);
  const response = await fetch(`/api/v1/${path}`, {
    signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  });
  if (!response.ok) throw new Error(`请求失败（HTTP ${response.status}）`);
  return response.json();
}

// 复用轮询缓存与取消机制。
export function qry<T>(path: string, interval = 5000, enabled = true) {
  return useQuery<T, Error>({
    queryKey: [path],
    enabled,
    queryFn: ({ signal }) => rdapi<T>(path, signal),
    refetchInterval: interval,
    staleTime: interval,
    retry: 1,
    refetchIntervalInBackground: false,
  });
}

// 保持缓存键稳定并按当前时间滚动历史范围。
export function hqry<T>(path: string, hours: number, enabled = true) {
  return useQuery<T, Error>({
    queryKey: ["history", path, hours],
    enabled,
    queryFn: ({ signal }) =>
      rdapi<T>(
        `${path}${path.includes("?") ? "&" : "?"}${histqry(hours)}`,
        signal,
      ),
    refetchInterval: 60000,
    staleTime: 60000,
    retry: 1,
    refetchIntervalInBackground: false,
  });
}
