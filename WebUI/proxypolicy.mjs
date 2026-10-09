// 仅放行显式启用且同源的固定服务操作。
export function proxyok({ enabled, packageEnabled = false, method, path, host, origin }) {
  const route =
    /^\/api\/v1\/services\/([A-Za-z0-9_.-]{1,255})\/(start|stop|restart)$/.exec(
      path ?? "",
    );
  return (
    enabled === true &&
    method === "POST" &&
    ((!!route && ![".", ".."].includes(route[1])) || path === "/api/v1/sites/notes"
      || (packageEnabled && (path === "/api/v1/environments/plans"
        || /^\/api\/v1\/environments\/plans\/[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}\/execute$/.test(path ?? "")))) &&
    /^(127\.0\.0\.1|localhost):\d+$/.test(host ?? "") &&
    origin === `http://${host}`
  );
}
