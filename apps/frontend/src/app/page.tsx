"use client";

import { useEffect, useState } from "react";

type Task = {
  id: number;
  name: string;
  done: boolean;
  created_at: string;
};

export default function Home() {
  const [token, setToken] = useState<string | null>(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [tasks, setTasks] = useState<Task[]>([]);
  const [newTask, setNewTask] = useState("");
  const [toasts, setToasts] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const stored = typeof window !== "undefined" ? localStorage.getItem("token") : null;
    if (stored) setToken(stored);
  }, []);

  useEffect(() => {
    if (!token) return;
    fetch("/api/tasks/tasks", { headers: { Authorization: `Bearer ${token}` } })
      .then((r) => (r.ok ? r.json() : []))
      .then((data) => setTasks(data ?? []))
      .catch(() => {});
    const es = new EventSource("/api/notifier/notifications/stream");
    es.onmessage = (e) => setToasts((t) => [e.data, ...t].slice(0, 5));
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
    setToken(data.token);
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
      <form onSubmit={addTask} className="flex gap-3">
        <input
          value={newTask}
          onChange={(e) => setNewTask(e.target.value)}
          placeholder="What needs doing?"
          className="flex-1 rounded-lg border border-slate-700 bg-slate-900/60 px-4 py-2 outline-none focus:border-accent"
        />
        <button className="rounded-lg bg-accent px-5 py-2 font-medium hover:bg-accent/80">Add</button>
      </form>

      <ul className="space-y-2">
        {tasks.length === 0 && (
          <li className="rounded-lg border border-dashed border-slate-800 p-8 text-center text-sm text-slate-500">
            No tasks yet — add one above.
          </li>
        )}
        {tasks.map((t) => (
          <li
            key={t.id}
            className="flex items-center gap-3 rounded-lg border border-slate-800 bg-slate-900/40 px-4 py-3"
          >
            <input
              type="checkbox"
              checked={t.done}
              onChange={() => toggle(t)}
              className="h-5 w-5 cursor-pointer accent-accent"
            />
            <span className={t.done ? "flex-1 text-slate-500 line-through" : "flex-1"}>{t.name}</span>
            <span className="text-xs text-slate-500">{new Date(t.created_at).toLocaleString()}</span>
          </li>
        ))}
      </ul>

      <div className="fixed bottom-6 right-6 space-y-2">
        {toasts.map((t, i) => (
          <div
            key={i}
            className="rounded-lg border border-purple-700/50 bg-purple-950/80 px-4 py-2 text-sm text-purple-100 shadow-lg backdrop-blur"
          >
            {t}
          </div>
        ))}
      </div>
    </div>
  );
}
