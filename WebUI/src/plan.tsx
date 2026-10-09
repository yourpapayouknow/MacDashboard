import { Alert, Button, useEffect, useQueryClient, useState } from "./head";
import { plnpost, planexec, qry } from "./api";
import { plnprg } from "./format.mjs";
import type { Plan } from "./types";
import { Hnt } from "./widgets";

// 两个管理页面共用提交、轮询、迟到响应保护和终态刷新。
export function usepln(inventory: string) {
  const [plan, setplan] = useState<Plan>();
  const [posting, pst] = useState(false);
  const [error, err] = useState("");
  const cache = useQueryClient();
  const terminal = plan && ["succeeded", "failed", "expired", "rolledBack"].includes(plan.state);
  const busy = posting || !!plan && ["queued", "authorized", "executing"].includes(plan.state);
  const progress = qry<Plan>(`environments/plans/${plan?.id ?? "pending"}`, 1000, !!plan && !terminal);
  // 只用服务器确认的终态刷新原管理页和任务页。
  useEffect(() => {
    if (!progress.data) return;
    const next = progress.data;
    setplan((current) => current?.id === next.id ? plnprg(current, next) : current);
    if (["succeeded", "failed", "expired", "rolledBack"].includes(next.state)) {
      cache.invalidateQueries({ queryKey: [inventory] });
      if (next.domain === "package" && next.parameters.kind === "tap") {
        cache.invalidateQueries({ queryKey: [`environments/tap?id=${encodeURIComponent(next.target)}`] });
      }
      if (inventory !== "environments/plans?limit=100") cache.invalidateQueries({ queryKey: ["environments/plans?limit=100"] });
    }
  }, [progress.data, cache, inventory]);
  // 失败保留同一计划，重复确认不创建第二次操作。
  async function sbmt(domain: string, target: string, action: string, parameters: Record<string, string> = {}) {
    if (busy) return false;
    pst(true);
    err("");
    try {
      const created = plan?.state === "pending" && plan.domain === domain && plan.target === target && plan.action === action
        && Object.keys(plan.parameters).length === Object.keys(parameters).length
        && Object.entries(parameters).every(([key, value]) => plan.parameters[key] === value)
        ? plan : await plnpost(domain, target, action, parameters);
      setplan((current) => plnprg(current, created));
      const queued = await planexec(created);
      setplan((current) => plnprg(current, queued));
      return true;
    } catch (value) { err(value instanceof Error ? value.message : "请检查实际目标状态"); return false; }
    finally { pst(false); }
  }
  // 执行期间保留目标和进度，避免切换到另一对象。
  function rst() { if (!busy) { setplan(undefined); err(""); } }
  return { plan, posting, busy, error, progress, sbmt, rst };
}

// 复用同一种操作状态和结果查询失败视图。
export function Plnst({ control }: { control: ReturnType<typeof usepln> }) {
  const { plan, progress } = control;
  return <>
    {plan && <Alert showIcon type={plan.state === "succeeded" ? "success" : ["failed", "expired"].includes(plan.state) ? "error" : "info"}
      title={plan.state === "succeeded" ? "操作成功" : plan.state === "failed" ? "操作未完成" : plan.state === "expired" ? "计划已过期" : "等待授权或执行"}
      description={<Hnt>{plan.message}{plan.exitCode !== undefined ? `，退出码${plan.exitCode}` : ""}</Hnt>} />}
    {plan && progress.isError && <Alert type="warning" title="结果查询失败"
      action={<Button onClick={() => progress.refetch()}>重试</Button>} />}
  </>;
}
