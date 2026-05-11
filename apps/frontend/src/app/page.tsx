"use client";

import { useEffect, useMemo, useState } from "react";

type Task = {
  id: number;
  name: string;
  done: boolean;
  created_at: string;
};

type Filter = "all" | "active" | "done";

export default function Home() {
  const [token, setToken] = useState<string | null>(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [tasks, setTasks] = useState<Task[]>([]);
  const [newTask, setNewTask] = useState("");
  const [toasts, setToasts] = useState<string[]>([]);
  const [filter, setFilter] = useState<Filter>("all");
  const [error, setError] = useState<string | null>(null);
  const [userEmail, setUserEmail] = useState<string | null>(null);

  useEffect(() => {
    const t = typeof window !== "undefined" ? localStorage.getItem("token") : null;
    const e = typeof window !== "undefined" ? localStorage.getItem("email") : null;
    if (t) setToken(t);
    if (e) setUserEmail(e);
  }, []);

  useEffect(() => {
    if (!token) return;
    fetch("/api/tasks/tasks", { headers: { Authorization: `Bearer ${token}` } })
      .then((r) => (r.ok ? r.json() : []))
      .then((data) => setTasks(data ?? []))
      .catch(() => {});
    const es = new EventSource("/api/notifier/notifications/stream");
    es.onmessage = (e) => setToasts((t) => [e.data, ...t].slice(0, 8));
    return () => es.close();
  }, [token]);

  async function login(e: React.FormEvent, signup = false) {
    e.preventDefault();
    setError(null);
    const res = await fetch(`/api/auth/${signup ? "signup" : "login"}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    if (!res.ok) {
      setError(await res.text());
      return;
    }
    const data = await res.json();
    localStorage.setItem("token", data.token);
    localStorage.setItem("email", email);
    setToken(data.token);
    setUserEmail(email);
  }

  function signOut() {
    localStorage.removeItem("token");
    localStorage.removeItem("email");
    setToken(null);
    setUserEmail(null);
    setTasks([]);
    setToasts([]);
  }

  async function addTask(e: React.FormEvent) {
    e.preventDefault();
    if (!newTask.trim() || !token) return;
    const res = await fetch("/api/tasks/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: newTask }),
    });
    if (res.ok) {
      const t = await res.json();
      setTasks((cur) => [t, ...cur]);
      setNewTask("");
    }
  }

  async function toggle(t: Task) {
    if (!token) return;
    const res = await fetch(`/api/tasks/tasks/${t.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ done: !t.done }),
    });
    if (res.ok) {
      const updated = await res.json();
      setTasks((cur) => cur.map((x) => (x.id === t.id ? updated : x)));
    }
  }

  async function remove(id: number) {
    if (!token) return;
    const res = await fetch(`/api/tasks/tasks/${id}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.ok || res.status === 204) {
      setTasks((cur) => cur.filter((x) => x.id !== id));
    }
  }

  const stats = useMemo(() => {
    const total = tasks.length;
    const done = tasks.filter((t) => t.done).length;
    const pending = total - done;
    const pct = total === 0 ? 0 : Math.round((done / total) * 100);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const since = today.getTime() - 6 * 86_400_000;
    const buckets = Array.from({ length: 7 }, (_, i) => {
      const day = new Date(since + i * 86_400_000);
      const next = new Date(day.getTime() + 86_400_000);
      return {
        label: day.toLocaleDateString(undefined, { weekday: "short" }),
        count: tasks.filter((t) => {
          const c = new Date(t.created_at).getTime();
          return c >= day.getTime() && c < next.getTime();
        }).length,
      };
    });
    const peak = Math.max(1, ...buckets.map((b) => b.count));
    return { total, done, pending, pct, buckets, peak };
  }, [tasks]);

  const filtered = useMemo(
    () =>
      tasks.filter((t) => (filter === "all" ? true : filter === "done" ? t.done : !t.done)),
    [tasks, filter],
  );

  if (!token) {
    return (
      <div className="rounded-2xl border border-slate-800 bg-slate-900/50 p-8 shadow-2xl backdrop-blur">
        <h1 className="mb-2 text-2xl font-semibold">Sign in</h1>
        <p className="mb-6 text-sm text-slate-400">
          Authenticate to start tracking tasks. Notifications stream in real time.
        </p>
        <form className="space-y-4">
          <input
            type="email"
            placeholder="Email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="w-full rounded-lg border border-slate-700 bg-slate-950 px-4 py-2 outline-none focus:border-accent"
          />
          <input
            type="password"
            placeholder="Password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full rounded-lg border border-slate-700 bg-slate-950 px-4 py-2 outline-none focus:border-accent"
          />
          {error && <p className="text-sm text-red-400">{error}</p>}
          <div className="flex gap-3">
            <button
              type="button"
              onClick={(e) => login(e as unknown as React.FormEvent, false)}
              className="flex-1 rounded-lg bg-accent px-4 py-2 font-medium text-white hover:bg-accent/80"
            >
              Sign in
            </button>
            <button
              type="button"
              onClick={(e) => login(e as unknown as React.FormEvent, true)}
              className="flex-1 rounded-lg border border-slate-700 px-4 py-2 hover:border-slate-600"
            >
              Sign up
            </button>
          </div>
        </form>
      </div>
    );
  }

  return (
    <div className="space-y-8">
      {/* user bar */}
      <div className="flex items-center justify-between rounded-xl border border-slate-800 bg-slate-900/40 px-4 py-3">
        <div className="flex items-center gap-3">
          <div className="flex h-9 w-9 items-center justify-center rounded-full bg-accent text-sm font-semibold text-white">
            {(userEmail ?? "?").slice(0, 1).toUpperCase()}
          </div>
          <div>
            <div className="text-sm font-medium">{userEmail ?? "signed in"}</div>
            <div className="text-xs text-slate-500">{stats.total} tasks tracked</div>
          </div>
        </div>
        <button
          onClick={signOut}
          className="text-xs text-slate-400 hover:text-slate-200"
        >
          Sign out
        </button>
      </div>

      {/* stats row */}
      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <StatCard label="Total" value={stats.total} accent="text-slate-100" />
        <StatCard label="Active" value={stats.pending} accent="text-amber-300" />
        <StatCard label="Completed" value={stats.done} accent="text-emerald-300" />
        <StatCard
          label="Done %"
          value={`${stats.pct}%`}
          accent="text-accent"
          progress={stats.pct}
        />
      </div>

      {/* main two-column area */}
      <div className="grid gap-6 md:grid-cols-3">
        <div className="space-y-4 md:col-span-2">
          {/* add task */}
          <form onSubmit={addTask} className="flex gap-3">
            <input
              value={newTask}
              onChange={(e) => setNewTask(e.target.value)}
              placeholder="What needs doing?"
              className="flex-1 rounded-lg border border-slate-700 bg-slate-900/60 px-4 py-2 outline-none focus:border-accent"
            />
            <button className="rounded-lg bg-accent px-5 py-2 font-medium hover:bg-accent/80">
              Add
            </button>
          </form>

          {/* filter tabs */}
          <div className="flex gap-2 text-sm">
            {(["all", "active", "done"] as Filter[]).map((f) => (
              <button
                key={f}
                onClick={() => setFilter(f)}
                className={
                  filter === f
                    ? "rounded-md bg-accent/20 px-3 py-1 text-accent ring-1 ring-accent/40"
                    : "rounded-md px-3 py-1 text-slate-400 hover:text-slate-200"
                }
              >
                {f === "all" ? `All (${stats.total})` : f === "active" ? `Active (${stats.pending})` : `Done (${stats.done})`}
              </button>
            ))}
          </div>

          {/* task list */}
          <ul className="space-y-2">
            {filtered.length === 0 && (
              <li className="rounded-lg border border-dashed border-slate-800 p-8 text-center text-sm text-slate-500">
                {tasks.length === 0
                  ? "No tasks yet — add one above."
                  : `No ${filter === "done" ? "completed" : "active"} tasks.`}
              </li>
            )}
            {filtered.map((t) => (
              <li
                key={t.id}
                className="group flex items-center gap-3 rounded-lg border border-slate-800 bg-slate-900/40 px-4 py-3 transition hover:border-slate-700"
              >
                <input
                  type="checkbox"
                  checked={t.done}
                  onChange={() => toggle(t)}
                  className="h-5 w-5 cursor-pointer accent-accent"
                />
                <span className={t.done ? "flex-1 text-slate-500 line-through" : "flex-1"}>
                  {t.name}
                </span>
                <span className="text-xs text-slate-500">{relativeTime(t.created_at)}</span>
                <button
                  onClick={() => remove(t.id)}
                  className="text-xs text-slate-500 opacity-0 transition group-hover:opacity-100 hover:text-red-400"
                  aria-label="Delete task"
                >
                  ✕
                </button>
              </li>
            ))}
          </ul>
        </div>

        {/* right side: activity chart + notifications */}
        <aside className="space-y-6">
          <div className="rounded-xl border border-slate-800 bg-slate-900/40 p-4">
            <div className="mb-3 flex items-baseline justify-between">
              <h3 className="text-sm font-medium">Activity — last 7 days</h3>
              <span className="text-xs text-slate-500">tasks created</span>
            </div>
            <div className="flex h-28 items-end gap-2">
              {stats.buckets.map((b, i) => {
                const h = b.count === 0 ? 4 : Math.max(8, (b.count / stats.peak) * 100);
                return (
                  <div key={i} className="flex flex-1 flex-col items-center gap-1">
                    <div
                      className={
                        "w-full rounded-t " +
                        (b.count === 0 ? "bg-slate-800" : "bg-gradient-to-t from-accent/40 to-accent")
                      }
                      style={{ height: `${h}%` }}
                      title={`${b.count} task${b.count === 1 ? "" : "s"} on ${b.label}`}
                    />
                    <span className="text-[10px] text-slate-500">{b.label}</span>
                  </div>
                );
              })}
            </div>
          </div>

          <div className="rounded-xl border border-slate-800 bg-slate-900/40 p-4">
            <div className="mb-3 flex items-center justify-between">
              <h3 className="text-sm font-medium">Live notifications</h3>
              <span className="flex items-center gap-1 text-xs text-emerald-400">
                <span className="h-2 w-2 animate-pulse rounded-full bg-emerald-400" />
                streaming
              </span>
            </div>
            {toasts.length === 0 ? (
              <p className="py-6 text-center text-xs text-slate-500">
                No events yet. Notifications appear here in real time as you create or update tasks.
              </p>
            ) : (
              <ul className="space-y-2">
                {toasts.map((t, i) => (
                  <li
                    key={i}
                    className="rounded-md border border-purple-700/30 bg-purple-950/40 px-3 py-2 text-xs text-purple-100"
                  >
                    {t}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </aside>
      </div>
    </div>
  );
}

function StatCard({
  label,
  value,
  accent,
  progress,
}: {
  label: string;
  value: number | string;
  accent: string;
  progress?: number;
}) {
  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900/40 p-4">
      <div className="text-xs uppercase tracking-wider text-slate-500">{label}</div>
      <div className={`mt-1 text-3xl font-semibold ${accent}`}>{value}</div>
      {progress !== undefined && (
        <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-slate-800">
          <div
            className="h-full bg-gradient-to-r from-accent/60 to-accent transition-all"
            style={{ width: `${progress}%` }}
          />
        </div>
      )}
    </div>
  );
}

function relativeTime(iso: string): string {
  const now = Date.now();
  const t = new Date(iso).getTime();
  const sec = Math.floor((now - t) / 1000);
  if (sec < 60) return "just now";
  if (sec < 3600) return `${Math.floor(sec / 60)}m ago`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ago`;
  return new Date(iso).toLocaleDateString();
}
