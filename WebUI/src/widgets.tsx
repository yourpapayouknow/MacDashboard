import {
  Alert,
  Button,
  Empty,
  Skeleton,
  Line,
  LineChart,
  ResponsiveContainer,
  CartesianGrid,
  XAxis,
  YAxis,
  Tooltip,
  Tip,
  Table,
} from "./head";
import type { QueryState } from "./types";
import type { ReactNode, TableProps } from "./head";
import { dt } from "./format.mjs";

// 使用随应用分发的MingCute图标。
export function Icn({ name }: { name: string }) {
  return <svg className="ui-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <use href={`/mingcute.svg#${name}`} />
  </svg>;
}

// 统一表格分页与排序图标并保留已有配置。
export function Tbl<T extends object>(props: TableProps<T>) {
  return <Table<T> {...props}
    pagination={props.pagination === false ? false : {
      itemRender: (_page, type, original) => type === "prev" || type === "next"
        ? <button className="ant-pagination-item-link" type="button" tabIndex={-1} aria-label={type === "prev" ? "上一页" : "下一页"}>
          <Icn name={type === "prev" ? "left" : "right"} />
        </button>
        : type === "jump-prev" || type === "jump-next" ? <Icn name="more_2" /> : original,
      ...props.pagination,
    }}
    columns={props.columns?.map((column) => column.sorter && !column.sortIcon ? {
      ...column,
      sortIcon: ({ sortOrder }) => <Icn name={sortOrder === "ascend" ? "up" : sortOrder === "descend" ? "down" : "selector_vertical"} />,
    } : column)}
  />;
}

// 把说明放在悬浮与键盘焦点提示中。
export function Hnt({ children }: { children: ReactNode }) {
  return <Tip title={children} trigger={["hover", "focus"]}>
    <Button className="hint" aria-label="查看说明">
      <Icn name="information" />
    </Button>
  </Tip>;
}

// 完整显示功能数据并允许换行。
export function Lbl({ value }: { value: string }) {
  return <span className="full-label" title={value}>{value}</span>;
}

// 用统一图标承接表格设置动作。
export function Cfgbtn({ click }: { click: () => void }) {
  return <Button aria-label="设置" title="设置" onClick={click}>
    <Icn name="settings_3" />
  </Button>;
}

// 显示请求状态并保留过期数据。
export function Stt({
  query,
  children,
}: {
  query: QueryState;
  children: ReactNode;
}) {
  if (query.isPending) return <Skeleton active paragraph={{ rows: 4 }} />;
  if (query.isError && !query.data)
    return (
      <Alert
        type="error"
        title={<span title={query.error?.message}>读取失败</span>}
        action={<Button onClick={() => query.refetch()}>重试</Button>}
        showIcon
      />
    );
  return (
    <>
      {query.isError && (
        <Alert
          className="state-alert"
          type="warning"
          showIcon
          title={<span title="当前显示上次成功读取的数据">连接中断</span>}
          action={<Button onClick={() => query.refetch()}>重试</Button>}
        />
      )}
      {children}
    </>
  );
}

// 保留宝塔分区标题和右侧操作位置。
export function Pnl({
  title,
  extra,
  children,
}: {
  title: string;
  extra?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="panel">
      <div className="panel-heading">
        <h2>{title}</h2>
        {extra}
      </div>
      {children}
    </section>
  );
}

// 使用成熟图表组件展示真实采样。
export function Chrt({
  rows,
  series,
  unit,
}: {
  rows: { sampledAt: string; [key: string]: string | number }[];
  series: { key: string; label: string; color: string }[];
  unit: string;
}) {
  if (!rows.length)
    return (
      <div className="chart-empty">
        <Empty description="暂无采样" />
      </div>
    );
  return (
    <>
      <div
        className="chart"
        role="img"
        aria-label={`${series.map((item) => item.label).join("、")}历史趋势，${rows.length}个采样点`}
      >
        <ResponsiveContainer width="100%" height="100%">
          <LineChart
            data={rows}
            margin={{ top: 4, right: 4, left: 0, bottom: 0 }}
            accessibilityLayer
          >
            <CartesianGrid stroke="#292827" vertical={false} />
            <XAxis
              dataKey="sampledAt"
              tickFormatter={(value) =>
                dt(value).toLocaleTimeString("zh-CN", {
                  hour: "2-digit",
                  minute: "2-digit",
                })
              }
              minTickGap={50}
              stroke="#A7A29A"
              fontSize={13}
            />
            <YAxis
              stroke="#A7A29A"
              fontSize={13}
              width={56}
              tickFormatter={(value) => Number(value).toFixed(1)}
            />
            <Tooltip
              labelFormatter={(value) => dt(value).toLocaleString("zh-CN")}
              contentStyle={{
                background: "#141414",
                border: "1px solid #3A3835",
                borderRadius: 0,
                padding: 4,
              }}
              formatter={(value, name) => [
                `${Number(value).toFixed(2)} ${unit}`,
                name,
              ]}
            />
            {series.map((item) => (
              <Line
                key={item.key}
                dataKey={item.key}
                name={item.label}
                stroke={item.color}
                strokeWidth={1.5}
                dot={rows.length === 1}
                isAnimationActive={false}
                connectNulls={false}
              />
            ))}
          </LineChart>
        </ResponsiveContainer>
      </div>
    </>
  );
}
