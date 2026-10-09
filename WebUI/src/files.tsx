import { Alert, Button, Drawer, Empty, Input, Modal, Select, useState } from "./head";
import type { TableColumnsType } from "./head";
import { qry } from "./api";
import type { FileEntry, FileInventory, FilePreview, FileRoot, OpCap } from "./types";
import { dt, flref, fmtbyt, txtok } from "./format.mjs";
import { Icn, Tbl as Table, Hnt, Lbl, Stt } from "./widgets";
import { Plnst, usepln } from "./plan";

// 从现有固定目录浏览文件并按需预览文本。
export function Fls() {
  const roots = qry<FileRoot[]>("files/roots", 60000);
  const [selection, slct] = useState<string>();
  const [path, setpath] = useState("");
  const [search, srch] = useState("");
  const [opened, opn] = useState<FileEntry>();
  const [creating, crtdlg] = useState(false);
  const [kind, setkind] = useState("createDirectory");
  const [name, setname] = useState("");
  const [moving, mvdlg] = useState(false);
  const [trashing, trshdlg] = useState(false);
  const [destinationRoot, dstrt] = useState("");
  const [destinationPath, dstpth] = useState("");
  const [editing, edit] = useState<FilePreview>();
  const [draft, drft] = useState("");
  const root = roots.data?.find((item) => item.id === selection && item.isAvailable)
    ?? roots.data?.find((item) => item.isAvailable);
  const inventory = `files?root=${encodeURIComponent(root?.id ?? "")}&path=${encodeURIComponent(path)}`;
  const directory = qry<FileInventory>(inventory, 60000, !!root);
  const control = usepln(inventory);
  const capability = qry<OpCap>("files/capabilities", 60000);
  const creatable = root?.isWritable && directory.data?.isWritable && capability.data?.enabled && !capability.isError
    && capability.data.actions.some((action) => ["createDirectory", "createFile"].includes(action));
  const enabled = creatable && capability.data?.actions.includes(kind);
  const relative = path ? `${path}/${name}` : name;
  const valid = !name.includes("/") && flref(root?.id, relative) && !!name;
  const movable = root?.isWritable && directory.data?.isWritable && capability.data?.enabled && !capability.isError
    && capability.data.actions.includes("move");
  const trashable = root?.isWritable && directory.data?.isWritable && capability.data?.enabled && !capability.isError
    && capability.data.actions.includes("trash");
  const moveValid = flref(destinationRoot, destinationPath)
    && (destinationRoot !== root?.id || destinationPath !== opened?.path);
  const preview = qry<FilePreview>(
    `files/preview?root=${encodeURIComponent(root?.id ?? "")}&path=${encodeURIComponent(opened?.path ?? "")}`,
    60000, !!root && !!opened,
  );
  const writable = root?.isWritable && directory.data?.isWritable && capability.data?.enabled && !capability.isError
    && capability.data.actions.includes("write");
  const textValid = txtok(draft) && draft !== editing?.text;
  // 切换目录时清除旧筛选和预览。
  function chngdir(next: string) { if (control.busy) return; setpath(next); srch(""); opn(undefined); edit(undefined); trshdlg(false); control.rst(); }
  // 当前目录和名称构成精确目标，创建只使用既有授权队列。
  async function sbmt() {
    if (!root || !enabled || !valid || kind === "createFile" && !txtok(draft) || control.busy) return;
    const parameters: Record<string, string> = { rootID: root.id, relativePath: relative };
    if (kind === "createFile") parameters.content = draft;
    if (await control.sbmt("file", `${root.id}:${relative}`, kind, parameters)) crtdlg(false);
  }
  // 冻结当前文件和目标位置，复用同一个授权队列。
  async function sbmtmv() {
    if (!root || !opened || !movable || !moveValid || control.busy) return;
    if (await control.sbmt("file", `${root.id}:${opened.path}`, "move", { rootID: root.id, relativePath: opened.path,
      destinationRootID: destinationRoot, destinationRelativePath: destinationPath })) {
      mvdlg(false); opn(undefined);
    }
  }
  // 精确确认当前普通文件，回收后恢复统一归任务记录。
  async function sbmttrsh() {
    if (!root || !opened || !trashable || control.busy) return;
    if (await control.sbmt("file", `${root.id}:${opened.path}`, "trash", { rootID: root.id, relativePath: opened.path })) {
      trshdlg(false); opn(undefined);
    }
  }
  // 保存使用开始编辑时冻结的完整预览摘要。
  async function sbmttxt() {
    if (!root || !opened || !editing?.digest || !writable || !textValid || control.busy) return;
    if (await control.sbmt("file", `${editing.rootID}:${editing.path}`, "write", { rootID: editing.rootID,
      relativePath: editing.path, digest: editing.digest, content: draft })) {
      edit(undefined); opn(undefined);
    }
  }
  const columns: TableColumnsType<FileEntry> = [
    { title: "名称", dataIndex: "name", width: 260, sorter: (a, b) => a.name.localeCompare(b.name),
      render: (value: string, row) => row.kind === "directory" || row.kind === "file"
        ? <button className="table-link mono" aria-label={value} disabled={control.busy}
            onClick={() => row.kind === "directory" ? chngdir(row.path) : opn(row)}><Lbl value={value} /></button>
        : <span className="mono"><Lbl value={value} /></span> },
    { title: "类型", dataIndex: "kind", width: 85,
      render: (value: string) => ({ directory: "目录", file: "文件", link: "链接", other: "特殊文件" })[value] ?? "未知" },
    { title: "大小", dataIndex: "byteCount", align: "right", width: 110,
      sorter: (a, b) => a.byteCount - b.byteCount, render: (value: number, row) => row.kind === "file" ? fmtbyt(value) : "—" },
    { title: "权限", dataIndex: "permissions", width: 80,
      render: (value: number) => <span className="mono">{value.toString(8).padStart(3, "0")}</span> },
    { title: "修改时间", dataIndex: "modifiedAt", width: 190,
      render: (value?: string) => value ? <Lbl value={dt(value).toLocaleString("zh-CN")} /> : "—" },
  ];
  const rows = directory.data?.entries.filter((item) => item.name.toLowerCase().includes(search.toLowerCase())) ?? [];
  return <>
    <div className="file-tools">
      <Select aria-label="目录范围" value={root?.id} className="file-root" disabled={control.busy}
        options={roots.data?.map((item) => ({ value: item.id, disabled: !item.isAvailable,
          label: <span className="mono"><Lbl value={item.path} /></span> }))}
        onChange={(value) => { slct(value); chngdir(""); }} />
      <Button disabled={!path || control.busy} onClick={() => chngdir(path.split("/").slice(0, -1).join("/"))}>上级</Button>
      <span className="file-location mono"><Lbl value={path || "/"} /></span>
      <Input aria-label="搜索文件" placeholder="搜索文件" value={search} allowClear={{ clearIcon: <Icn name="close" /> }}
        onChange={(event) => srch(event.target.value)} />
      <Button disabled={!root} loading={directory.isFetching} onClick={() => directory.refetch()}>刷新</Button>
      <span title={directory.data && !directory.data.isWritable ? "当前目录不可写" : capability.data?.reason || "无法确认文件执行能力"}>
        <Button disabled={!creatable || control.busy || directory.isError || directory.isPending}
          onClick={() => { control.rst(); setname(""); drft(""); setkind("createDirectory"); crtdlg(true); }}>新建</Button>
      </span>
      <Hnt>目录最多读取2000项；预览256KiB的UTF-8文本，普通附件限32MiB。文件操作需本机授权和可写父目录，不覆盖现有条目。</Hnt>
    </div>
    <Plnst control={control} />
    <Stt query={roots}>
      {root ? <Stt query={directory}>
        {directory.data && !directory.data.isComplete && <Alert className="state-alert" type="warning" showIcon
          title={<span title="超过2000项或部分目录项无法读取">清单不完整</span>} />}
        <Table<FileEntry> rowKey="path" columns={columns} dataSource={rows} size="small" scroll={{ x: 725 }}
          pagination={{ pageSize: 20, showSizeChanger: false }} locale={{ emptyText: search ? "无匹配文件" : "目录为空" }} />
      </Stt> : <Empty description="无可用目录" />}
    </Stt>
    <Drawer title={opened ? <Lbl value={opened.name} /> : "文本预览"} open={!!opened && !moving} size={560}
      onClose={() => { if (!control.posting) { opn(undefined); edit(undefined); trshdlg(false); } }} >
      <div className="row-actions">
        {trashing ? <>
          <Button danger disabled={!trashable || control.busy} loading={control.posting} onClick={sbmttrsh}>确认回收</Button>
          <Button disabled={control.posting} onClick={() => trshdlg(false)}>取消</Button>
          <Hnt>只回收所有者的同卷普通文件，不永久删除。成功回执支持任务页恢复；废纸篓清空、文件变化或原位置被占用会拒绝恢复。回执失败须检查系统废纸篓。</Hnt>
        </> : editing ? <>
          <Button disabled={!writable || !textValid || control.busy} loading={control.posting} onClick={sbmttxt}>保存</Button>
          <Button disabled={control.posting} onClick={() => edit(undefined)}>取消</Button>
          <Hnt>仅保存256KiB以内UTF-8文本。需停止其他写入并在本机授权；保存前备份并核对原摘要，恢复统一在任务记录。</Hnt>
        </> : <>
        <Button disabled={!root || !opened || opened.byteCount > 32 * 1024 * 1024}
          href={root && opened ? `/api/v1/files/download?root=${encodeURIComponent(root.id)}&path=${encodeURIComponent(opened.path)}` : undefined}
          download={opened?.name}>下载</Button>
        <span title={directory.data && !directory.data.isWritable ? "当前目录不可写" : capability.data?.reason || "无法确认文件执行能力"}>
          <Button disabled={!movable || !opened || control.busy || directory.isError || directory.isPending}
            onClick={() => { control.rst(); dstrt(root!.id); dstpth(opened!.path); mvdlg(true); }}>移动</Button>
        </span>
        <span title={capability.data?.reason}>
          <Button danger disabled={!trashable || !opened || control.busy || directory.isError || directory.isPending}
            onClick={() => { control.rst(); trshdlg(true); }}>回收</Button>
        </span>
        {preview.data?.digest && <span title={capability.data?.reason}>
          <Button disabled={!writable || !preview.data?.digest || preview.isError || preview.isPending || control.busy}
            onClick={() => { control.rst(); drft(preview.data!.text ?? ""); edit(preview.data); }}>编辑</Button>
        </span>}
        <Hnt>完整附件最多32MiB，读取期间变化会拒绝下载。预览截断不会截断附件。</Hnt>
        </>}
      </div>
      {trashing ? control.error && <Alert type="error" title="提交未确认" description={<Hnt>{control.error}</Hnt>} /> : editing ? <>
        <Input.TextArea aria-label="文件内容" className="mono" value={draft} rows={12} spellCheck={false}
          disabled={control.posting} onChange={(event) => drft(event.target.value)} />
        {!txtok(draft) && <Alert type="error" title="文本超限或含NUL" />}
        {control.error && <Alert type="error" title="提交未确认" description={<Hnt>{control.error}</Hnt>} />}
      </> : <Stt query={preview}>
        {preview.data && <>
          {!preview.data.isComplete && <Alert className="state-alert" type="warning" showIcon
            title={<span title="仅显示文件开头256KiB，完整文件未加载">预览已截断</span>} />}
          {preview.data.text == null ? <Empty description="无法预览文本" />
            : preview.data.text === "" ? <Empty description="文件为空" />
              : <pre className="file-preview" tabIndex={0}>{preview.data.text}</pre>}
        </>}
      </Stt>}
    </Drawer>
    <Modal title="填写名称" open={creating} onOk={sbmt} onCancel={() => { if (!control.posting) crtdlg(false); }}
      okText="确定" cancelText="取消" confirmLoading={control.posting}
      okButtonProps={{ disabled: !enabled || !valid || kind === "createFile" && !txtok(draft) || control.busy }}>
      <Select aria-label="条目类型" value={kind} disabled={control.posting} onChange={setkind} options={[
        { value: "createDirectory", label: "目录", disabled: !capability.data?.actions.includes("createDirectory") },
        { value: "createFile", label: "文本文件", disabled: !capability.data?.actions.includes("createFile") },
      ]} />
      <Input aria-label="条目名称" placeholder="条目名称" disabled={control.posting} value={name} maxLength={255}
        onChange={(event) => setname(event.target.value)} />
      {kind === "createFile" && <Input.TextArea aria-label="文件内容" className="mono" value={draft} rows={8}
        spellCheck={false} disabled={control.posting} onChange={(event) => drft(event.target.value)} />}
      <Hnt>目录权限700，文本权限600。名称不可含斜线、换行或穿越；已有条目禁止覆盖。文本限256KiB以内UTF-8，不含NUL；失败后检查实际条目。</Hnt>
      {name && !valid && <Alert type="error" title="名称或路径无效" />}
      {kind === "createFile" && !txtok(draft) && <Alert type="error" title="文本超限或含NUL" />}
      {control.error && <Alert type="error" title="提交未确认" description={<Hnt>{control.error}</Hnt>} />}
    </Modal>
    <Modal title="调整位置" open={moving} onOk={sbmtmv} onCancel={() => { if (!control.posting) mvdlg(false); }}
      okText="执行" cancelText="取消" confirmLoading={control.posting}
      okButtonProps={{ disabled: !movable || !moveValid || control.busy }}>
      <div className="mono"><Lbl value={opened?.path ?? ""} /></div>
      <Select aria-label="目标范围" value={destinationRoot} className="file-root"
        options={roots.data?.map((item) => ({ value: item.id, disabled: !item.isAvailable || !item.isWritable,
          label: <span className="mono"><Lbl value={item.path} /></span> }))} onChange={dstrt} />
      <Input aria-label="相对路径" placeholder="相对路径" value={destinationPath} maxLength={512}
        onChange={(event) => dstpth(event.target.value)} />
      <Hnt>目标父目录必须存在且与源文件同卷。只移动普通文件，不覆盖目标；原位置记录用于恢复，不复制文件内容。</Hnt>
      {!moveValid && <Alert type="warning" title="请填写新位置" />}
      {control.error && <Alert type="error" title="提交未确认" description={<Hnt>{control.error}</Hnt>} />}
    </Modal>
  </>;
}
