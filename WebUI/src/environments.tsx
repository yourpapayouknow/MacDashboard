import { Alert, Button, Drawer, Input, Modal, useEffect, useLocation, useState } from "./head";
import type { TableColumnsType } from "./head";
import { qry } from "./api";
import type { Env, Pkg, Tap, OpCap } from "./types";
import { Icn, Tbl as Table, Hnt, Lbl, Stt } from "./widgets";
import { Plnst, usepln } from "./plan";
import { pkgreq } from "./format.mjs";
import { envgrp, languages } from "./envfmt.mjs";

interface LangRow { key: string; name: string; version: string; source: string; path?: string; pkg?: Pkg }

// 按软件类型、源与运行时查看真实库存。
export function Envs() {
  const inventory = qry<Env>("environments", 60000);
  const [selected, settab] = useState("python");
  const [search, srch] = useState("");
  const [opened, opn] = useState<Pkg>();
  const [tapname, tapopn] = useState<string>();
  const [action, cfrm] = useState<string>();
  const [adding, adddlg] = useState(false);
  const [addkind, setkind] = useState("formula");
  const [pkg, pkgid] = useState("");
  const [lkup, setlkup] = useState("");
  const control = usepln("environments");
  const { posting, busy, error } = control;
  const capability = qry<OpCap>("environments/capabilities", 60000);
  const addparams: Record<string, string> = addkind === "formula" ? {} : { kind: addkind };
  const candidate = qry<Pkg>(`environments/${addkind}?id=${encodeURIComponent(lkup)}`, 60000, adding && addkind !== "tap" && !!lkup);
  const found = adding && addkind !== "tap" && lkup === pkg ? candidate.data : undefined;
  const tap = qry<Tap>(`environments/tap?id=${encodeURIComponent(tapname ?? "")}`, 60000, !!tapname);
  const installed = found && (addkind === "cask" ? !!found.installedVersion : !!found.versions?.length);
  const known = found && found.pinned !== undefined && (addkind === "formula" || !!found.tap && found.tap !== "unknown");
  const instok = known && !installed && !found.disabled && found.pinned === false;
  const location = useLocation();
  // 首页快捷入口定位到同一份软件清单。
  useEffect(() => {
    const parameters = new URLSearchParams(location.search);
    srch(parameters.get("pkg") ?? "");
    if (parameters.has("pkg")) settab(parameters.get("kind") === "casks" ? "casks" : envgrp(parameters.get("pkg") ?? ""));
  }, [location.search]);
  // 按当前筛选文字匹配库存项。
  const mtch = (value: string) => value.toLowerCase().includes(search.toLowerCase());
  const columns: TableColumnsType<Pkg> = [
    { title: "名称", dataIndex: "id", width: 260, sorter: (a, b) => a.id.localeCompare(b.id),
      render: (value: string, row) => <button className="table-link mono" aria-label={value} disabled={busy}
        onClick={() => { opn(row); control.rst(); }}><Lbl value={value} /></button> },
    { title: "已装版本", width: 150, render: (_, row) => <span className="mono"><Lbl
        value={row.versions?.join(",") || row.installedVersion || "—"} /></span> },
    { title: "来源", dataIndex: "tap", width: 190,
      render: (value: string) => <span className="mono"><Lbl value={value === "unknown" ? "未确认" : value} /></span> },
    { title: "状态", width: 100, render: (_, row) => row.disabled ? "安装禁用" : row.deprecated ? "已废弃" : "已安装" },
    { title: "更新", dataIndex: "outdated", width: 85, render: (value: boolean) => value ? "可更新" : "当前版本" },
    { title: "固定", dataIndex: "pinned", width: 75,
      render: (value?: boolean) => value === undefined ? "未确认" : value ? "是" : "否" },
  ];
  const env = inventory.data;
  const langRows = (group: string): LangRow[] => [
    ...(env?.formulae.filter((row) => envgrp(row.id) === group).map((row) => ({
      key: row.id, name: row.id, version: row.versions?.join(",") || "—", source: "Homebrew", pkg: row,
    })) ?? []),
    ...(env?.runtimes.filter((row) => (envgrp(row.tool) === "formulae" ? "runtimes" : envgrp(row.tool)) === group).map((row) => ({
      key: `${row.tool}:${row.installPath}:${row.version}`, name: row.installPath.split("/").at(-1) || row.tool,
      version: row.version, source: row.source, path: row.installPath,
    })) ?? []),
  ];
  const categories = [
    ...languages.filter(({ id }) => langRows(id).length > 0),
    ...(langRows("runtimes").length ? [{ id: "runtimes", label: "其他运行时", icon: "" }] : []),
    { id: "formulae", label: "工具软件", icon: "" },
    { id: "casks", label: "图形应用", icon: "" },
    { id: "taps", label: "软件源", icon: "" },
  ];
  const tab = categories.some(({ id }) => id === selected) ? selected : categories[0].id;
  const language = !["formulae", "casks", "taps"].includes(tab);
  const runtimeColumns: TableColumnsType<LangRow> = [
    { title: "名称", dataIndex: "name", width: 180, render: (value: string, row) => row.pkg
      ? <button className="table-link mono" aria-label={value} disabled={busy} onClick={() => { opn(row.pkg); control.rst(); }}><Lbl value={value} /></button>
      : <span className="mono"><Lbl value={value} /></span> },
    { title: "已装版本", dataIndex: "version", width: 160, render: (value: string) => <span className="mono"><Lbl value={value} /></span> },
    { title: "来源", dataIndex: "source", width: 130 },
    { title: "路径", dataIndex: "path", render: (value?: string) => <span className="mono">{value ? <Lbl value={value} /> : "—"}</span> },
  ];
  const current = opened && (opened.versions ? env?.formulae : env?.casks)?.find((row) => row.id === opened.id);
  const kind = opened?.versions ? "formula" : "cask";
  const parameters: Record<string, string> = kind === "cask" ? { kind: "cask" } : {};
  const manageable = current && current.pinned !== undefined && (kind === "formula" || !!current.tap && current.tap !== "unknown");
  const upgradable = manageable && current.outdated && !current.pinned && !current.disabled;
  const removable = manageable && !current.pinned;
  const upstream = current?.currentVersion && current.currentVersion !== current.installedVersion;
  // 保存计划后对同一个标识提交确认，失败保留计划供查询。
  async function sbmt() {
    if (!current || !manageable || !action || busy || !capability.data?.enabled || !capability.data.actions.includes(action)
      || action === "upgrade" && !upgradable || action === "remove" && !removable) return;
    if (await control.sbmt("package", current.id, action, parameters)) cfrm(undefined);
  }
  // 查询精确标识，迟到结果只对应原输入。
  function srchpkg() {
    if (busy || candidate.isFetching || !pkgreq(pkg, "install", addparams)) return;
    if (lkup === pkg) candidate.refetch(); else setlkup(pkg);
  }
  // 查询确认后安装同一对象，排队进度沿用原页面。
  async function instpkg() {
    if (addkind === "tap") {
      if (busy || !pkgreq(pkg, "install", addparams) || env?.installedTaps.includes(pkg)
        || !capability.data?.enabled || capability.isError || !capability.data.actions.includes("install")) return;
      if (await control.sbmt("package", pkg, "install", addparams)) adddlg(false);
      return;
    }
    if (!found || !instok || busy || !capability.data?.enabled || capability.isError
      || !capability.data.actions.includes("install")) return;
    if (await control.sbmt("package", found.id, "install", addparams)) adddlg(false);
  }
  // 同一源详情内确认移除，终态刷新原生条件。
  async function rmtap() {
    if (!tap.data?.removable || tap.isError || busy || !capability.data?.enabled || capability.isError
      || !capability.data.actions.includes("remove")) return;
    if (await control.sbmt("package", tap.data.name, "remove", { kind: "tap" })) cfrm(undefined);
  }
  const readable = tab === "taps" ? env?.tapInventoryAvailable : env?.homebrewInventoryAvailable;
  return <>
    <div className="env-categories" role="group" aria-label="环境分类">
      {categories.map(({ id, label, icon }) => <button key={id} className="env-category" data-category={id}
        aria-pressed={tab === id} onClick={() => { settab(id); srch(""); }}>
        {icon ? <img src={`/languages/${icon}.svg`} alt="" /> : <Icn name={id === "casks" ? "box_3" : id === "taps" ? "storage" : "terminal"} />}
        <span>{label}</span>
      </button>)}
    </div>
    <div className="table-tools">
      <Input aria-label="搜索条目" placeholder="搜索条目" value={search} allowClear={{ clearIcon: <Icn name="close" /> }} onChange={(event) => srch(event.target.value)} />
      <Button loading={inventory.isFetching} onClick={() => inventory.refetch()}>刷新</Button>
      {<span title={capability.data?.reason || "无法确认软件执行能力"}><Button
        disabled={!capability.data?.enabled || !capability.data.actions.includes("install") || capability.isError || busy}
        onClick={() => { control.rst(); opn(undefined); tapopn(undefined); cfrm(undefined); pkgid(""); setlkup(""); setkind(tab === "taps" ? "tap" : tab === "casks" ? "cask" : "formula"); adddlg(true); }}>{tab === "taps" ? "添加源" : "添加软件"}</Button></span>}
      <Hnt>Homebrew来源为本机已安装源。软件与源变更需本机授权，有效会话复用；未安装与读取失败单独显示。语言按真实已装版本分类，支持Homebrew、mise及本机运行时。其他来源只读，不切换版本，不扫描项目虚拟环境。</Hnt>
    </div>
    {!opened && !tapname && !adding && <Plnst control={control} />}
    <Stt query={inventory}>
      {env && env.runtimeWarnings?.length > 0 && <Alert showIcon type="warning" title="部分环境读取失败" description={<Hnt>{env.runtimeWarnings.join("、")}</Hnt>} />}
      {language ? <>
        {env?.homebrewAvailable && !env.homebrewInventoryAvailable && <Alert showIcon type="warning" title="软件清单读取失败" />}
        <Table<LangRow> size="small" rowKey="key" columns={runtimeColumns} scroll={{ x: 700 }}
          dataSource={langRows(tab).filter((row) => mtch(`${row.name} ${row.version} ${row.source} ${row.path ?? ""}`))}
          pagination={{ pageSize: 15, showSizeChanger: false }} locale={{ emptyText: search ? "无匹配条目" : "未安装运行时" }} />
      </> : env && (!env.homebrewAvailable || !readable) ? <Alert showIcon type="warning"
        title={env.homebrewAvailable ? "清单读取失败" : "未安装Homebrew"} />
        : tab === "taps" ? <Table<{ name: string }> size="small" rowKey="name"
          columns={[{ title: "仓库", dataIndex: "name", render: (value: string) => <button className="table-link mono" aria-label={value}
            disabled={busy} onClick={() => { control.rst(); cfrm(undefined); tapopn(value); }}><Lbl value={value} /></button> }]}
          dataSource={env?.installedTaps.filter(mtch).map((name) => ({ name })) ?? []}
          pagination={{ pageSize: 15, showSizeChanger: false }} locale={{ emptyText: search ? "无匹配条目" : "未添加源" }} />
          : <Table<Pkg> size="small" rowKey="id" columns={columns} scroll={{ x: 800 }}
            dataSource={(tab === "formulae" ? env?.formulae.filter((row) => envgrp(row.id) === "formulae") : env?.casks)?.filter((row) => mtch(`${row.id} ${row.tap}`)) ?? []}
            pagination={{ pageSize: 15, showSizeChanger: false }} locale={{ emptyText: search ? "无匹配条目" : "未安装软件" }} />}
    </Stt>
    <Drawer title={opened ? <Lbl value={opened.id} /> : "软件详情"} open={!!opened} size={480}
      onClose={() => { if (!posting) { opn(undefined); cfrm(undefined); } }}>
      {current ? <>
        {(upstream || current.license || current.installedOnRequest !== undefined) && <dl className="home-detail">
          {upstream && <><dt>上游版本</dt><dd className="mono"><Lbl value={current.currentVersion!} /></dd></>}
          {current.license && <><dt>许可证</dt><dd><Lbl value={current.license} /></dd></>}
          {current.installedOnRequest !== undefined && <><dt>安装请求</dt><dd>{current.installedOnRequest ? "用户指定" : "间接安装"}</dd></>}
        </dl>}
        {manageable && <div className="row-actions">
          {action ? <>
            <Button loading={posting} disabled={busy || !capability.data?.enabled || capability.isError
              || action === "upgrade" && !upgradable || action === "remove" && !removable} onClick={sbmt}>
              {action === "remove" ? "确认移除" : action === "upgrade" ? "确认升级" : action === "pin" ? "确认固定" : "确认解除"}
            </Button>
            <Button disabled={posting} onClick={() => cfrm(undefined)}>取消</Button>
            <Hnt>{action === "remove" ? "移除Homebrew当前默认版本，其他已装版本可能保留。依赖保护仍有效，不强制删除，不自动清理无关依赖。先停止相关服务；版本状态记录不能恢复二进制，失败须检查实际状态。" : action === "upgrade" ? "按Homebrew规则升级该软件及必要依赖，关联软件也可能升级或重装。先停止相关服务；仅记录原版本状态，不能自动恢复软件二进制。超时或失败须检查实际状态。" : "固定会阻止该软件升级，原状态及固定链接先备份。"}{kind === "cask" && "先保存并退出应用。不提供zap或额外sudo，需提权的安装步骤会失败；来源变化时拒绝继续。"}确认后使用本机授权。</Hnt>
          </> : <>
          <span title={capability.data?.reason || "无法确认软件执行能力"}>
            <Button disabled={!capability.data?.enabled || !capability.data.actions.includes(current.pinned ? "unpin" : "pin") || capability.isError || busy}
              onClick={() => cfrm(current.pinned ? "unpin" : "pin")}>
              {current.pinned ? "解除固定" : "固定版本"}
            </Button>
          </span>
          {upgradable && <Button
            disabled={!capability.data?.enabled || !capability.data.actions.includes("upgrade") || capability.isError || busy}
            onClick={() => cfrm("upgrade")}>升级软件</Button>}
          {removable && <Button disabled={!capability.data?.enabled || !capability.data.actions.includes("remove") || capability.isError || busy}
            onClick={() => cfrm("remove")}>移除版本</Button>}
          <Hnt>{current.description}。{capability.data?.reason}。固定会阻止升级与移除；其他软件仍可能需要较新依赖。原固定状态与具体链接在执行前备份，软件二进制不自动恢复。</Hnt>
          </>}
        </div>}
        {action && error && <Alert type="error" title="提交未确认" description={<Hnt>{error}</Hnt>} />}
        {!manageable && <Alert type="warning" title="软件状态未确认" description={<Hnt>{current.description}。Homebrew未提供固定状态或来源，无法安全执行软件变更。</Hnt>} />}
      </> : opened && !(control.plan?.action === "remove" && control.plan.state === "succeeded")
        && <Alert type="warning" title="软件已不在清单" />}
      <Plnst control={control} />
    </Drawer>
    <Drawer title={tapname ? <Lbl value={tapname} /> : "软件源"} open={!!tapname} size={480}
      onClose={() => { if (!posting) { tapopn(undefined); cfrm(undefined); } }}>
      <Stt query={tap}>
        {tap.data && <>
          <dl className="home-detail">
            {tap.data.remote && <><dt>远端地址</dt><dd className="mono"><Lbl value={tap.data.remote} /></dd></>}
            <dt>本地位置</dt><dd className="mono"><Lbl value={tap.data.path} /></dd>
            {tap.data.head && <><dt>提交版本</dt><dd className="mono"><Lbl value={tap.data.head} /></dd></>}
          </dl>
          {tap.data.removable && !tap.isError ? <div className="row-actions">
            {action === "remove" ? <>
              <Button disabled={busy || !capability.data?.enabled || capability.isError} loading={posting} onClick={rmtap}>确认移除</Button>
              <Button disabled={posting} onClick={() => cfrm(undefined)}>取消</Button>
            </> : <Button disabled={busy || !capability.data?.enabled || capability.isError || !capability.data.actions.includes("remove")}
              title={capability.data?.reason} onClick={() => cfrm("remove")}>移除源</Button>}
            <Hnt>只移除无软件占用的第三方默认源，不卸载软件。先停止其他仓库与软件写入；执行前保存完整仓库附件，文件或软件状态变化时拒绝继续。仓库上限16MiB，附件仅在任务记录下载，不自动恢复。确认后使用本机授权。</Hnt>
          </div> : <Alert type="warning" title={tap.data.installed ? "源不可移除" : "源已不在清单"}
            description={<Hnt>{tap.data.reason}</Hnt>} />}
        </>}
      </Stt>
      {error && <Alert type="error" title="提交未确认" description={<Hnt>{error}</Hnt>} />}
      <Plnst control={control} />
    </Drawer>
    <Modal title={addkind === "tap" ? "添加软件源" : "查找软件"} open={adding} onOk={addkind === "tap" || found ? instpkg : srchpkg}
      onCancel={() => { if (!posting) adddlg(false); }} okText={addkind === "tap" ? "确认添加" : found ? "确认安装" : "查询"} cancelText="取消"
      confirmLoading={posting || candidate.isFetching} okButtonProps={{ disabled: busy || !pkgreq(pkg, "install", addparams)
        || addkind === "tap" && (env?.installedTaps.includes(pkg) || !capability.data?.enabled || capability.isError || !capability.data.actions.includes("install"))
        || candidate.isFetching || !!found && (!instok || !capability.data?.enabled || capability.isError || !capability.data.actions.includes("install")) }}>
      <Input aria-label={addkind === "tap" ? "源标识" : "软件标识"} placeholder={addkind === "tap" ? "所有者/仓库" : "软件标识"} className="mono" value={pkg} maxLength={255}
        disabled={posting} onChange={(event) => pkgid(event.target.value)} />
      {found?.license && <dl className="home-detail"><dt>许可证</dt><dd><Lbl value={found.license} /></dd></dl>}
      {installed && <Alert type="warning" title="软件已安装" />}
      {addkind === "tap" && env?.installedTaps.includes(pkg) && <Alert type="warning" title="源已安装" />}
      {found?.disabled && <Alert type="warning" title="安装已禁用" />}
      {found && !known && <Alert type="warning" title="软件状态未确认" />}
      {lkup === pkg && candidate.isError && <Alert type="error" title="查询未确认" description={<Hnt>{candidate.error.message}</Hnt>} />}
      {error && <Alert type="error" title="提交未确认" description={<Hnt>{error}</Hnt>} />}
      <Hnt>{addkind === "tap" ? "填写小写所有者/仓库，省略homebrew-前缀；使用GitHub默认HTTPS地址，不接受自定义地址或凭据，不自动信任源。输入格式正确不表示远端存在；确认后由Homebrew连接并验证，不安装源内软件。超时或失败须检查实际状态。" : <>{found?.description && `${found.description}。`}填写精确Homebrew标识，别名不接受。查询不请求系统授权；确认安装后记录原状态，依赖及关联软件可能同步更新。不升级已存在目标；不能自动恢复二进制，超时或失败须检查实际状态。{addkind === "cask" && "图形应用不追加sudo，需提权的安装步骤会失败；先保存并退出相关应用。"}</>}</Hnt>
      <Plnst control={control} />
    </Modal>
  </>;
}
