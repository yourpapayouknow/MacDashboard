import { Alert, Button, Drawer, Input, Tabs, useState } from "./head";
import type { TableColumnsType } from "./head";
import { qry } from "./api";
import type { Ctnr, Ctnrsnap, OpCap } from "./types";
import { Icn, Tbl as Table, Hnt, Lbl, Stt } from "./widgets";
import { Plnst, usepln } from "./plan";

// 查看现有容器与本机连接上下文。
export function Ctnrs() {
  const query = qry<Ctnrsnap>("environments/containers", 30000);
  const [tab, settab] = useState("containers");
  const [search, srch] = useState("");
  const [opened, opn] = useState<Ctnr>();
  const [action, cfrm] = useState<string>();
  const control = usepln("environments/containers");
  const capability = qry<OpCap>("environments/containers/capabilities", 60000);
  const snap = query.data;
  const current = opened && snap?.containers.find((row) => row.id === opened.id);
  const actionable = !!current && ["running", "created", "exited"].includes(current.state);
  const enabled = capability.data?.enabled && !capability.isError && snap?.daemonAvailable && !!snap.endpoint && !!snap.daemonID;
  const label = action === "start" ? "确认启动" : action === "stop" ? "确认停止" : action === "remove" ? "确认移除" : "确认重启";
  // 只提交当前库存连接及完整身份，原生授权在本机完成。
  async function sbmt() {
    if (!current || !action || !enabled || !actionable || control.busy || !capability.data?.actions.includes(action)
      || action === "restart" && current.state !== "running" || action === "remove" && current.state === "running") return;
    if (await control.sbmt("container", current.id, action, { endpoint: snap!.endpoint!, daemonID: snap!.daemonID! })) cfrm(undefined);
  }
  const columns: TableColumnsType<Ctnr> = [
    { title: "名称", dataIndex: "name", width: 200, render: (value: string, row) => <button className="table-link mono"
      aria-label={value} disabled={control.busy} onClick={() => { opn(row); cfrm(undefined); control.rst(); }}><Lbl value={value} /></button> },
    { title: "镜像", dataIndex: "image", width: 240, render: (value: string) => <span className="mono"><Lbl value={value} /></span> },
    { title: "状态", dataIndex: "state", width: 90, render: (value: string, row) => <span title={row.status}>{
      ({ running: "运行中", exited: "已停止", paused: "已暂停", created: "已创建", restarting: "重启中", removing: "移除中", dead: "已终止" })[value] ?? "未知"}</span> },
    { title: "端口", dataIndex: "ports", render: (value: string) => <span className="mono"><Lbl value={value || "—"} /></span> },
  ];
  return <>
    <Tabs activeKey={tab} onChange={(value) => { settab(value); srch(""); }} items={[
      { key: "containers", label: "容器列表" }, { key: "contexts", label: "连接上下文" },
    ]} />
    <div className="table-tools">
      <Input aria-label="搜索条目" placeholder="搜索条目" value={search} allowClear={{ clearIcon: <Icn name="close" /> }} onChange={(event) => srch(event.target.value)} />
      <Button loading={query.isFetching} onClick={() => query.refetch()}>刷新</Button>
      <Hnt>Docker使用默认本机Unix上下文，忽略DOCKER连接环境变量。操作需本机授权，有效会话复用；容器创建及虚拟机配置使用原有工具。</Hnt>
    </div>
    <Stt query={query}>
      {tab === "containers" ? snap && !snap.daemonAvailable
        ? <Alert showIcon type="warning" title={snap.dockerAvailable ? "引擎无法连接" : "未安装Docker"} />
        : <Table<Ctnr> rowKey="id" columns={columns} size="small" scroll={{ x: 750 }}
          dataSource={snap?.containers.filter((row) => `${row.name} ${row.image} ${row.id}`.toLowerCase().includes(search.toLowerCase())) ?? []}
          pagination={{ pageSize: 15, showSizeChanger: false }} locale={{ emptyText: search ? "无匹配容器" : "暂无容器" }} />
        : <Table<Ctnrsnap["contexts"][number]> rowKey="name" size="small" scroll={{ x: 650 }}
          columns={[
            { title: "名称", dataIndex: "name", width: 200, render: (value: string) => <Lbl value={value} /> },
            { title: "连接地址", dataIndex: "endpoint", render: (value: string) => <span className="mono"><Lbl value={value} /></span> },
            { title: "当前", dataIndex: "isCurrent", width: 70, render: (value: boolean, row) => <span title={row.error || row.description}>{value ? "是" : "否"}</span> },
          ]} dataSource={snap?.contexts.filter((row) => row.name.toLowerCase().includes(search.toLowerCase())) ?? []}
          pagination={{ pageSize: 15, showSizeChanger: false }} locale={{ emptyText: search ? "无匹配条目" : "暂无上下文" }} />}
    </Stt>
    <Drawer title={opened ? <Lbl value={opened.name} /> : "容器详情"} open={!!opened} size={480}
      onClose={() => { if (!control.posting) { opn(undefined); cfrm(undefined); } }}>
      {current ? <>
        <dl className="home-detail">
          <dt>标识</dt><dd className="mono"><Lbl value={current.id} /></dd>
          {!!current.networks.length && <><dt>网络</dt><dd className="mono"><Lbl value={current.networks.join(",")} /></dd></>}
        </dl>
        {actionable && <div className="row-actions">
          {action ? <>
            <Button loading={control.posting} disabled={control.busy || !enabled || action === "restart" && current.state !== "running"
              || action === "remove" && current.state === "running"}
              onClick={sbmt}>{label}</Button>
            <Button disabled={control.posting} onClick={() => cfrm(undefined)}>取消</Button>
            <Hnt>{action === "remove" ? "仅移除已停止容器，不强制停止，不移除卷或镜像。容器可写层会永久删除；记录仅含原状态，不能恢复内容。取消授权不执行。"
              : "确认后请求本机授权。停止或重启可能中断连接；Docker等待10秒后会强制结束未退出的进程，取消授权不执行。"}</Hnt>
          </> : <>
          {[current.state === "running" ? "stop" : "start", ...(current.state === "running" ? ["restart"] : ["remove"])].map((value) =>
            <span key={value} title={capability.data?.reason || "无法确认容器执行能力"}>
              <Button disabled={!enabled || control.busy || !capability.data?.actions.includes(value)} onClick={() => cfrm(value)}>
                {value === "start" ? "启动" : value === "stop" ? "停止" : value === "remove" ? "移除" : "重启"}
              </Button>
            </span>)}
          <Hnt>{capability.data?.reason}。暂停、重启中及异常容器禁止操作。原生命周期状态先备份，容器内容和挂载数据不作备份。</Hnt>
          </>}
        </div>}
        {action && control.error && <Alert type="error" title="提交未确认" description={<Hnt>{control.error}</Hnt>} />}
      </> : opened && !control.plan && <Alert type="warning" title="容器已不在清单" />}
      <Plnst control={control} />
    </Drawer>
  </>;
}
