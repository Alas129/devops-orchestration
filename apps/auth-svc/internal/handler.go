package authsvc

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

type credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (a *App) healthz(w http.ResponseWriter, r *http.Request) {
	if err := a.db.Ping(r.Context()); err != nil {
		http.Error(w, "db unreachable", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (a *App) livez(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (a *App) signup(w http.ResponseWriter, r *http.Request) {
	var c credentials
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	if c.Email == "" || len(c.Password) < 8 {
		http.Error(w, "email and password (>=8 chars) required", http.StatusBadRequest)
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(c.Password), bcrypt.DefaultCost)
	if err != nil {
		http.Error(w, "hash failed", http.StatusInternalServerError)
		return
	}
	u, err := a.store.CreateUser(r.Context(), c.Email, string(hash))
	if err != nil {
		// duplicate emails surface as a constraint error — surface a 409.
		if strings.Contains(err.Error(), "duplicate key") {
			http.Error(w, "email already registered", http.StatusConflict)
			return
		}
		http.Error(w, "create user", http.StatusInternalServerError)
		return
	}
	a.issueAndRespond(w, u.ID)
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	var c credentials
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	u, err := a.store.FindByEmail(r.Context(), c.Email)
	if errors.Is(err, ErrNotFound) {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}
	if err != nil {
		http.Error(w, "db", http.StatusInternalServerError)
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(c.Password)); err != nil {
		http.Error(w, "invalid credentials", http.StatusUnauthorized)
		return
	}
	a.issueAndRespond(w, u.ID)
}

func (a *App) me(w http.ResponseWriter, r *http.Request) {
	authz := r.Header.Get("Authorization")
	tok := strings.TrimPrefix(authz, "Bearer ")
	if tok == authz || tok == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}
	uid, err := a.tokens.Parse(tok)
	if err != nil {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}
	u, err := a.store.GetUser(r.Context(), uid)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":    u.ID,
		"email": u.Email,
	})
}

func (a *App) issueAndRespond(w http.ResponseWriter, userID int64) {
	tok, err := a.tokens.Issue(userID)
	if err != nil {
		http.Error(w, "token issue", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"token":   tok,
		"user_id": userID,
	})
}
