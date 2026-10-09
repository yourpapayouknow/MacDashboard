// 语言分类只匹配明确的软件或运行时标识。
export const languages = [
  { id: "python", label: "Python", icon: "python" },
  { id: "node", label: "Node.js", icon: "nodejs" },
  { id: "java", label: "Java", icon: "java" },
  { id: "go", label: "Go", icon: "go" },
  { id: "cpp", label: "C/C++", icon: "cplusplus" },
  { id: "rust", label: "Rust", icon: "rust" },
  { id: "swift", label: "Swift", icon: "swift" },
  { id: "ruby", label: "Ruby", icon: "ruby" },
  { id: "perl", label: "Perl", icon: "perl" },
];

// Homebrew完整标识保留操作目标，分类只读取最后一段。
export function envgrp(id) {
  const name = id.split("/").at(-1).toLowerCase();
  if (/^(python|pypy)(@|\d|$)/.test(name) || ["uv", "pipx", "poetry"].includes(name)) return "python";
  if (/^node(@|$)/.test(name) || ["npm", "pnpm", "yarn"].includes(name)) return "node";
  if (/^(openjdk|temurin|java)(@|$)/.test(name)) return "java";
  if (["gradle", "maven"].includes(name)) return "java";
  if (/^(gcc|llvm|clang)(@|$)/.test(name)) return "cpp";
  return languages.find(({ id: tool }) => new RegExp(`^${tool}(@|$)`).test(name))?.id ?? "formulae";
}
