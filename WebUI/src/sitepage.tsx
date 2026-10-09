import {
  Alert,
  Button,
  Drawer,
  Empty,
  Input,
  Select,
  Tabs,
  useState,
  useEffect,
} from "./head";
import type { ReactNode, TableColumnsType } from "./head";
import { noteput, qry } from "./api";
import type { Conn, Proc, ProcDtl, Site, SiteDef, SiteNotes, Sites, SiteInfra, Srv, Srvs } from "./types";
import { fmtbyt, dt } from "./format.mjs";
import { defrt, endpt, mgmtlnk, notefnd, prctree, sitflt, sitkind, srvstt } from "./sitefmt.mjs";
import { Tbl as Table, Hnt, Icn, Lbl, Stt } from "./widgets";
import { Svcacts } from "./serviceacts";

// 打开现有第三方管理页，不声明API接管。
function Mgmt({ url }: { url?: string }) {
  const link = mgmtlnk(url);
  return link ? (
    <a href={link} target="_blank" rel="noopener noreferrer" aria-label="管理入口">
      <Icn name="external_link" />
    </a>
  ) : (
    <span title="未发现管理入口">—</span>
  );
}

// 网站设置以原生字段分组展示。
function Siterows({ rows, compact = false }: { rows: [string, ReactNode][]; compact?: boolean }) {
  return (
    <dl className={`system-info${compact ? " site-load-info" : ""}`}>
      {rows.filter(([, value]) => value !== undefined && value !== null && value !== "").map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{typeof value === "string" ? <Lbl value={value} /> : value ?? "—"}</dd>
        </div>
      ))}
    </dl>
  );
}

// 编辑面板备注并保留保存失败时的输入。
function Notefld({ definition, inventory, refresh }: {
  definition: SiteDef; inventory: SiteNotes; refresh: () => Promise<unknown>;
}) {
  const persisted = notefnd(inventory.notes, definition)?.note ?? "";
  const [value, setValue] = useState(persisted);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("");
  const allowed = inventory.enabled && (!inventory.target || inventory.target === definition.label);
  // 后台刷新只更新未编辑的内容。
  useEffect(() => { if (!dirty) setValue(persisted); }, [persisted, dirty]);
  // 保存成功后刷新共享备注。
  async function save() {
    if (new TextEncoder().encode(value).length > 4096) {
      setStatus("备注超过4096字节");
      return;
    }
    setBusy(true);
    setStatus("");
    try {
      await noteput({ label: definition.label, source: definition.source,
        definitionPath: definition.definitionPath, note: value });
      setStatus("已保存");
      await refresh();
      setDirty(false);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "保存失败");
    } finally { setBusy(false); }
  }
  return (
    <div className="note-editor">
      <Input.TextArea aria-label="项目备注" value={value} maxLength={4096}
        disabled={!allowed || busy} autoSize={{ minRows: 2, maxRows: 6 }}
        onChange={(event) => { setValue(event.target.value); setDirty(true); setStatus(""); }} />
      <span title={allowed ? "保存到面板数据目录，最多4096字节" : "当前未开放此项目的备注编辑"}>
        <Button onClick={save} loading={busy} disabled={!allowed || !dirty}>保存</Button>
      </span>
      {status && <span role="status">{status}</span>}
    </div>
  );
}

// 展示启动管理器的真实状态与退出信息。
function Srvdtl({ service }: { service?: Srv }) {
  return service ? (
    <Siterows
      rows={[
        ["运行用户", service.user],
        ["运行次数", service.runs],
        ["最近退出码", service.lastExitCode],
        ["配置状态", service.isDisabled ? "已禁用" : "未禁用"],
        ["开机启动", service.runAtLoad ? "是" : "否"],
      ]}
    />
  ) : (
    <Hnt>未找到对应的启动管理记录，状态未知。</Hnt>
  );
}

// 按启动项真实PID展示宝塔项目负载基础信息。
function Svcload({ service, active }: { service?: Srv; active: boolean }) {
  const running = service?.state === "running";
  const [picked, setPicked] = useState<number>();
  const query = qry<{ sampledAt: string; processes: Proc[] }>(
    "system/processes",
    10000,
    running && active,
  );
  const processes = prctree(query.data?.processes ?? [], service?.pid) as Proc[];
  const pid = processes.some((row) => row.pid === picked) ? picked : service?.pid;
  const process = query.data?.processes.find((row) => row.pid === pid);
  const details = qry<ProcDtl>(`system/processes/${pid ?? 0}`, 10000, running && active && !!pid);
  const connections = qry<{ hasFullVisibility: boolean; connections: Conn[] }>(
    "system/connections", 10000, running && active,
  );
  if (!service) return <Hnt>项目状态未知，请刷新后重试。</Hnt>;
  if (!running) return <span title="开启项目后查看负载">项目未运行</span>;
  return (
    <Stt query={query}>
      {process ? (
        <>
          <Select aria-label="进程" value={pid} onChange={setPicked}
            options={processes.map((row) => ({ value: row.pid, label: String(row.pid) }))} />
          <Siterows
            compact
            rows={[
              ["名称", process.command.split("/").pop()],
              ["状态", process.state],
              ["用户", process.user],
              ["启动时间", details.data?.startedAt ? dt(details.data.startedAt).toLocaleString("zh-CN") : "—"],
              ["PPID", process.parentPID],
              ["线程", process.threadCount],
              ["套接字", details.data?.socketCount ?? "—"],
              ["CPU", `${process.cpuPercent.toFixed(1)}%`],
              ["内存", fmtbyt(process.residentBytes)],
              ["读取字节", fmtbyt(process.readBytes)],
              ["写入字节", fmtbyt(process.writtenBytes)],
              ["命令", process.command],
            ]}
          />
          <Hnt>
            采样时间：{query.data ? dt(query.data.sampledAt).toLocaleString("zh-CN") : "—"}。
            CPU为进程占用，读取和写入为累计字节。状态为macOS原生状态码，命令仅显示执行文件。
            详情由libproc读取，受进程权限限制。
          </Hnt>
        </>
      ) : (
        <Hnt>本次采样未找到该PID，进程可能已退出或当前权限不可读取。</Hnt>
      )}
      <h3>网络</h3>
      <Stt query={connections}>
        <Table
          rowKey={(row, index) => `${row.protocolName}:${row.localEndpoint}:${row.remoteEndpoint}:${row.state}:${index}`}
          dataSource={connections.data?.connections.filter((row) => row.pid === pid)}
          pagination={false}
          scroll={{ x: 620 }}
          locale={{ emptyText: "暂无数据" }}
          columns={[
            { title: "客户端地址", render: (_, row) => endpt(row.remoteEndpoint).address },
            { title: "客户端端口", render: (_, row) => endpt(row.remoteEndpoint).port },
            { title: "协议", dataIndex: "protocolName" },
            { title: "FD", render: (_, row) => row.descriptor ?? "—" },
            { title: "本地地址", render: (_, row) => endpt(row.localEndpoint).address },
            { title: "本地端口", render: (_, row) => endpt(row.localEndpoint).port },
            { title: "状态", dataIndex: "state" },
          ]}
        />
        {connections.data?.hasFullVisibility === false && <span title="当前仅显示权限可读取的连接">部分连接</span>}
      </Stt>
      <h3>打开的文件列表</h3>
      <Stt query={details}>
        {details.data?.isAvailable === false && <Alert type="warning" title="进程不可读取" />}
        {details.data?.isAvailable && !details.data.isComplete &&
          <span title="进程权限变化或句柄数量超限，当前列表可能不完整">部分数据</span>}
        <Table rowKey="descriptor" dataSource={details.data?.files} pagination={{ pageSize: 10 }}
          locale={{ emptyText: "暂无可读取文件" }} scroll={{ x: 500 }}
          columns={[
            { title: "FD", dataIndex: "descriptor", width: 60 },
            { title: "文件路径", dataIndex: "path", render: (value: string) => <Lbl value={value} /> },
          ]} />
      </Stt>
    </Stt>
  );
}

// 只读显示DNS与反向代理的安全配置。
function Infradtl({ kind }: { kind: string }) {
  const query = qry<SiteInfra>("sites/infrastructure", 60000);
  const ag = query.data?.adGuard;
  const proxy = query.data?.zoraxy;
  return (
    <Stt query={query}>
      {kind === "dns" ? (
        ag?.isAvailable ? (
          <>
            <Siterows
              rows={[
                ["配置地址", ag.bindHosts.join(", ")],
                ["配置端口", ag.dnsPort],
                ["上游DNS", ag.upstreams.join("\n")],
                ["引导DNS", ag.bootstrapServers.join("\n")],
                [
                  "TLS",
                  ag.isTLSEnabled === undefined
                    ? "—"
                    : ag.isTLSEnabled
                      ? "已开启"
                      : "未开启",
                ],
                [
                  "DHCP",
                  ag.isDHCPEnabled === undefined
                    ? "—"
                    : ag.isDHCPEnabled
                      ? "已开启"
                      : "未开启",
                ],
                ["DHCP网卡", ag.dhcpInterface],
              ]}
            />
            <h3>DNS重写</h3>
            <Table
              rowKey="domain"
              pagination={{ pageSize: 10 }}
              dataSource={ag.rewrites}
              columns={[
                { title: "域名", dataIndex: "domain" },
                { title: "目标", dataIndex: "answer" },
                {
                  title: "状态",
                  render: (_, row) => (row.isEnabled ? "已启用" : "已禁用"),
                },
              ]}
            />
          </>
        ) : (
          <Empty description="未读取到DNS配置" />
        )
      ) : proxy?.isAvailable ? (
        <>
          <Table
            rowKey="domain"
            pagination={{ pageSize: 10 }}
            dataSource={proxy.routes}
            columns={[
              { title: "域名", dataIndex: "domain" },
              {
                title: "目标URL",
                render: (_, row) =>
                  row.activeOrigins
                    .map(
                      (item) =>
                        `${item.requiresTLS ? "https" : "http"}://${item.address}`,
                    )
                    .join(", "),
              },
              {
                title: "状态",
                render: (_, row) => (row.isDisabled ? "已禁用" : "已启用"),
              },
            ]}
            expandable={{
              expandedRowRender: (row) => (
                <Siterows
                  rows={[
                    ["绑定域名", row.aliases.join(", ") || "—"],
                    ["运行端口", row.listeningPorts.join(", ") || "—"],
                    [
                      "非活动目标",
                      row.inactiveOrigins
                        .map((item) => item.address)
                        .join(", ") || "—",
                    ],
                  ]}
                />
              ),
            }}
          />
          <h3>SSL证书</h3>
          <Table
            rowKey="fileName"
            pagination={false}
            dataSource={proxy.certificates}
            columns={[
              { title: "证书", dataIndex: "fileName" },
              { title: "域名", dataIndex: "subject" },
              {
                title: "到期时间",
                render: (_, row) =>
                  row.expiresAt
                    ? dt(row.expiresAt).toLocaleString("zh-CN")
                    : "—",
              },
            ]}
          />
          <Hnt>
            路由状态表示配置是否启用，不代表上游健康。证书清单未提供逐项目绑定关系。
          </Hnt>
        </>
      ) : (
        <Empty description="未读取到反向代理配置" />
      )}
    </Stt>
  );
}

// 以宝塔其他项目列表承接本地监听服务。
export function Sitepg() {
  const query = qry<Sites>("sites", 30000);
  const [tab, setTab] = useState("all");
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(1);
  const [size, setSize] = useState(10);
  const [detail, setDetail] = useState<Site | SiteDef>();
  const [detailTab, setDetailTab] = useState("project");
  // 打开新项目时回到宝塔默认的项目信息页。
  function opndtl(value: Site | SiteDef) {
    setDetailTab("project");
    setDetail(value);
  }
  const [fields, setFields] = useState([
    "name",
    "state",
    "ports",
    "note",
    "actions",
  ]);
  const [editing, setEditing] = useState(false);
  const configured = tab === "configured";
  const runtime = qry<Srvs>("services", 30000, configured || !!detail);
  const notes = qry<SiteNotes>("sites/notes", 30000);
  const rows = sitflt(
    query.data?.services ?? [],
    search,
    tab,
  );
  const definitions =
    query.data?.configuredServices.filter((row) =>
      `${row.label} ${row.program} ${row.definitionPath} ${row.expectedPorts.join(" ")} ${notefnd(notes.data?.notes ?? [], row)?.note ?? ""}`
        .toLowerCase()
        .includes(search.trim().toLowerCase()),
    ) ?? [];
  // 两类项目列表共用宝塔的元数据列顺序。
  const metadata = [
    ["note", "备注"],
  ].map(([key, title]) => ({
    key,
    title,
    width: 100,
    render: (_: unknown, row: Site | SiteDef) => {
      if (!("label" in row)) return "—";
      const value = notefnd(notes.data?.notes ?? [], row)?.note;
      return value ? <Lbl value={value} /> : "—";
    },
  }));
  const columns: TableColumnsType<Site> = [
    {
      key: "name",
      title: "项目名称",
      dataIndex: "process",
      width: 180,
      sorter: (a, b) => a.process.localeCompare(b.process),
      render: (_, row) => (
        <button className="table-link" aria-label={row.process} onClick={() => opndtl(row)}>
          <Lbl value={row.process} />
          <small>PID {row.pid}</small>
        </button>
      ),
    },
    {
      key: "state",
      title: "状态",
      width: 90,
      render: () => <span className="status-text">运行中</span>,
    },
    {
      key: "ports",
      title: "运行端口",
      width: 210,
      render: (_, row) =>
        row.listeners
          .map((item) => `${item.protocolName.toUpperCase()} ${item.port}`)
          .join(", "),
    },
    {
      key: "actions",
      title: "操作",
      width: 110,
      fixed: "right",
      render: (_, row) => (
        <div className="row-actions">
          <Mgmt url={row.managementURL} />
        </div>
      ),
    },
  ];
  // 搜索与分类改变时回到第一页。
  function reset() {
    setPage(1);
  }
  const liveDetail =
    detail && "pid" in detail
      ? query.data?.services.find((row) => row.pid === detail.pid)
      : undefined;
  const defDetail =
    detail && "label" in detail
      ? query.data?.configuredServices.find(
          (row) =>
            row.label === detail.label &&
            row.source === detail.source &&
            row.definitionPath === detail.definitionPath,
        )
      : undefined;
  const defService = defrt(runtime.data?.services ?? [], defDetail) as
    Srv | undefined;
  const pidServices = liveDetail
    ? (runtime.data?.services.filter(
        (row) => row.manager === "launchd" && row.pid === liveDetail.pid,
      ) ?? [])
    : [];
  const actionDefinition =
    pidServices.length === 1
      ? query.data?.configuredServices.find((row) => defrt(pidServices, row))
      : undefined;
  return (
    <div className="sites-page">
      <Tabs
        activeKey={tab}
        onChange={(value) => {
          setTab(value);
          reset();
        }}
        items={[
          ["all", "全部项目"],
          ["web", "Web项目"],
          ["reverseProxy", "反向代理"],
          ["dns", "DNS服务"],
          ["other", "其他项目"],
          ["system", "系统服务"],
          ["configured", "启动项目"],
        ].map(([key, label]) => ({ key, label }))}
      />
      <section className="panel">
        <div className="site-tools">
          <div className="site-filters">
            <Input
              aria-label="搜索项目"
              placeholder="请输入项目名称或备注"
              allowClear={{ clearIcon: <Icn name="close" /> }}
              value={search}
              onChange={(event) => {
                setSearch(event.target.value);
                reset();
              }}
            />
            <Button
              aria-label="刷新"
              title="刷新"
              loading={query.isFetching || (configured && runtime.isFetching)}
              onClick={() => {
                query.refetch();
                notes.refetch();
                if (configured || detail) runtime.refetch();
              }}
            >
              ↻
            </Button>
            <Button
              aria-label="设置列表字段"
              title="设置列表字段"
              onClick={() => setEditing(true)}
            >
              ☷
            </Button>
          </div>
        </div>
        {!query.data?.hasFullVisibility && query.data && (
          <Alert
            className="state-alert"
            type="warning"
            title={<span title="仅显示当前权限可读取的监听服务">部分可见</span>}
          />
        )}
        <Stt query={query}>
          {configured ? (
            <Stt query={runtime}>
              <Table<SiteDef>
                rowKey={(row) => `${row.source}:${row.definitionPath}`}
                dataSource={definitions}
                scroll={{ x: 1180 }}
                pagination={{
                  current: page,
                  pageSize: size,
                  showSizeChanger: true,
                  showTotal: (total) => `共 ${total} 条`,
                  onChange: (p, s) => {
                    setPage(p);
                    setSize(s);
                  },
                }}
                columns={(
                  [
                    {
                      key: "name",
                      title: "项目名称",
                      dataIndex: "label",
                      width: 250,
                      render: (_, row) => (
                        <button
                          className="table-link"
                          aria-label={row.label}
                          onClick={() => opndtl(row)}
                        >
                          <Lbl value={row.label} />
                        </button>
                      ),
                    },
                    {
                      key: "state",
                      title: "状态",
                      width: 130,
                      render: (_, row) => {
                        const service = defrt(
                          runtime.data?.services ?? [],
                          row,
                        );
                        return (
                          <span
                            className={
                              service?.state === "running"
                                ? "status-text"
                                : undefined
                            }
                          >
                            {srvstt(service?.state)}
                          </span>
                        );
                      },
                    },
                    {
                      key: "ports",
                      title: "运行端口",
                      render: (_, row) => {
                        const service = defrt(
                          runtime.data?.services ?? [],
                          row,
                        );
                        return (
                          query.data?.services
                            .find(
                              (item) =>
                                service?.pid !== undefined &&
                                item.pid === service.pid,
                            )
                            ?.listeners.map(
                              (item) =>
                                `${item.protocolName.toUpperCase()} ${item.port}`,
                            )
                            .join(", ") || "—"
                        );
                      },
                    },
                    ...metadata,
                  ] satisfies TableColumnsType<SiteDef>
                ).filter((column) => fields.includes(String(column.key)))}
                locale={{ emptyText: "您的列表为空" }}
              />
              <Hnt>
                状态采样时间：
                {runtime.data
                  ? dt(runtime.data.sampledAt).toLocaleString("zh-CN")
                  : "—"}
                。运行状态来自启动管理器；运行端口仅按PID匹配，未监听不等于已停止。
              </Hnt>
            </Stt>
          ) : (
            <>
              <Table<Site>
                rowKey="pid"
                dataSource={rows}
                columns={columns.filter((col) =>
                  fields.includes(String(col.key)),
                )}
                scroll={{
                  x: Math.max(
                    500,
                    columns
                      .filter((col) => fields.includes(String(col.key)))
                      .reduce((sum, col) => sum + Number(col.width ?? 100), 0),
                  ),
                }}
                pagination={{
                  current: page,
                  pageSize: size,
                  showSizeChanger: true,
                  showQuickJumper: true,
                  showTotal: (total) => `共 ${total} 条`,
                  onChange: (p, s) => {
                    setPage(p);
                    setSize(s);
                  },
                }}
                locale={{
                  emptyText:
                    search
                      ? "未找到匹配项目"
                      : "您的列表为空",
                }}
              />
            </>
          )}
        </Stt>
        <Hnt>
          本地服务替代宝塔项目；
          {configured
            ? "状态来自启动管理器，不代表业务健康。"
            : "状态“运行中”表示检测到监听，不代表业务健康。"}
          采样时间：
          {query.data ? dt(query.data.sampledAt).toLocaleString("zh-CN") : "—"}
        </Hnt>
      </section>
      <Drawer
        title="设置列表字段"
        size={420}
        open={editing}
        onClose={() => setEditing(false)}
      >
        <div className="home-detail">
          <Select
            mode="multiple"
            aria-label="列表字段"
            value={fields}
            onChange={(value) =>
              setFields([...new Set(["name", ...value])])
            }
            options={[...columns.filter((col) => !configured || col.key !== "actions"), ...(configured ? metadata : [])].map((col) => ({
              value: String(col.key),
              label: col.title as string,
              disabled: col.key === "name",
            }))}
          />
          <Hnt>
            项目名称固定显示。字段选择仅用于当前页面。
          </Hnt>
          <Button onClick={() => setEditing(false)}>确定</Button>
        </div>
      </Drawer>
      <Drawer
        title={<Lbl value={
          detail
            ? "process" in detail
              ? detail.process
              : detail.label
            : "项目详情"
        } />}
        className="site-settings"
        size={720}
        open={!!detail}
        onClose={() => setDetail(undefined)}
      >
        <div className="home-detail">
          {detail && !liveDetail && !defDetail && (
            <Alert
              type="warning"
              title={<span title="请返回列表重新选择">项目已变化</span>}
            />
          )}
          {liveDetail && (
            <>
              <Siterows
                rows={[
                  ["类型", sitkind(liveDetail.kind)],
                ]}
              />
              {mgmtlnk(liveDetail.managementURL) && <Hnt>{liveDetail.managementURLSource === "knownProcess"
                ? "管理入口来自已识别的服务端口。" : "管理入口按常见端口推断，请确认目标。"}</Hnt>}
              <Stt query={runtime}>
                {pidServices.length ? (
                  pidServices.map((service) => (
                    <div key={`${service.source}:${service.id}`}>
                      <h4><Lbl value={service.id} /></h4>
                      <Srvdtl service={service} />
                    </div>
                  ))
                ) : (
                  <Hnt>
                    当前PID未匹配到启动管理记录；监听状态不代表业务健康。
                  </Hnt>
                )}
              </Stt>
              {actionDefinition && (
                <Svcacts key={`${actionDefinition.source}:${actionDefinition.definitionPath}`} service={pidServices[0]} />
              )}
              <Table
                rowKey={(row) =>
                  `${row.protocolName}:${row.address}:${row.port}`
                }
                pagination={false}
                dataSource={liveDetail.listeners}
                columns={[
                  { title: "协议", dataIndex: "protocolName" },
                  { title: "监听地址", dataIndex: "address" },
                  { title: "运行端口", dataIndex: "port" },
                ]}
              />
              {((liveDetail.kind === "dns" &&
                /adguardhome/i.test(liveDetail.process)) ||
                (liveDetail.kind === "reverseProxy" &&
                  /zoraxy/i.test(liveDetail.process))) && (
                <Infradtl kind={liveDetail.kind} />
              )}
            </>
          )}
          {defDetail && (
            <Tabs
              key={`${defDetail.source}:${defDetail.definitionPath}`}
              tabPosition="left"
              destroyOnHidden={false}
              activeKey={detailTab}
              onChange={setDetailTab}
              items={[
                {
                  key: "project",
                  label: "项目信息",
                  children: (
                    <>
                      {" "}
                      <Siterows
                        rows={[
                          ["项目执行文件", defDetail.program],
                          ["项目备注", <Stt query={notes}>{notes.data &&
                            <Notefld key={`${defDetail.source}:${defDetail.definitionPath}`}
                              definition={defDetail} inventory={notes.data} refresh={() => notes.refetch()} />
                          }</Stt>],
                        ]}
                      />
                      <Hnt>
                        项目配置只读，更改启动项配置尚未提供。
                      </Hnt>
                      <Siterows
                        rows={[
                          ["配置文件", defDetail.definitionPath],
                          [
                            "来源",
                            (
                              {
                                userAgent: "用户启动项",
                                systemAgent: "系统启动项",
                                systemDaemon: "系统守护进程",
                              } as Record<string, string>
                            )[defDetail.source] ?? defDetail.source,
                          ],
                        ]}
                      />
                    </>
                  ),
                },
                {
                  key: "load",
                  label: "负载状态",
                  children: <Svcload service={defService} active={detailTab === "load"} />,
                },
                {
                  key: "state",
                  label: "服务状态",
                  children: (
                    <Stt query={runtime}>
                      <Svcacts service={defService} />
                      <Srvdtl service={defService} />
                      <Hnt>
                        状态采样时间：
                        {runtime.data
                          ? dt(runtime.data.sampledAt).toLocaleString("zh-CN")
                          : "—"}
                      </Hnt>
                    </Stt>
                  ),
                },
              ]}
            />
          )}
          <Hnt>
            配置详情只读查看。更改
            DNS、反向代理配置请进入对应管理页；启停需要本机原生授权，新增和删除尚未接入。
          </Hnt>
        </div>
      </Drawer>
    </div>
  );
}
