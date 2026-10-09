// 集中引用界面依赖。
export { useState, useEffect } from "react";
export type { ReactNode } from "react";
export { createRoot } from "react-dom/client";
export {
  QueryClient,
  QueryClientProvider,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
export {
  HashRouter,
  NavLink,
  Routes,
  Route,
  Navigate,
  useLocation,
  useNavigate,
} from "react-router-dom";
export {
  Alert,
  Button,
  ConfigProvider,
  Drawer,
  Empty,
  Input,
  Modal,
  Progress,
  Select,
  Skeleton,
  Table,
  Tabs,
  Tooltip as Tip,
  theme,
} from "antd";
export type { TableColumnsType, TableProps } from "antd";
export { default as zhCN } from "antd/locale/zh_CN";
export {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
