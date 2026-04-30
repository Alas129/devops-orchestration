CREATE SCHEMA IF NOT EXISTS tasks;

CREATE TABLE IF NOT EXISTS tasks.tasks (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL,
    name       TEXT NOT NULL,
    done       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tasks_user ON tasks.tasks (user_id);

ALTER ROLE CURRENT_USER SET search_path = tasks, public;
