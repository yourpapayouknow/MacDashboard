import {
  Alert,
  Button,
  ConfigProvider,
  createRoot,
  Drawer,
  HashRouter,
  NavLink,
  Navigate,
  QueryClient,
  QueryClientProvider,
  Route,
  Routes,
  theme,
  useEffect,
  useLocation,
  useQueryClient,
  useState,
  zhCN,
} from "./head";
import { qry } from "./api";
import type { Live, Svccap } from "./types";
import { dt } from "./format.mjs";
import { Hm } from "./home";
import { Mntr } from "./monitor";
import { Sitepg } from "./sitepage";
import { Fls } from "./files";
import { Envs } from "./environments";
import { Ctnrs } from "./containers";
import { Admn } from "./admin";
import { Dtbs } from "./databases";
import { Tsks } from "./tasks";
import { Icn, Lbl } from "./widgets";
import "./style.css";

// 复用全局请求缓存。
const client = new QueryClient();
const menu = [
  { path: "/", label: "首页", symbol: "home_2" },
  { path: "/site", label: "网站", symbol: "external_link" },
  { path: "/databases", label: "数据库", symbol: "storage" },
  { path: "/containers", label: "容器", symbol: "box_3" },
  { path: "/monitor", label: "监控", symbol: "chart_line" },
  { path: "/environments", label: "环境", symbol: "terminal" },
  { path: "/files", label: "文件", symbol: "folder_2" },
  { path: "/certificates", label: "证书", symbol: "certificate" },
  { path: "/schedules", label: "计划任务", symbol: "calendar" },
  { path: "/tasks", label: "任务", symbol: "task_2" },
  { path: "/security", label: "防火墙", symbol: "shield" },
];

// 保留宝塔固定模块入口。
function Mn({
  close,
  native = false,
  hostname,
  status,
  sampled,
  warning,
}: {
  close?: () => void;
  native?: boolean;
  hostname: string;
  status: string;
  sampled: string;
  warning: boolean;
}) {
  return (
    <>
      <div className="machine-panel">
        <span className="machine"><Lbl value={hostname} /></span>
        <div className="connection" role="status">
          <span className={`status-dot ${warning ? "warning" : ""}`} />
          {status}<time className="last-sample">{sampled}</time>
        </div>
      </div>
      <nav aria-label="模块导航">
        {menu.map((item) => (
          <NavLink
            key={item.path}
            to={item.path}
            end
            onClick={close}
            title={item.label}
          >
            <span className="nav-icon" aria-hidden>
              <Icn name={item.symbol} />
            </span>
            <span className="nav-label">{item.label}</span>
          </NavLink>
        ))}
      </nav>
      <div className="sidebar-foot">
        <span className="status-dot" />
        {native ? "本机授权" : "只读监控"}
      </div>
    </>
  );
}

// 显示机器连接状态并适配平板导航。
function Shll() {
  const live = qry<Live>("system/live");
  const capability = qry<Svccap>("services/capabilities", 60000);
  const native = capability.data?.enabled === true && !capability.isError;
  const cache = useQueryClient();
  const location = useLocation();
  const [opened, open] = useState(false);
  const [clock, tick] = useState(Date.now());
  // 跟踪断连后数据过期状态。
  useEffect(() => {
    const timer = window.setInterval(() => tick(Date.now()), 5000);
    return () => window.clearInterval(timer);
  }, []);
  // 切换页面后关闭窄屏模块抽屉。
  useEffect(() => open(false), [location.pathname]);
  const stale = live.dataUpdatedAt > 0 && clock - live.dataUpdatedAt > 20000;
  const status = live.isPending
    ? "连接中"
    : live.isError
      ? "连接中断"
      : stale
        ? "数据已过期"
        : "已连接";
  const machine = {
    hostname: live.data?.system.summary.hostname ?? "—", status,
    sampled: live.data ? dt(live.data.sampledAt).toLocaleTimeString("zh-CN") : "—",
    warning: live.isError || stale,
  };
  return (
    <div className="app-shell">
      <a
        className="skip"
        href="#workspace"
        onClick={(event) => {
          event.preventDefault();
          document.getElementById("workspace")?.focus();
        }}
      >
        跳到主要内容
      </a>
      <aside className="sidebar">
        <Mn native={native} {...machine} />
      </aside>
      <Drawer
        title="模块导航"
        placement="left"
        open={opened}
        onClose={() => open(false)}
        size={224}
      >
        <Mn native={native} {...machine} close={() => open(false)} />
      </Drawer>
      <div className="workspace">
        <header className={`topbar${location.pathname === "/" ? "" : " compact"}`}>
          <Button
            className="mobile-menu"
            aria-label="打开模块导航"
            onClick={() => open(true)}
          >
            <Icn name="menu" />
          </Button>
          {location.pathname === "/" && <div className="brand">
            <img className="brand-mark" src="/app-icon.png" alt="" />
            <div className="brand-copy">
              <strong>MacDashboard</strong>
              {live.data?.system.summary.modelName && <span className="brand-model">{live.data.system.summary.modelName}</span>}
            </div>
          </div>}
        </header>
        <main id="workspace" tabIndex={-1}>
          {stale && (
            <Alert
              className="state-alert"
              showIcon
              type="warning"
              title={<span title="请检查服务连接">数据已过期</span>}
              action={
                <Button onClick={() => cache.invalidateQueries()}>
                  重新连接
                </Button>
              }
            />
          )}
          <Routes>
            <Route path="/" element={<Hm />} />
            <Route path="/site" element={<Sitepg />} />
            <Route path="/monitor" element={<Mntr />} />
            <Route path="/files" element={<Fls />} />
            <Route path="/environments" element={<Envs />} />
            <Route path="/containers" element={<Ctnrs />} />
            <Route path="/databases" element={<Dtbs />} />
            <Route path="/certificates" element={<Admn key="certificates" section="certificates" />} />
            <Route path="/schedules" element={<Admn key="schedules" section="schedules" />} />
            <Route path="/security" element={<Admn key="security" section="security" />} />
            <Route path="/tasks" element={<Tsks />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}

// 应用已确认的方角暗色主题。
createRoot(document.getElementById("root")!).render(
  <ConfigProvider
    locale={zhCN}
    componentSize="small"
    button={{ autoInsertSpace: false, loadingIcon: <Icn name="loading" /> }}
    drawer={{ closeIcon: <Icn name="close" /> }}
    modal={{ closeIcon: <Icn name="close" />, infoIcon: <Icn name="information" />,
      successIcon: <Icn name="check_circle" />, warningIcon: <Icn name="warning" />, errorIcon: <Icn name="warning" /> }}
    alert={{ closeIcon: <Icn name="close" />, infoIcon: <Icn name="information" />,
      successIcon: <Icn name="check_circle" />, warningIcon: <Icn name="warning" />, errorIcon: <Icn name="warning" /> }}
    select={{ suffixIcon: <Icn name="down" />, clearIcon: <Icn name="close" />,
      removeIcon: <Icn name="close" />, loadingIcon: <Icn name="loading" />, menuItemSelectedIcon: <Icn name="check" /> }}
    tabs={{ moreIcon: <Icn name="more_2" /> }}
    empty={{ image: <Icn name="file" /> }}
    theme={{
      algorithm: theme.darkAlgorithm,
      token: {
        colorPrimary: "#C97832",
        colorLink: "#C97832",
        colorLinkHover: "#C97832",
        colorLinkActive: "#C97832",
        colorBgBase: "#0D0D0E",
        colorBgContainer: "#0D0D0E",
        colorBgElevated: "#141414",
        colorText: "#F2F0EC",
        colorTextSecondary: "#A7A29A",
        colorBorder: "#292827",
        colorSuccess: "#5E9B68",
        colorWarning: "#C99A45",
        colorError: "#C45D55",
        borderRadius: 0,
        fontSize: 15,
        fontWeightStrong: 800,
        fontFamily:
          '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", "PingFang SC", sans-serif',
        controlHeight: 28,
        controlHeightSM: 28,
        motion: false,
        padding: 4,
        paddingXXS: 4,
        paddingXS: 4,
        paddingSM: 4,
        paddingMD: 4,
        paddingLG: 4,
        paddingXL: 4,
        paddingContentHorizontalLG: 4,
        margin: 4,
        marginXXS: 4,
        marginXS: 4,
        marginSM: 4,
        marginMD: 4,
        marginLG: 4,
        marginXL: 4,
        marginXXL: 4,
      },
      components: {
        Table: { headerBg: "#141414", cellPaddingBlock: 4, cellPaddingInline: 4,
          cellPaddingBlockSM: 4, cellPaddingInlineSM: 4, cellPaddingBlockMD: 4, cellPaddingInlineMD: 4 },
        Button: { fontWeight: 600, paddingInline: 4, paddingInlineSM: 4, paddingInlineLG: 4,
          paddingBlock: 4, paddingBlockSM: 4, paddingBlockLG: 4, iconGap: 4 },
        Input: { paddingInline: 4, paddingInlineSM: 4, paddingInlineLG: 4,
          paddingBlock: 4, paddingBlockSM: 4, paddingBlockLG: 4 },
        Alert: { defaultPadding: 4, withDescriptionPadding: 4 },
        Select: { optionPadding: 4 },
        Tabs: { inkBarColor: "#C97832", horizontalItemGutter: 4,
          horizontalItemPadding: "4px", horizontalItemPaddingSM: "4px",
          horizontalItemPaddingLG: "4px", verticalItemPadding: "4px",
          verticalItemMargin: "4px 0", cardGutter: 4 },
      },
    }}
  >
    <QueryClientProvider client={client}>
      <HashRouter>
        <Shll />
      </HashRouter>
    </QueryClientProvider>
  </ConfigProvider>,
);
