import { Alert, Button, Input, Modal, Tabs, useState } from "./head";
import type { TableColumnsType } from "./head";
import { qry } from "./api";
import type { Audit, OpCap, Plan, Svccap, Svcop } from "./types";
import { dt, rstrbl, dbbkpref, txtbkp, txtbkpref, tapbkpref } from "./format.mjs";
import { Icn, Tbl as Table, Hnt, Lbl, Stt } from "./widgets";
import { Plnst, usepln } from "./plan";

// 仅翻译固定协议中的操作与状态。
const actions: Record<string, string> = { start: "启动", stop: "停止", restart: "重启", install: "安装", remove: "移除",
  upgrade: "升级", pin: "固定", unpin: "取消固定", setDefault: "设为默认", backup: "备份", restore: "恢复",
  trust: "信任", untrust: "取消信任", enable: "启用", disable: "停用", stealthOn: "启用隐身", stealthOff: "停用隐身",
  createDirectory: "新建目录", createFile: "新建文本", move: "移动", write: "保存文本", trash: "移至废纸篓", lock: "锁定", unlock: "解锁", addGroup: "加入用户组", removeGroup: "移出用户组" };
const states: Record<string, string> = { queued: "排队中", running: "执行中", pending: "待授权", authorized: "已授权",
  executing: "处理中", succeeded: "成功", failed: "失败", cancelled: "已取消", expired: "已过期", rolledBack: "已回滚" };

// 查看本机操作、待执行计划与持久审计记录。
export function Tsks() {
  const [tab, settab] = useState("operations");
  const [search, srch] = useState("");
  const [selected, slct] = useState<string>();
  const capability = qry<Svccap>("services/capabilities", 60000);
  const native = capability.data?.enabled === true;
  const operations = qry<Svcop[]>("services/operations", 5000, tab === "operations" && native);
  const plans = qry<Plan[]>("environments/plans?limit=100", 10000, tab === "plans");
  const filecap = qry<OpCap>("files/capabilities", 60000, tab === "plans");
  const packagecap = qry<OpCap>("environments/capabilities", 60000, tab === "plans");
  const databasecap = qry<OpCap>("databases/capabilities", 60000, tab === "plans");
  const control = usepln("environments/plans?limit=100");
  const record = plans.data?.find((plan) => plan.id === selected);
  const restorable = rstrbl(record);
  const recoverycap = record?.domain === "database" ? databasecap : record?.domain === "package" ? packagecap : filecap;
  const enabled = recoverycap.data?.enabled && recoverycap.data.actions.includes("restore") && !recoverycap.isError;
  const audit = qry<Audit[]>("audit?limit=100", 10000, tab === "audit");
  const active = tab === "plans" ? plans : tab === "audit" ? audit : operations;
  // 筛选目标与固定操作名。
  const mtch = (value: string) => value.toLowerCase().includes(search.toLowerCase());
  // 显示完整可访问提示和短时间文本。
  const tm = (value: string) => <Lbl value={dt(value).toLocaleString("zh-CN")} />;
  const pagination = { pageSize: 15, showSizeChanger: false };
  const empty = { emptyText: search ? "无匹配记录" : "暂无记录" };
  // 从同一成功任务冻结备份和对象，再次请求本机授权。
  async function rstr() {
    if (!record || !restorable || !enabled || control.busy) return;
    const parameters: Record<string, string> = { backupID: record.rollbackToken! };
    if (record.domain === "package" && record.parameters.kind === "cask") parameters.kind = "cask";
    if (record.domain === "file" && record.action !== "trash" && !txtbkp(record)) {
      parameters.rootID = record.parameters.destinationRootID;
      parameters.relativePath = record.parameters.destinationRelativePath;
    } else if (record.domain === "database" || record.action === "trash" || txtbkp(record)) {
      parameters.rootID = record.parameters.rootID;
      parameters.relativePath = record.parameters.relativePath;
    }
    const target = record.domain === "file" ? `${parameters.rootID}:${parameters.relativePath}` : record.target;
    if (await control.sbmt(record.domain, target, "restore", parameters)) slct(undefined);
  }
  const columns: TableColumnsType<Svcop | Plan> = [
    { title: "时间", dataIndex: "createdAt", width: 180, render: tm },
    { title: "目标", dataIndex: "target", width: 250, render: (value?: string) => <span className="mono"><Lbl value={value || "—"} /></span> },
    { title: "操作", dataIndex: "action", width: 120, render: (value: string) => actions[value] || "未知" },
    { title: "进度", dataIndex: "state", width: 100, render: (value: string, row) => <span title={row.message}>{value === "rolledBack" && "domain" in row && row.domain === "database" ? "快照已用" : states[value] || "未知"}</span> },
    { title: "标识", dataIndex: "id", render: (value: string, row) => tab === "plans" && "domain" in row && (rstrbl(row) || dbbkpref(row) || txtbkpref(row) || tapbkpref(row))
      ? <button className="table-link mono" aria-label={value} disabled={control.busy}
          onClick={() => { control.rst(); slct(value); }}><Lbl value={value} /></button>
      : <span className="mono"><Lbl value={value} /></span> },
    { title: "退出码", dataIndex: "exitCode", width: 80, render: (value?: number) => value ?? "—" },
  ];
  return <>
    <Tabs activeKey={tab} onChange={(value) => { settab(value); srch(""); }} items={[
      { key: "operations", label: "服务操作" }, { key: "plans", label: "变更任务" }, { key: "audit", label: "审计日志" },
    ]} />
    <div className="table-tools">
      <Input aria-label="搜索条目" placeholder="搜索条目" value={search} allowClear={{ clearIcon: <Icn name="close" /> }} onChange={(event) => srch(event.target.value)} />
      <Button loading={active.isFetching} disabled={tab === "operations" && !native} onClick={() => active.refetch()}>刷新</Button>
      <Hnt>服务操作只保留本次进程的最近100项，审计与计划持久保存。等待授权和请求记录不表示执行成功。可恢复的成功记录通过标识打开确认。</Hnt>
    </div>
    <Plnst control={control} />
    {tab === "operations" && !native ? <Stt query={capability}><Alert showIcon type="warning" title="原生执行未启用" /></Stt>
      : <Stt query={active}>
        {tab === "audit" ? <Table<Audit> size="small" rowKey="id" scroll={{ x: 850 }} pagination={pagination} locale={empty}
          columns={[
            { title: "发生时间", dataIndex: "recordedAt", width: 180, render: tm },
            { title: "事件", dataIndex: "operation", width: 210, render: (value: string) => <span className="mono"><Lbl value={value} /></span> },
            { title: "对象", dataIndex: "target", width: 230, render: (value?: string) => <span className="mono"><Lbl value={value || "—"} /></span> },
            { title: "结果", dataIndex: "succeeded", width: 85, render: (value: boolean, row) => <span title={row.message}>{value ? "成功" : "未成功"}</span> },
            { title: "来源", dataIndex: "sourceAddress", render: (value?: string) => <span className="mono"><Lbl value={value || "—"} /></span> },
          ]} dataSource={audit.data?.filter((row) => mtch(`${row.target || ""} ${row.operation}`)) ?? []} />
          : <Table<Svcop | Plan> size="small" rowKey="id" columns={columns} scroll={{ x: 850 }} pagination={pagination} locale={empty}
            dataSource={(tab === "plans" ? plans.data : operations.data)?.filter((row) => mtch(`${row.target || ""} ${actions[row.action] || row.action}`)) ?? []} />}
      </Stt>}
    <Modal title={restorable ? "变更处理" : "备份附件"} open={!!record} footer={restorable ? undefined : null}
      onOk={rstr} onCancel={() => { if (!control.posting) slct(undefined); }}
      okText="恢复" cancelText="取消" confirmLoading={control.posting}
      okButtonProps={{ disabled: !restorable || !enabled || control.busy, title: recoverycap.data?.reason || "无法确认恢复能力" }}>
      {tapbkpref(record) ? <>
        <span className="mono"><Lbl value={record!.target} /></span>
        <Button href={`/api/v1/environments/backups/${encodeURIComponent(record!.rollbackToken!)}/download`}>下载仓库</Button>
        <Hnt>附件包含移除前仓库及Git记录，仅供下载和人工检查，不执行解压或自动恢复，不含已安装软件。下载不请求系统授权。</Hnt>
      </> : txtbkp(record) ? <>
        <span className="mono"><Lbl value={record?.target ?? ""} /></span>
        {txtbkpref(record) && <Button href={`/api/v1/files/backups/${encodeURIComponent(record!.rollbackToken!)}/download`}>下载原文</Button>}
        <Hnt>{restorable ? "恢复此前完整文本，需停止其他写入并核验本机授权。文件身份、权限或当前内容改变会拒绝操作；恢复前备份现状，支持撤销。"
          : "此任务只提供原文下载，用于检查此前内容。下载不请求系统授权，当前记录不能再次恢复。"}</Hnt>
      </> : record?.domain === "file" && record.action === "trash" ? <>
        <span className="mono"><Lbl value={record.target} /></span>
        <Hnt>从系统废纸篓恢复原位置，需本机授权。回执、文件身份或父目录变化、已清空、原位置已有条目均拒绝恢复；不覆盖文件，不还原其他文件。</Hnt>
      </> : record?.domain === "file" ? <>
        <span className="mono"><Lbl value={`${record.parameters.destinationRootID}:${record.parameters.destinationRelativePath}`} /></span>
        <Hnt>{`恢复到${record.target}。需核验本机授权；文件身份、内容状态或父目录变化会拒绝操作，原位置已有条目也不会覆盖。状态备份不含文件内容。`}</Hnt>
      </> : record?.domain === "database" ? <>
        <span className="mono"><Lbl value={record.target} /></span>
        {dbbkpref(record) && <Button href={`/api/v1/databases/backups/${encodeURIComponent(record.rollbackToken!)}/download`}>下载快照</Button>}
        <Hnt>{restorable ? "恢复会替换此库当前内容，需先停止使用此库的应用并重新本机授权。恢复前保存当前快照，文件或内容变化会拒绝操作；已用于恢复的记录只保留下载。"
          : "此快照已用于恢复，仅供下载。下载不请求系统授权，当前记录不能再次恢复。"}</Hnt>
      </> : <>
        <span>{record?.action === "pin" ? "解除固定" : "重新固定"}</span>
        <Hnt>{`恢复${record?.target ?? "软件"}此前的固定状态，需要重新本机授权。安装版本及当前固定状态必须未变；恢复原固定链接只支持单一安装版本，不改软件内容。`}</Hnt>
      </>}
      {control.error && <Alert type="error" title="提交未确认" description={<Hnt>{control.error}</Hnt>} />}
    </Modal>
  </>;
}
