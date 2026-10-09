import { Alert, Button, Input, Modal, Select, useState } from "./head";
import { qry } from "./api";
import { flref } from "./format.mjs";
import type { FileRoot, OpCap } from "./types";
import { Hnt, Lbl, Stt } from "./widgets";
import { Plnst, usepln } from "./plan";

// 数据库只保留文件快照操作，软件安装项留在原管理页面。
export function Dtbs() {
  const roots = qry<FileRoot[]>("files/roots", 60000);
  const capability = qry<OpCap>("databases/capabilities", 60000);
  const [selection, slct] = useState<string>();
  const [path, setpath] = useState("");
  const [confirming, cnfrm] = useState(false);
  const control = usepln("environments/plans?limit=100");
  const root = roots.data?.find((item) => item.id === selection && item.isAvailable)
    ?? roots.data?.find((item) => item.isAvailable);
  const valid = flref(root?.id, path);
  const enabled = root?.isWritable && capability.data?.enabled && capability.data.actions.includes("backup") && !capability.isError;
  // 同一根内文件进入既有精确确认与本机授权流程。
  async function bkp() {
    if (!root || !valid || !enabled || control.busy) return;
    if (await control.sbmt("database", `${root.id}:${path}`, "backup", { rootID: root.id, relativePath: path })) cnfrm(false);
  }
  return <>
    <Stt query={roots}>
      <div className="file-tools">
        <Select aria-label="目录范围" value={root?.id} className="file-root" disabled={control.busy}
          onChange={(value) => { slct(value); control.rst(); }} options={roots.data?.filter((item) => item.isAvailable).map((item) => ({
            value: item.id, label: <span title={item.path}><Lbl value={item.path} /></span>,
          }))} />
        <Input aria-label="库文件" placeholder="SQLite路径" className="mono database-file" title={path || "相对路径"}
          value={path} maxLength={512} disabled={control.busy}
          onChange={(event) => { setpath(event.target.value); control.rst(); }} />
        <span title={!enabled ? capability.data?.reason || "无法确认原生能力" : !valid ? "请输入根内库文件路径" : undefined}>
          <Button disabled={!enabled || !valid || control.busy} onClick={() => cnfrm(true)}>备份</Button>
        </span>
        <Hnt>管理SQLite普通文件，单个快照最多32MiB。在线备份包含已提交WAL数据，不复制安装库存，不接受SQL或凭据。恢复和下载通过任务页的快照标识操作。</Hnt>
      </div>
    </Stt>
    <Plnst control={control} />
    <Modal title="SQLite快照" open={confirming} onOk={bkp} onCancel={() => { if (!control.posting) cnfrm(false); }}
      okText="执行" cancelText="取消" confirmLoading={control.posting} okButtonProps={{ disabled: !valid || !enabled || control.busy }}>
      <span className="mono"><Lbl value={`${root?.path ?? ""}/${path}`} /></span>
      <Hnt>需要本机管理员授权。快照保存至面板私有备份目录，原库内容不被备份操作替换；只支持可读取的本机SQLite文件。</Hnt>
      {control.error && <Alert type="error" title="提交未确认" description={<Hnt>{control.error}</Hnt>} />}
    </Modal>
  </>;
}
