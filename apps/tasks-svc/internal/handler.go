package tasksvc

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
)

type Task struct {
	ID        int64     `json:"id"`
	UserID    int64     `json:"user_id"`
	Name      string    `json:"name"`
	Done      bool      `json:"done"`
	CreatedAt time.Time `json:"created_at"`
}

func (a *App) listTasks(w http.ResponseWriter, r *http.Request) {
	uid := userID(r.Context())
	rows, err := a.db.Query(r.Context(),
		`SELECT id, user_id, name, done, created_at FROM tasks WHERE user_id=$1 ORDER BY id DESC LIMIT 200`, uid)
	if err != nil {
		http.Error(w, "db", 500)
		return
	}
	defer rows.Close()
	out := []Task{}
	for rows.Next() {
		var t Task
		if err := rows.Scan(&t.ID, &t.UserID, &t.Name, &t.Done, &t.CreatedAt); err != nil {
			http.Error(w, "scan", 500)
			return
		}
		out = append(out, t)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

type createReq struct {
	Name string `json:"name"`
}

func (a *App) createTask(w http.ResponseWriter, r *http.Request) {
	uid := userID(r.Context())
	var req createReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		http.Error(w, "bad body", 400)
		return
	}
	var t Task
	err := a.db.QueryRow(r.Context(),
		`INSERT INTO tasks (user_id, name) VALUES ($1, $2)
		 RETURNING id, user_id, name, done, created_at`,
		uid, req.Name).Scan(&t.ID, &t.UserID, &t.Name, &t.Done, &t.CreatedAt)
	if err != nil {
		http.Error(w, "db", 500)
		return
	}
	a.publish("tasks.created", t)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(201)
	_ = json.NewEncoder(w).Encode(t)
}

type updateReq struct {
	Name *string `json:"name,omitempty"`
	Done *bool   `json:"done,omitempty"`
}

func (a *App) updateTask(w http.ResponseWriter, r *http.Request) {
	uid := userID(r.Context())
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		http.Error(w, "bad id", 400)
		return
	}
	var req updateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad body", 400)
		return
	}
	var t Task
	err = a.db.QueryRow(r.Context(),
		`UPDATE tasks SET
		  name = COALESCE($3, name),
		  done = COALESCE($4, done)
		 WHERE id=$1 AND user_id=$2
		 RETURNING id, user_id, name, done, created_at`,
		id, uid, req.Name, req.Done).Scan(&t.ID, &t.UserID, &t.Name, &t.Done, &t.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		http.Error(w, "not found", 404)
		return
	}
	if err != nil {
		http.Error(w, "db", 500)
		return
	}
	a.publish("tasks.updated", t)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(t)
}

func (a *App) deleteTask(w http.ResponseWriter, r *http.Request) {
	uid := userID(r.Context())
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		http.Error(w, "bad id", 400)
		return
	}
	cmd, err := a.db.Exec(r.Context(), `DELETE FROM tasks WHERE id=$1 AND user_id=$2`, id, uid)
	if err != nil {
		http.Error(w, "db", 500)
		return
	}
	if cmd.RowsAffected() == 0 {
		http.Error(w, "not found", 404)
		return
	}
	w.WriteHeader(204)
}
