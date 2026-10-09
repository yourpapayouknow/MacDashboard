import { Hnt } from "./widgets";
import {
  Alert,
  Button,
  useEffect,
  useQueryClient,
  useState,
} from "./head";
import { qry, svcpost } from "./api";
import type { Srv, Svccap, Svcop } from "./types";

const labels: Record<string, string> = {
  start: "启动",
  stop: "停止",
  restart: "重启",
};

// 识别仍需等待本机授权或执行的任务。
function pending(task?: Svcop) {
  return !!task && ["queued", "running"].includes(task.state);
}

// 固定服务动作采用目标确认、原生授权和任务结果三步。
export function Svcacts({ service, scheduled = false }: { service?: Srv; scheduled?: boolean }) {
  const capability = qry<Svccap>("services/capabilities", 60000);
  const cache = useQueryClient();
  const [action, setAction] = useState<string>();
  const [posting, setPosting] = useState(false);
  const [error, setError] = useState("");
  const [task, setTask] = useState<Svcop>();
  const progress = qry<Svcop>(
    task ? `services/operations/${task.id}` : "services/operations/pending",
    1000,
    pending(task),
  );
  const busy = posting || pending(task);
  const allowed =
    service?.manager === "launchd" &&
    service.id !== "com.iwmei.macdashboard.monitor-helper.native" &&
    (!capability.data?.target || capability.data.target === service.id);
  const reason = !allowed
    ? capability.data?.target
      ? `当前仅允许测试项目 [${capability.data.target}]`
      : "未匹配到可管理的启动服务"
    : capability.isPending
      ? "正在检查本机授权能力"
      : capability.isError
        ? "无法确认本机授权能力"
        : capability.data?.reason;

  // 完成后刷新真实状态，不以按钮点击冒充成功。
  useEffect(() => {
    if (!progress.data) return;
    setTask(progress.data);
    if (!pending(progress.data)) {
      cache.invalidateQueries({ queryKey: ["services"] });
      cache.invalidateQueries({ queryKey: ["sites"] });
    }
  }, [progress.data, cache]);

  // 请求失败保留原位确认，禁止自动重试写操作。
  async function submit() {
    if (!service || !allowed || !action || !capability.data?.enabled || busy)
      return;
    setPosting(true);
    setError("");
    try {
      const result = await svcpost(service.id, action);
      setTask(result);
      setAction(undefined);
    } catch (value) {
      setError(
        value instanceof Error
          ? value.message
          : "请求结果未确认，请先检查服务状态，避免重复操作",
      );
    } finally {
      setPosting(false);
    }
  }

  return (
    <section>
      <div className="row-actions">
        {action ? <>
          <Button loading={posting} danger={action === "stop"} disabled={busy || !allowed || !capability.data?.enabled || capability.isError}
            onClick={submit}>确认{labels[action]}</Button>
          <Button disabled={posting} onClick={() => setAction(undefined)}>取消</Button>
        </> : Object.entries(labels)
          .filter(
            ([key]) => scheduled
              ? service?.state === "stopped" ? key !== "restart"
                : service?.state === "unloaded" ? key === "start"
                  : ["running", "scheduled"].includes(service?.state ?? "") && key !== "start"
              : key === "restart" || key ===
                (service?.state === "running" || service?.state === "scheduled" ? "stop" : "start"),
          )
          .map(([key, label]) => {
            const unavailable =
              !allowed ||
              !capability.data?.enabled ||
              capability.isError ||
              busy ||
              (key === "start" &&
                (service?.state === "running" || service?.isDisabled)) ||
              (key === "restart" && service?.isDisabled) ||
              (key === "stop" &&
                !["running", "stopped", "scheduled"].includes(
                  service?.state ?? "",
                ));
            return (
              <span key={key} title={key !== "stop" && service?.isDisabled ? "启动配置已禁用" : reason}>
                <Button
                  danger={key === "stop"}
                  disabled={unavailable}
                  onClick={() => {
                    setAction(key);
                    setError("");
                  }}
                >
                  {label}
                </Button>
              </span>
            );
          })}
      </div>
      <Hnt>{reason}。{scheduled ? "启动会加载任务并立即运行；停止会卸载任务，重新登录或重启可能再次加载；重启会结束当前执行并重新运行。不修改触发条件或持久禁用状态。"
        : `操作只针对启动服务，不删除项目文件。${action === "stop" ? "停止后项目将无法访问。" : action ? "操作会变更项目运行状态。" : ""}`}缺少有效授权会话时，在此Mac的系统窗口批准操作。</Hnt>
      {action && error && <Alert type="error" showIcon title="提交未确认" description={<Hnt>{error}</Hnt>} />}
      {task && (
        <Alert
          showIcon
          type={
            task.state === "succeeded"
              ? "success"
              : task.state === "failed"
                ? "error"
                : "info"
          }
          title={
            pending(task)
              ? "等待本机授权或执行"
              : task.state === "succeeded"
                ? `${labels[task.action]}成功`
                : "操作未完成"
          }
          description={
            <Hnt>
              {task.target} · {labels[task.action]}：
              {task.state === "succeeded"
                ? `${labels[task.action]}成功`
                : (task.message ?? "任务已提交")}
              {task.exitCode !== undefined && (
                <span> · 退出码 {task.exitCode}</span>
              )}
            </Hnt>
          }
        />
      )}
      {progress.isError && (
        <Alert
          type="warning"
          showIcon
          title={<span title="请检查实际服务状态后再操作">结果查询失败</span>}
          action={<Button onClick={() => progress.refetch()}>刷新</Button>}
        />
      )}
    </section>
  );
}
