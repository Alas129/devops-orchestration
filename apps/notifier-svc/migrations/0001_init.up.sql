CREATE SCHEMA IF NOT EXISTS notifier;

CREATE TABLE IF NOT EXISTS notifier.notifications (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL,
    kind       TEXT NOT NULL,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifier.notifications (user_id);

ALTER ROLE CURRENT_USER SET search_path = notifier, public;
