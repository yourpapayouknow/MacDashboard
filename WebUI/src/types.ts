// 对齐 Swift 只读监控数据结构。
export interface Summary {
  hostname: string;
  modelName?: string | null;
  osVersion: string;
  architecture: string;
  logicalCores: number;
  memoryBytes: number;
  uptimeSeconds: number;
}
export interface Disk {
  mountPath: string;
  fileSystem: string;
  device: string;
  totalBytes: number;
  usedBytes: number;
  availableBytes: number;
  totalFiles: number;
  usedFiles: number;
  availableFiles: number;
}
export interface Net {
  name: string;
  kind: string;
  role: string;
  isUp: boolean;
  addresses: string[];
  receivedBytes: number;
  sentBytes: number;
}
export interface Rate {
  name: string;
  kind: string;
  role: string;
  receivedBytesPerSecond: number;
  sentBytesPerSecond: number;
}
export interface Live {
  sampledAt: string;
  intervalSeconds: number;
  system: {
    summary: Summary;
    cpu: {
      totalPercent: number;
      logicalCores: number;
      physicalCores: number;
      userPercent: number;
      systemPercent: number;
      idlePercent: number;
      perCorePercent: number[];
    };
    load: {
      one: number;
      five: number;
      fifteen: number;
      safeLimit: number;
      maximum: number;
    };
    memory: {
      totalBytes: number;
      usedBytes: number;
      availableBytes: number;
      pressureLevel: number;
      swapUsedBytes: number;
      swapTotalBytes: number;
      activeBytes: number;
      inactiveBytes: number;
      wiredBytes: number;
      compressedBytes: number;
      cachedBytes: number;
    };
    disks: Disk[];
    networks: Net[];
  };
  networkRates: Rate[];
  diskRates: {
    name: string;
    readBytesPerSecond: number;
    writtenBytesPerSecond: number;
    readOperationsPerSecond: number;
    writeOperationsPerSecond: number;
  }[];
}
export interface Point {
  sampledAt: string;
  cpuPercent: number;
  memoryUsedBytes: number;
  loadOne: number;
  networkReceivedBytesPerSecond: number;
  networkSentBytesPerSecond: number;
  diskReadBytesPerSecond: number;
  diskWrittenBytesPerSecond: number;
}
export interface Proc {
  pid: number;
  parentPID: number;
  user: string;
  state: string;
  cpuPercent: number;
  residentBytes: number;
  threadCount: number;
  command: string;
  elapsed: string;
  readBytes: number;
  writtenBytes: number;
}
export interface ProcDtl {
  sampledAt: string;
  pid: number;
  startedAt?: string;
  socketCount?: number;
  files: { descriptor: number; path: string }[];
  isAvailable: boolean;
  isComplete: boolean;
}
export interface Conn {
  descriptor?: number;
  pid: number;
  process: string;
  protocolName: string;
  localEndpoint: string;
  remoteEndpoint?: string;
  state?: string;
}
export interface QueryState {
  isPending: boolean;
  isError: boolean;
  error: Error | null;
  dataUpdatedAt: number;
  data?: unknown;
  refetch: () => unknown;
}

// 对齐固定目录与有界文本读取接口。
export interface FileRoot {
  id: string;
  path: string;
  isAvailable: boolean;
  isWritable: boolean;
}
export interface FileEntry {
  name: string;
  path: string;
  kind: string;
  byteCount: number;
  modifiedAt?: string;
  permissions: number;
}
export interface FileInventory {
  rootID: string;
  path: string;
  entries: FileEntry[];
  isComplete: boolean;
  isWritable: boolean;
}
export interface FilePreview {
  rootID: string;
  path: string;
  byteCount: number;
  text?: string;
  isComplete: boolean;
  digest?: string;
}

// 首页与环境模块共享原生软件清单。
export interface Pkg {
  id: string;
  versions?: string[];
  installedVersion?: string;
  currentVersion?: string;
  description?: string;
  homepage?: string;
  license?: string;
  tap: string;
  outdated: boolean;
  pinned?: boolean;
  deprecated: boolean;
  disabled: boolean;
  installedOnRequest?: boolean;
}
export interface RuntimeVersion {
  tool: string;
  version: string;
  installPath: string;
  active: boolean;
  source: string;
}
export interface Env {
  homebrewAvailable: boolean;
  homebrewPath?: string;
  homebrewInventoryAvailable: boolean;
  formulae: Pkg[];
  casks: Pkg[];
  installedTaps: string[];
  tapInventoryAvailable: boolean;
  miseAvailable: boolean;
  misePath?: string;
  runtimes: RuntimeVersion[];
  runtimeInventoryAvailable: boolean;
  runtimeWarnings: string[];
}

export interface Tap {
  name: string;
  installed: boolean;
  path: string;
  remote?: string;
  head?: string;
  removable: boolean;
  reason: string;
}

// 原生容器与管理域只读快照。
export interface Ctnr {
  id: string; name: string; image: string; state: string;
  status: string; ports: string; networks: string[];
}
export interface Ctnrsnap {
  dockerAvailable: boolean; daemonAvailable: boolean; serverVersion?: string;
  endpoint?: string; daemonID?: string;
  containers: Ctnr[];
  contexts: { name: string; description: string; endpoint: string; isCurrent: boolean; error?: string }[];
  podmanAvailable: boolean; colimaAvailable: boolean; limaAvailable: boolean; orbStackAvailable: boolean;
}
export interface Admin {
  sampledAt: string;
  databases: { id: string; engine: string; source: string; version?: string; state: string }[];
  certificates: { sha256: string; label: string; keychain: string }[];
  schedules: { id: string; manager: string; schedule: string; definitionPath?: string; source?: string }[];
  fileRoots: FileRoot[];
  firewall: { isAvailable: boolean; isEnabled?: boolean; stealthMode?: boolean };
  users: { name: string; numericID: number }[];
  groups: { name: string; numericID: number }[];
}
export interface Plan {
  id: string; createdAt: string; expiresAt: string;
  domain: string; action: string; target: string; state: string; message: string;
  parameters: Record<string, string>;
  rollbackToken?: string;
  backup?: { kind: string };
  exitCode?: number;
}
// 软件执行能力与固定操作白名单。
export interface OpCap { enabled: boolean; actions: string[]; reason: string; }
export interface Audit {
  id: string; recordedAt: string; operation: string; target?: string;
  succeeded: boolean; message: string; sourceAddress?: string;
}

// 网站模块复用原生监听和启动定义。
export interface Site {
  pid: number;
  process: string;
  kind: string;
  managementURL?: string;
  managementURLSource?: string;
  listeners: { address: string; port: number; protocolName: string }[];
}
export interface SiteDef {
  label: string;
  source: string;
  program: string;
  definitionPath: string;
  isDisabled: boolean;
  runAtLoad: boolean;
  expectedPorts: number[];
  isActive: boolean;
}
export interface SiteNote {
  label: string;
  source: string;
  definitionPath: string;
  note: string;
}
export interface SiteNotes {
  enabled: boolean;
  target?: string;
  notes: SiteNote[];
}
export interface Sites {
  sampledAt: string;
  services: Site[];
  configuredServices: SiteDef[];
  hasFullVisibility: boolean;
}

// 启动管理器返回的运行证据，不展示启动参数。
export interface Srv {
  id: string;
  manager: string;
  source?: string;
  state: string;
  program?: string;
  definitionPath?: string;
  isDisabled: boolean;
  runAtLoad: boolean;
  pid?: number;
  runs?: number;
  lastExitCode?: number;
  user?: string;
}

export interface Srvs {
  sampledAt: string;
  services: Srv[];
  homebrewAvailable: boolean;
}

// 授权桥接能力与不含凭据的操作任务。
export interface Svccap {
  enabled: boolean;
  reason: string;
  target?: string;
}
export interface Svcop {
  id: string;
  target?: string;
  action: string;
  state: string;
  createdAt: string;
  updatedAt: string;
  message?: string;
  exitCode?: number;
}
export interface SiteInfra {
  sampledAt: string;
  adGuard: {
    isAvailable: boolean;
    managementURL?: string;
    bindHosts: string[];
    dnsPort?: number;
    upstreams: string[];
    bootstrapServers: string[];
    isTLSEnabled?: boolean;
    isDHCPEnabled?: boolean;
    dhcpInterface?: string;
    rewrites: { domain: string; answer: string; isEnabled: boolean }[];
  };
  zoraxy: {
    isAvailable: boolean;
    managementURL?: string;
    routes: {
      domain: string;
      aliases: string[];
      isDisabled: boolean;
      listeningPorts: number[];
      activeOrigins: {
        address: string;
        requiresTLS: boolean;
        weight: number;
      }[];
      inactiveOrigins: {
        address: string;
        requiresTLS: boolean;
        weight: number;
      }[];
    }[];
    certificates: { fileName: string; subject?: string; expiresAt?: string }[];
  };
}
