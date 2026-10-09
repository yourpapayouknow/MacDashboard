import {
  Alert,
  Button,
  Drawer,
  Empty,
  Input,
  Progress,
  NavLink,
  useNavigate,
  Select,
  Tabs,
  useState,
  ReactNode,
} from "./head";
import { qry, hqry } from "./api";
import type { Live, Point, Rate, Proc, Sites, Pkg as Package, Env, Admin } from "./types";
import { fmtbt, netttl, uptm } from "./format.mjs";
import { Tbl as Table, Hnt, Icn, Lbl, Chrt, Pnl, Stt } from "./widgets";

// 区分容量数值与单位字号。
function Valfmt({ value }: { value?: number }) {
  const [number, unit] = fmtbt(value).split(" ");
  return (
    <>
      {number}
      {unit && (
        <>
          {" "}
          <small>{unit}</small>
        </>
      )}
    </>
  );
}

// 保留资源仪表的占用比例与点击详情，保留宝塔环形仪表。
function Mtrc({
  label,
  detail,
  percent,
  open,
}: {
  label: string;
  detail: ReactNode;
  percent?: number;
  open: () => void;
}) {
  const value =
    percent === undefined ? undefined : Math.max(0, Math.min(100, percent));
  return (
    <button className="home-gauge" onClick={open} aria-label={`${label}详情`}>
      <h3 title={label}>{label}</h3>
      <Progress
        className="gauge-ring"
        type="circle"
        percent={value ?? 0}
        size={88}
        strokeWidth={7}
        strokeColor="#C97832"
        railColor="#292827"
        status="normal"
        aria-label={label}
        format={() => (
          <span>
            <strong>{percent?.toFixed(0) ?? "—"}</strong>
            <small>%</small>
          </span>
        )}
      />
      <span className="gauge-detail">{detail}</span>
    </button>
  );
}

// 网卡选择同时切换即时数值、累计计数及历史曲线。
function Trffc({ live }: { live?: Live }) {
  const [name, select] = useState("all");
  const [tab, switchTab] = useState("network");
  const all = hqry<{ samples: Point[] }>("system/history", 1);
  const selected = hqry<{ samples: (Rate & { sampledAt: string })[] }>(
    `system/network/history?name=${encodeURIComponent(name)}`,
    1,
    name !== "all" && tab === "network",
  );
  const rates = live?.networkRates ?? [];
  const traffic =
    name === "all"
      ? netttl(rates)
      : {
          rx: rates.find((row) => row.name === name)?.receivedBytesPerSecond,
          tx: rates.find((row) => row.name === name)?.sentBytesPerSecond,
        };
  const interfaces = (live?.system.networks ?? []).filter((row) =>
    name === "all" ? row.kind === "physical" : row.name === name,
  );
  const totals = interfaces.length
    ? interfaces.reduce(
        (sum, row) => ({
          rx: sum.rx + row.receivedBytes,
          tx: sum.tx + row.sentBytes,
        }),
        { rx: 0, tx: 0 },
      )
    : undefined;
  const disks = live?.diskRates;
  const diskSum = disks?.reduce(
    (sum, row) => ({
      read: sum.read + row.readBytesPerSecond,
      write: sum.write + row.writtenBytesPerSecond,
      operations:
        sum.operations +
        row.readOperationsPerSecond +
        row.writeOperationsPerSecond,
    }),
    { read: 0, write: 0, operations: 0 },
  );
  const query = name !== "all" && tab === "network" ? selected : all;
  const rows =
    tab === "network" && name !== "all"
      ? (selected.data?.samples ?? []).map((row) => ({
          sampledAt: row.sampledAt,
          rx: row.receivedBytesPerSecond / 1024,
          tx: row.sentBytesPerSecond / 1024,
        }))
      : (all.data?.samples ?? []).map((row) => ({
          sampledAt: row.sampledAt,
          rx: row.networkReceivedBytesPerSecond / 1024,
          tx: row.networkSentBytesPerSecond / 1024,
          read: row.diskReadBytesPerSecond / 1024,
          write: row.diskWrittenBytesPerSecond / 1024,
        }));
  return (
    <section className="panel home-traffic" aria-label="流量与磁盘IO">
      <Tabs
        activeKey={tab}
        onChange={switchTab}
        tabBarExtraContent={
          tab === "network" && (
            <label className="interface-picker">
              网卡{" "}
              <Select
                aria-label="网卡"
                value={name}
                onChange={select}
                options={[
                  { value: "all", label: "所有" },
                  ...rates.map((row) => ({ value: row.name, label: row.name })),
                ]}
              />
            </label>
          )
        }
        items={[
          { key: "network", label: "流量" },
          { key: "disk", label: "磁盘IO" },
        ]}
      />
      <div className="traffic-values">
        {(tab === "network"
          ? [
              [
                "上行",
                live?.intervalSeconds ? fmtbt(traffic.tx, true) : "采样中",
              ],
              [
                "下行",
                live?.intervalSeconds ? fmtbt(traffic.rx, true) : "采样中",
              ],
              ["总发送", fmtbt(totals?.tx)],
              ["总接收", fmtbt(totals?.rx)],
            ]
          : [
              ["读取", fmtbt(diskSum?.read, true)],
              ["写入", fmtbt(diskSum?.write, true)],
              [
                "每秒读写",
                diskSum ? `${Math.round(diskSum.operations)}次` : "—",
              ],
              ["IO延迟", "—"],
            ]
        ).map(([label, value]) => (
          <div key={label}>
            <span>{label}</span>
            <strong>{value}</strong>
          </div>
        ))}
      </div>
      <Stt query={query}>
        <Chrt
          rows={rows}
          unit="KB/s"
          series={
            tab === "network"
              ? [
                  { key: "tx", label: "上行", color: "#C97832" },
                  { key: "rx", label: "下行", color: "#5E9B68" },
                ]
              : [
                  { key: "read", label: "读取", color: "#C97832" },
                  { key: "write", label: "写入", color: "#5E9B68" },
                ]
          }
        />
      </Stt>
    </section>
  );
}

// 读取浏览器本地首页偏好，不影响系统服务。
function rdlocal(key: string, fallback: string) {
  try {
    return localStorage.getItem(key) ?? fallback;
  } catch {
    return fallback;
  }
}

// 按宝塔详情字段顺序展示原生读数。
function Dtlrows({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl className="system-info">
      {rows.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{typeof value === "string" ? <Lbl value={value} /> : value ?? "—"}</dd>
        </div>
      ))}
    </dl>
  );
}

// 点击查看资源信息与进程排行。
function Rsrcdtl({ title, system }: { title: string; system: Live["system"] }) {
  const processes = qry<{
    processes: Proc[];
    topCPU: Proc[];
    topMemory: Proc[];
  }>("system/processes", 10000);
  const memory = title === "内存";
  const percent =
    title === "负载"
      ? (system.load.one / system.load.maximum) * 100
      : memory
        ? (system.memory.usedBytes / system.memory.totalBytes) * 100
        : system.cpu.totalPercent;
  const unsupported = <span title="macOS接口未提供">—</span>;
  return (
    <>
      <p>
        {title === "负载" ? "运行达到" : "占用"}
        {percent.toFixed(0)}%
      </p>
      <details open>
        <summary>{memory ? "内存信息" : "基础信息"}</summary>
        {title === "负载" ? (
          <>
            <Dtlrows
              rows={[
                [
                  "1/5/15分钟负载",
                  `${system.load.one.toFixed(2)} / ${system.load.five.toFixed(2)} / ${system.load.fifteen.toFixed(2)}`,
                ],
              ]}
            />
            <Stt query={processes}>
              <Dtlrows
                rows={[
                  [
                    "活动/全部进程",
                    processes.data
                      ? `${processes.data.processes.filter((row) => row.state.startsWith("R")).length} / ${processes.data.processes.length}`
                      : undefined,
                  ],
                ]}
              />
            </Stt>
            <Hnt>
              活动进程按运行状态统计；安全阈值 {system.load.safeLimit}，最大值{" "}
              {system.load.maximum}。
            </Hnt>
          </>
        ) : memory ? (
          <>
            <Dtlrows
              rows={[
                ["空闲内存：", unsupported],
                ["已用：", fmtbt(system.memory.usedBytes)],
                ["总内存：", fmtbt(system.memory.totalBytes)],
                ["共享：", unsupported],
                ["可分配内存：", fmtbt(system.memory.availableBytes)],
                ["缓冲与缓存", unsupported],
              ]}
            />
            <Hnt>
              macOS 可分配内存包含可回收页，不能等同于 Linux
              空闲内存、共享内存或 buff/cache。
            </Hnt>
          </>
        ) : (
          <>
            <p>
              {system.cpu.physicalCores}个物理核心，{system.cpu.logicalCores}
              个逻辑核心
            </p>
            <Hnt>
              架构：{system.summary.architecture}。当前接口未提供 CPU型号和物理
              CPU 数量。
            </Hnt>
          </>
        )}
      </details>
      {title === "负载" && (
        <details open>
          <summary>更多负载信息</summary>
          <Dtlrows
            rows={[
              ["用户态", `${system.cpu.userPercent.toFixed(1)}%`],
              ["优先调度", unsupported],
              ["内核态", `${system.cpu.systemPercent.toFixed(1)}%`],
              ["空闲", `${system.cpu.idlePercent.toFixed(1)}%`],
              ...[
                "磁盘等待",
                "硬件中断",
                "软件中断",
                "虚拟机争用",
                "虚拟机运行",
                "虚拟机调度",
              ].map((label) => [label, unsupported] as [string, ReactNode]),
            ]}
          />
          <Hnt>
            user：用户级别的 CPU 时间百分比；system：系统级别的 CPU
            时间百分比；idle：空闲状态的 CPU 时间百分比。
          </Hnt>
        </details>
      )}
      {title === "CPU" && (
        <details open>
          <summary>核心使用率</summary>
          <Dtlrows
            rows={system.cpu.perCorePercent.map((value, index) => [
              `核心 ${index + 1}`,
              `${value.toFixed(1)}%`,
            ])}
          />
        </details>
      )}
      {memory && (
        <details open>
          <summary>macOS内存信息</summary>
          <Dtlrows
            rows={[
              ["活跃内存", fmtbt(system.memory.activeBytes)],
              ["非活跃内存", fmtbt(system.memory.inactiveBytes)],
              ["固定内存", fmtbt(system.memory.wiredBytes)],
              ["压缩内存", fmtbt(system.memory.compressedBytes)],
              ["缓存内存", fmtbt(system.memory.cachedBytes)],
              [
                "交换内存",
                `${fmtbt(system.memory.swapUsedBytes)} / ${fmtbt(system.memory.swapTotalBytes)}`,
              ],
              [
                "内存压力",
                system.memory.pressureLevel === 1
                  ? "正常"
                  : system.memory.pressureLevel === 2
                    ? "警告"
                    : system.memory.pressureLevel === 4
                      ? "严重"
                      : `未知（${system.memory.pressureLevel}）`,
              ],
            ]}
          />
        </details>
      )}
      <details open>
        <summary>
          {memory ? "内存排行前5" : "CPU排行前5"}
        </summary>
        <Stt query={processes}>
          <Table<Proc>
            rowKey="pid"
            pagination={false}
            dataSource={(memory
              ? processes.data?.topMemory
              : processes.data?.topCPU
            )?.slice(0, 5)}
            columns={[
              {
                title: "进程名称",
                dataIndex: "command",
                render: (value) => <span title={value}>{value}</span>,
              },
              { title: "PID", dataIndex: "pid", width: 80 },
              {
                title: memory ? "内存使用率" : "CPU占用率",
                width: 100,
                render: (_, row) =>
                  memory
                    ? `${((row.residentBytes / system.memory.totalBytes) * 100).toFixed(1)}%`
                    : `${row.cpuPercent.toFixed(1)}%`,
              },
              ...(memory
                ? [
                    {
                      title: "内存",
                      render: (_: unknown, row: Proc) =>
                        fmtbt(row.residentBytes),
                    },
                  ]
                : []),
            ]}
          />
        </Stt>
        {!memory && <Hnt>单个进程 CPU 占用率可超过 100%。</Hnt>}
      </details>
    </>
  );
}

// 对照宝塔首页的仪表、概览、流量和软件分区。
export function Hm() {
  const navigate = useNavigate();
  const live = qry<Live>("system/live");
  const sites = qry<Sites>("sites", 60000);
  const admin = qry<Admin>("environments/admin", 60000);
  const env = qry<Env>("environments", 60000);
  const [detail, show] = useState("");
  const [memo, setMemo] = useState(() => rdlocal("macdashboard.home.memo", ""));
  const [draft, setDraft] = useState("");
  const [saveError, setError] = useState("");
  const [pins, setPins] = useState<string[] | null>(() => {
    const saved = rdlocal("macdashboard.home.software", "__default__");
    return saved === "__default__" ? null : saved.split("\n").filter(Boolean);
  });
  const [overview, setOverview] = useState(() =>
    rdlocal("macdashboard.home.overview", "网站\n数据库\n备忘录")
      .split("\n")
      .filter((value) => ["网站", "数据库", "备忘录"].includes(value)),
  );
  const [choices, setChoices] = useState<string[]>([]);
  const system = live.data?.system;
  const disk =
    system?.disks.find((row) => row.mountPath === "/System/Volumes/Data") ??
    system?.disks.find((row) => row.mountPath === "/");
  const memory =
    system && system.memory.totalBytes > 0
      ? (system.memory.usedBytes / system.memory.totalBytes) * 100
      : undefined;
  const load =
    system && system.load.maximum > 0
      ? (system.load.one / system.load.maximum) * 100
      : undefined;
  const packages = [...(env.data?.formulae ?? []), ...(env.data?.casks ?? [])];
  const defaults =
    env.data?.formulae
      .filter((row) => row.installedOnRequest)
      .slice(0, 8)
      .map((row) => row.id) ?? [];
  const displayed = (pins ?? defaults)
    .map((id) => packages.find((row) => row.id === id))
    .filter((row): row is Package => !!row);
  // 保存本机浏览器的备忘录与快捷软件选择。
  function svlocal(key: string, value: string) {
    try {
      localStorage.setItem(key, value);
      setError("");
      return true;
    } catch {
      setError("保存失败");
      return false;
    }
  }
  // 打开首页详情或偏好编辑。
  function opndtl(title: string) {
    setError("");
    setDraft(memo);
    setChoices(title === "概览自定义编辑" ? overview : (pins ?? defaults));
    show(title);
  }
  return (
    <div className="home-page">
      <div className="home-machine">
        <button className="machine-info" onClick={() => opndtl("系统信息")}>
          <span>macOS {system?.summary.osVersion ?? "—"}</span>
          <span className="muted">{system?.summary.architecture ?? "—"}</span>
        </button>
        <div className="heading-actions">
          <span className="muted">v0.1.0</span>
        </div>
      </div>
      <Stt query={live}>
        <section className="home-gauges" aria-label="资源状态">
          <Mtrc
            label="负载"
            percent={load}
            detail={
              load === undefined
                ? "—"
                : load < 70
                  ? "运行流畅"
                  : load < 80
                    ? "运行正常"
                    : load < 90
                      ? "运行缓慢"
                      : "运行堵塞"
            }
            open={() => opndtl("负载")}
          />
          <Mtrc
            label="CPU"
            percent={system?.cpu.totalPercent}
            detail={
              <>
                {system?.cpu.logicalCores ?? "—"}
                <small>核心</small>
              </>
            }
            open={() => opndtl("CPU")}
          />
          <Mtrc
            label="内存"
            percent={memory}
            detail={
              <>
                <Valfmt value={system?.memory.usedBytes} /> /{" "}
                <Valfmt value={system?.memory.totalBytes} />
              </>
            }
            open={() => opndtl("内存")}
          />
          <Mtrc
            label="/"
            percent={
              disk && disk.totalBytes > 0
                ? (disk.usedBytes / disk.totalBytes) * 100
                : undefined
            }
            detail={
              <>
                <Valfmt value={disk?.usedBytes} /> /{" "}
                <Valfmt value={disk?.totalBytes} />
              </>
            }
            open={() => opndtl("/")}
          />
        </section>
      </Stt>
      <Pnl
        title="概览"
        extra={
          <Button
            aria-label="概览自定义编辑"
            onClick={() => opndtl("概览自定义编辑")}
          >
            <Icn name="more_2" />
          </Button>
        }
      >
        <div className="home-overview">
          {overview.includes("网站") && (
            <Stt query={sites}>
              <button className="overview-link" onClick={() => navigate("/site")}>
                <span>监听数量</span>
                <strong>
                  {sites.data?.services.length ?? "—"}
                  <small><Icn name="external_link" /></small>
                </strong>
              </button>
            </Stt>
          )}
          {overview.includes("数据库") && (
            <Stt query={admin}>
              <button
                className="overview-link"
                onClick={() => navigate("/databases")}
              >
                <span>数据库实例</span>
                <strong>
                  {admin.data?.databases.length ?? "—"}
                  <small><Icn name="external_link" /></small>
                </strong>
              </button>
            </Stt>
          )}
          {overview.includes("备忘录") && (
            <button className="overview-memo" onClick={() => opndtl("备忘录")}>
              <span>备忘录</span>
              <p title={memo}>{memo || "未记录"}</p>
            </button>
          )}
        </div>
      </Pnl>
      <div className="home-bottom">
        <Trffc live={live.data} />
        <Pnl
          title="软件"
          extra={
            <Button
              aria-label="软件自定义编辑"
              onClick={() => opndtl("软件自定义编辑")}
            >
              <Icn name="more_2" />
            </Button>
          }
        >
          <Stt query={env}>
            <div className="home-software">
              {displayed.map((row) => (
                <button key={row.id} onClick={() => navigate(`/environments?pkg=${encodeURIComponent(row.id)}&kind=${row.versions ? "formulae" : "casks"}`)}>
                  <Lbl value={row.id} />
                  <Icn name="external_link" />
                </button>
              ))}
            </div>
            {!displayed.length && (
              <Empty description="暂无快捷软件" />
            )}
          </Stt>
        </Pnl>
      </div>
      <Drawer
        title={<Lbl value={detail} />}
        open={!!detail}
        onClose={() => show("")}
        size={560}
      >
        <div className="home-detail">
          {saveError && <Alert type="error" title={saveError} />}
          {detail === "备忘录" ? (
            <>
              <Input.TextArea
                aria-label="备忘录内容"
                value={draft}
                onChange={(event) => setDraft(event.target.value)}
                maxLength={10000}
                rows={10}
              />
              <Hnt>仅保存于此浏览器，不跨设备同步。</Hnt>
              <Button
                type="primary"
                onClick={() => {
                  if (svlocal("macdashboard.home.memo", draft)) {
                    setMemo(draft);
                    show("");
                  }
                }}
              >
                保存
              </Button>
            </>
          ) : ["软件自定义编辑", "概览自定义编辑"].includes(detail) ? (
            <>
              <Select
                mode="multiple"
                aria-label={
                  detail === "概览自定义编辑" ? "首页概览项目" : "首页快捷软件"
                }
                value={choices}
                onChange={setChoices}
                options={
                  detail === "概览自定义编辑"
                    ? ["网站", "数据库", "备忘录"].map((label) => ({
                        value: label,
                        label,
                      }))
                    : packages.map((row) => ({
                        value: row.id,
                        label: row.id,
                      }))
                }
              />
              <Hnt>首页显示偏好仅保存于此浏览器。</Hnt>
              <Button
                type="primary"
                onClick={() => {
                  if (
                    svlocal(
                      detail === "概览自定义编辑"
                        ? "macdashboard.home.overview"
                        : "macdashboard.home.software",
                      choices.join("\n"),
                    )
                  ) {
                    if (detail === "概览自定义编辑") setOverview(choices);
                    else setPins(choices);
                    show("");
                  }
                }}
              >
                保存
              </Button>
            </>
          ) : (
            <Stt query={live}>
              {detail === "系统信息" && (
                <dl className="system-info">
                  <div>
                    <dt>主机</dt>
                    <dd>{system?.summary.hostname}</dd>
                  </div>
                  <div>
                    <dt>系统</dt>
                    <dd>macOS {system?.summary.osVersion}</dd>
                  </div>
                  <div>
                    <dt>运行时间</dt>
                    <dd>{system ? uptm(system.summary.uptimeSeconds) : "—"}</dd>
                  </div>
                </dl>
              )}
              {["负载", "CPU", "内存"].includes(detail) && system && (
                <Rsrcdtl title={detail} system={system} />
              )}
              {detail === "/" && (
                <>
                  <p>
                    容量占用
                    {disk && disk.totalBytes > 0
                      ? ((disk.usedBytes / disk.totalBytes) * 100).toFixed(2)
                      : "—"}
                    %
                  </p>
                  <h3>基础信息</h3>
                  {disk && (
                    <Dtlrows
                      rows={[
                        ["挂载点：", disk.mountPath],
                        ["共：", fmtbt(disk.totalBytes)],
                        ["可用：", fmtbt(disk.availableBytes)],
                        ["已用：", fmtbt(disk.usedBytes)],
                        ["文件系统：", disk.fileSystem],
                        ["设备：", disk.device],
                      ]}
                    />
                  )}
                  <Hnt>
                    APFS
                    系统卷和数据卷共用空间，不重复相加；下方保留各挂载点原始读数。
                  </Hnt>
                  <details open>
                    <summary>Inode信息</summary>
                    {disk && (
                      <Dtlrows
                        rows={[
                          ["总数：", disk.totalFiles],
                          ["已用：", disk.usedFiles],
                          ["可用：", disk.availableFiles],
                          [
                            "使用率：",
                            disk.totalFiles > 0
                              ? `${((disk.usedFiles / disk.totalFiles) * 100).toFixed(2)} %`
                              : "—",
                          ],
                        ]}
                      />
                    )}
                    <Hnt>
                      macOS 原生文件节点计数；APFS 各卷的统计不作相加。
                    </Hnt>
                  </details>
                  <details>
                    <summary>挂载明细</summary>
                    {system?.disks.map((row) => (
                      <section key={row.mountPath}>
                        <h4 className="mono">{row.mountPath}</h4>
                        <Dtlrows
                          rows={[
                            ["设备：", row.device],
                            ["文件系统：", row.fileSystem],
                            ["共：", fmtbt(row.totalBytes)],
                            ["可用：", fmtbt(row.availableBytes)],
                            ["已用：", fmtbt(row.usedBytes)],
                            ["总数：", row.totalFiles],
                            ["已用节点：", row.usedFiles],
                            ["可用节点：", row.availableFiles],
                          ]}
                        />
                      </section>
                    ))}
                  </details>
                </>
              )}
              <NavLink to="/monitor" onClick={() => show("")}>
                查看监控 →
              </NavLink>
            </Stt>
          )}
        </div>
      </Drawer>
    </div>
  );
}
