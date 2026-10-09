import { Alert, Button, Drawer, Input, useState } from "./head";
import { qry } from "./api";
import type { Admin, Srvs } from "./types";
import { Icn, Tbl as Table, Hnt, Lbl, Stt } from "./widgets";
import { crtref } from "./format.mjs";
import { schdsvc, srvstt } from "./sitefmt.mjs";
import { Svcacts } from "./serviceacts";

// 复用管理域快照和一致的只读列表。
export function Admn({ section }: { section: "certificates" | "schedules" | "security" }) {
  const query = qry<Admin>("environments/admin", 60000);
  const [search, srch] = useState("");
  const [opened, opn] = useState<Admin["schedules"][number]>();
  const runtime = qry<Srvs>("services", 30000, section === "schedules" && query.data?.schedules.some((row) => row.manager === "launchd") === true);
  // 按可见身份字段筛选，不读取秘密配置。
  const mtch = (value: string) => value.toLowerCase().includes(search.toLowerCase());
  const pagination = { pageSize: 15, showSizeChanger: false };
  const empty = { emptyText: search ? "无匹配条目" : "暂无可见条目" };
  // 统一有界身份与路径的显示。
  const lbl = (value?: string) => <span className="mono"><Lbl value={value || "—"} /></span>;
  // 展示全部原生触发条件，完整表达式仅在悬浮或聚焦时展开。
  const schdl = (value: string) => {
    const label = value.split("; ").map((trigger) => {
      const interval = /^every (\d+) seconds$/.exec(trigger);
      return interval ? `每${interval[1]}秒` : trigger.startsWith("calendar ") ? trigger.slice(9)
        : ({ "watch paths": "路径变更", "queue directories": "非空目录", mount: "卷宗挂载", "@reboot": "开机",
          "@yearly": "每年", "@annually": "每年", "@monthly": "每月", "@weekly": "每周", "@daily": "每天",
          "@midnight": "每天", "@hourly": "每小时" })[trigger] || trigger;
    }).join("；");
    return <Lbl value={label} />;
  };
  const snap = query.data;
  const service = runtime.isError ? undefined : schdsvc(runtime.data?.services ?? [], opened);
  return <>
    <div className="table-tools">
      {section !== "security" && <Input aria-label="搜索条目" placeholder="搜索条目" value={search}
        allowClear={{ clearIcon: <Icn name="close" /> }} onChange={(event) => srch(event.target.value)} />}
      <Button loading={query.isFetching || section === "schedules" && runtime.isFetching} onClick={() => {
        query.refetch();
        if (section === "schedules" && query.data?.schedules.some((row) => row.manager === "launchd")) runtime.refetch();
      }}>刷新</Button>
      <Hnt>{section === "schedules" ? "点击launchd名称管理原生运行状态；cron只读。表达式顺序：分、时、日、月、周。分号分隔独立触发条件；日与周任一匹配即可触发。任务参数不公开，cron名称按原配置行号标识。"
          : section === "certificates" ? "点击指纹下载系统钥匙串的公开DER证书，不含私钥。下载会重新核对SHA256；删除、信任和导入尚未开放。"
            : "应用防火墙状态可能受本机权限限制。配置使用macOS系统设置，当前页面只读。"}</Hnt>
    </div>
    <Stt query={query}>
      {section === "certificates" ? <Table<Admin["certificates"][number]> rowKey={(row) => `${row.sha256}:${row.keychain}`}
          size="small" scroll={{ x: 500 }} pagination={pagination} locale={empty} columns={[
            { title: "身份", dataIndex: "label", width: 250, render: lbl }, { title: "SHA256", dataIndex: "sha256", width: 250,
              render: (value: string) => crtref(value) ? <a className="table-link mono" href={crtref(value)} download
                title="下载公开证书"><Lbl value={value} /></a> : lbl(value) },
          ]} dataSource={snap?.certificates.filter((row) => mtch(`${row.label} ${row.sha256}`)) ?? []} />
          : section === "schedules" ? <Table<Admin["schedules"][number]> rowKey={(row) => `${row.manager}:${row.id}:${row.definitionPath || ""}`}
            size="small" scroll={{ x: 650 }} pagination={pagination} locale={empty} columns={[
              { title: "名称", dataIndex: "id", width: 220, render: (value: string, row) => row.manager === "launchd"
                ? <button className="table-link mono" aria-label={value} onClick={() => opn(row)}><Lbl value={value} /></button> : lbl(value) },
              { title: "触发条件", dataIndex: "schedule", width: 180, render: schdl },
              { title: "状态", render: (_, row) => row.manager === "launchd" ? srvstt(runtime.isError ? undefined : schdsvc(runtime.data?.services ?? [], row)?.state) : "—" },
            ]} dataSource={snap?.schedules.filter((row) => mtch(`${row.id} ${row.schedule}`)) ?? []} />
            : snap?.firewall.isAvailable ? <dl className="home-detail">
              <dt>应用过滤</dt><dd>{snap.firewall.isEnabled === undefined ? "未知" : snap.firewall.isEnabled ? "开启" : "关闭"}</dd>
              <dt>隐身模式</dt><dd>{snap.firewall.stealthMode === undefined ? "未知" : snap.firewall.stealthMode ? "启用" : "停用"}</dd>
            </dl> : <Alert type="warning" showIcon title="防火墙不可读" />}
    </Stt>
    <Drawer title={opened ? <Lbl value={opened.id} /> : "任务详情"} open={!!opened} size={480} onClose={() => opn(undefined)}>
      {opened && <>
        <dl className="home-detail">
          {!!opened.definitionPath && <><dt>配置位置</dt><dd className="mono"><Lbl value={opened.definitionPath} /></dd></>}
          {service?.runs !== undefined && <><dt>运行次数</dt><dd>{service.runs}</dd></>}
          {service?.lastExitCode !== undefined && <><dt>最近退出</dt><dd>{service.lastExitCode}</dd></>}
          {service?.runAtLoad && <><dt>加载即运行</dt><dd>启用</dd></>}
        </dl>
        {service?.isDisabled && <Alert type="warning" title="启动配置已禁用" />}
        <Stt query={runtime}>{service ? <Svcacts key={`${opened.source}:${opened.definitionPath}`} service={service} scheduled />
          : <Alert type="warning" title="启动状态未确认" description={<Hnt>未找到唯一且来源与配置位置一致的launchd服务，请刷新后在本机检查。</Hnt>} />}</Stt>
      </>}
    </Drawer>
  </>;
}
