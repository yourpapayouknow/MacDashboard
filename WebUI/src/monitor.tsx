import {
  Alert,
  Button,
  Input,
  Select,
  Tabs,
  useQueryClient,
  useState,
} from "./head";
import type { TableColumnsType } from "./head";
import { qry, hqry } from "./api";
import type { Conn, Live, Net, Point, Proc, Rate } from "./types";
import { fmtbyt, dt, netlbl } from "./format.mjs";
import { Icn, Tbl as Table, Hnt, Lbl, Chrt, Pnl, Stt } from "./widgets";

// 使用宝塔表格习惯查看进程排行。
function Prcs() {
  const processes = qry<{
    processes: Proc[];
    topCPU: Proc[];
    topMemory: Proc[];
  }>("system/processes", 10000);
  const [search, srch] = useState("");
  const columns: TableColumnsType<Proc> = [
    {
      title: "PID",
      dataIndex: "pid",
      width: 85,
      sorter: (a, b) => a.pid - b.pid,
    },
    {
      title: "进程",
      dataIndex: "command",
      render: (value) => (
        <span className="mono"><Lbl value={value} /></span>
      ),
    },
    { title: "用户", dataIndex: "user", width: 110, render: (value: string) => <Lbl value={value} /> },
    {
      title: "CPU",
      dataIndex: "cpuPercent",
      width: 90,
      align: "right",
      defaultSortOrder: "descend",
      sorter: (a, b) => a.cpuPercent - b.cpuPercent,
      render: (value) => `${value.toFixed(1)}%`,
    },
    {
      title: "内存",
      dataIndex: "residentBytes",
      width: 110,
      align: "right",
      sorter: (a, b) => a.residentBytes - b.residentBytes,
      render: (value) => fmtbyt(value),
    },
    { title: "线程", dataIndex: "threadCount", width: 80, align: "right" },
    { title: "运行时间", dataIndex: "elapsed", width: 100 },
  ];
  const rows =
    processes.data?.processes.filter((row) =>
      `${row.pid} ${row.command} ${row.user}`
        .toLowerCase()
        .includes(search.toLowerCase()),
    ) ?? [];
  return (
    <>
      <div className="table-tools">
        <Input
          placeholder="搜索进程或用户"
          aria-label="搜索进程"
          value={search}
          onChange={(event) => srch(event.target.value)}
          allowClear={{ clearIcon: <Icn name="close" /> }}
        />
        <span className="muted">{rows.length}个进程</span>
        <Hnt>仅显示真实读取到的进程。多核心CPU用量可能超过100%。列表每10秒更新。</Hnt>
      </div>
      <Stt query={processes}>
        <Table<Proc>
          rowKey="pid"
          size="small"
          columns={columns}
          dataSource={rows}
          scroll={{ x: 850 }}
          pagination={{ pageSize: 15, showSizeChanger: false }}
          locale={{
            emptyText: search ? "无匹配进程" : "暂无可见进程",
          }}
        />
      </Stt>
    </>
  );
}

// 按权限范围显示真实连接列表。
function Cnns() {
  const connections = qry<{ hasFullVisibility: boolean; connections: Conn[] }>(
    "system/connections",
    30000,
  );
  const [search, srch] = useState("");
  const rows =
    connections.data?.connections
      .filter((row) =>
        `${row.process} ${row.pid} ${row.localEndpoint} ${row.remoteEndpoint ?? ""}`
          .toLowerCase()
          .includes(search.toLowerCase()),
      )
      .map((row, index) => ({ ...row, key: index })) ?? [];
  return (
    <>
      <Stt query={connections}>
        {connections.data && !connections.data.hasFullVisibility && (
          <Alert
            className="state-alert"
            showIcon
            type="warning"
            title={<span title="当前权限不足，只显示可读取的连接">部分可见</span>}
          />
        )}
        <div className="table-tools">
          <Input
            placeholder="搜索进程或地址"
            aria-label="搜索连接"
            value={search}
            onChange={(event) => srch(event.target.value)}
            allowClear={{ clearIcon: <Icn name="close" /> }}
          />
          <span className="muted">{rows.length}条连接</span>
          <Hnt>清单每30秒更新。权限不足时仅显示当前可读连接。</Hnt>
        </div>
        <Table
          size="small"
          rowKey="key"
          dataSource={rows}
          scroll={{ x: 850 }}
          pagination={{ pageSize: 15, showSizeChanger: false }}
          columns={[
            { title: "进程", dataIndex: "process", width: 130, render: (value: string) => <Lbl value={value} /> },
            { title: "PID", dataIndex: "pid", width: 80 },
            { title: "协议", dataIndex: "protocolName", width: 80 },
            { title: "本地地址", dataIndex: "localEndpoint", render: (value: string) => <span className="mono"><Lbl value={value} /></span> },
            {
              title: "远端地址",
              dataIndex: "remoteEndpoint",
              render: (value) => <span className="mono"><Lbl value={value ?? "—"} /></span>,
            },
            {
              title: "状态",
              dataIndex: "state",
              width: 110,
              render: (value) => <Lbl value={value ?? "—"} />,
            },
          ]}
          locale={{
            emptyText: search ? "无匹配连接" : "暂无可见连接",
          }}
        />
      </Stt>
    </>
  );
}

// 按网卡查看流量以区分物理与隧道流量。
function Ntwrks({ live, hours }: { live?: Live; hours: number }) {
  const interfaces = live?.system.networks ?? [];
  const [selected, select] = useState("");
  const name = interfaces.some((row) => row.name === selected)
    ? selected
    : (interfaces.find((row) => row.kind === "physical")?.name ??
      interfaces[0]?.name);
  const history = hqry<{ samples: (Rate & { sampledAt: string })[] }>(
    `system/network/history?name=${encodeURIComponent(name ?? "")}`,
    hours,
  );
  return (
    <>
      <div className="table-tools">
        <Select
          aria-label="选择网卡"
          value={name}
          onChange={select}
          style={{ minWidth: 160 }}
          options={interfaces.map((row) => ({
            value: row.name,
            label: <Lbl value={`${row.name}·${netlbl(row.kind, row.role)}`} />,
          }))}
        />
      </div>
      <Stt query={history}>
        <Chrt
          rows={(history.data?.samples ?? []).map((row) => ({
            sampledAt: row.sampledAt,
            rx: row.receivedBytesPerSecond / 1024,
            tx: row.sentBytesPerSecond / 1024,
          }))}
          unit="KiB/s"
          series={[
            { key: "rx", label: "接收", color: "#C97832" },
            { key: "tx", label: "发送", color: "#5E9B68" },
          ]}
        />
      </Stt>
      <Table<Net>
        rowKey="name"
        size="small"
        dataSource={interfaces}
        pagination={false}
        scroll={{ x: 700 }}
        columns={[
          { title: "网卡", dataIndex: "name", render: (value: string) => <Lbl value={value} /> },
          {
            title: "类型与用途",
            render: (_, row) => <Lbl value={netlbl(row.kind, row.role)} />,
          },
          {
            title: "状态",
            render: (_, row) => (row.isUp ? "已启用" : "未启用"),
          },
          {
            title: "累计接收",
            dataIndex: "receivedBytes",
            render: (value) => fmtbyt(value),
          },
          {
            title: "累计发送",
            dataIndex: "sentBytes",
            render: (value) => fmtbyt(value),
          },
        ]}
      />
    </>
  );
}

// 展示监控趋势与同页查询表格。
export function Mntr() {
  const cache = useQueryClient();
  const [hours, range] = useState(24);
  const [tab, settab] = useState("resource");
  const live = qry<Live>("system/live");
  const history = hqry<{ samples: Point[] }>("system/history", hours);
  const rows = (history.data?.samples ?? []).map((row) => ({
    ...row,
    memoryGiB: row.memoryUsedBytes / 1024 ** 3,
    rx: row.networkReceivedBytesPerSecond / 1024,
    tx: row.networkSentBytesPerSecond / 1024,
    read: row.diskReadBytesPerSecond / 1024,
    write: row.diskWrittenBytesPerSecond / 1024,
  }));
  const resource = (
    <Stt query={history}>
      <div className="two-col">
        <Pnl title="CPU使用率">
          <Chrt
            rows={rows}
            unit="%"
            series={[{ key: "cpuPercent", label: "CPU", color: "#C97832" }]}
          />
        </Pnl>
        <Pnl title="内存使用量">
          <Chrt
            rows={rows}
            unit="GiB"
            series={[{ key: "memoryGiB", label: "内存", color: "#C97832" }]}
          />
        </Pnl>
        <Pnl title="系统负载">
          <Chrt
            rows={rows}
            unit="负载"
            series={[{ key: "loadOne", label: "1分钟负载", color: "#C97832" }]}
          />
        </Pnl>
        <Pnl title="网络流量（物理网卡）">
          <Chrt
            rows={rows}
            unit="KiB/s"
            series={[
              { key: "rx", label: "接收", color: "#C97832" },
              { key: "tx", label: "发送", color: "#5E9B68" },
            ]}
          />
        </Pnl>
        <Pnl title="磁盘I/O">
          <Chrt
            rows={rows}
            unit="KiB/s"
            series={[
              { key: "read", label: "读取", color: "#C97832" },
              { key: "write", label: "写入", color: "#5E9B68" },
            ]}
          />
        </Pnl>
        <Pnl title="采样信息">
          <div className="summary-row">
            <span>历史记录</span>
            <span>{rows.length}个采样点</span>
          </div>
          <div className="summary-row">
            <span>最近实时采样</span>
            <span>
              {live.data
                ? dt(live.data.sampledAt).toLocaleTimeString("zh-CN")
                : "尚未获取"}
            </span>
          </div>
          <div className="summary-row">
            <span>交换内存</span>
            <span>{fmtbyt(live.data?.system.memory.swapUsedBytes)}</span>
          </div>
          <Hnt>
            后台每分钟保留历史记录，实时读取也会产生采样。空白时段不补造数据。
          </Hnt>
        </Pnl>
      </div>
    </Stt>
  );
  return (
    <>
      <div className="page-heading">
        <div className="heading-actions">
          <Select
            aria-label="监控时间范围"
            value={hours}
            onChange={(value) => {
              range(value);
            }}
            options={[
              { value: 1, label: "最近1小时" },
              { value: 6, label: "最近6小时" },
              { value: 24, label: "最近24小时" },
              { value: 168, label: "最近7天" },
            ]}
          />
          <Button
            onClick={() => {
              void cache.invalidateQueries();
            }}
          >
            刷新
          </Button>
        </div>
      </div>
      <Tabs
        activeKey={tab}
        onChange={settab}
        destroyOnHidden
        items={[
          { key: "resource", label: "系统资源", children: resource },
          { key: "process", label: "进程管理", children: <Prcs /> },
          {
            key: "network",
            label: "网络流量",
            children: (
              <Stt query={live}>
                <Ntwrks live={live.data} hours={hours} />
              </Stt>
            ),
          },
          { key: "connections", label: "网络连接", children: <Cnns /> },
        ]}
      />
      <Hnt>
        指标每 5
        秒更新；历史每分钟更新。当前页面为只读，进程列表支持搜索和排序。
      </Hnt>
    </>
  );
}
