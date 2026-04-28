package authsvc

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrNotFound = errors.New("not found")

type User struct {
	ID           int64
	Email        string
	PasswordHash string
	CreatedAt    time.Time
}

type Store struct {
	Pool *pgxpool.Pool
}

func (s *Store) CreateUser(ctx context.Context, email, passwordHash string) (*User, error) {
	const q = `INSERT INTO users (email, password_hash) VALUES ($1, $2)
	           RETURNING id, email, password_hash, created_at`
	u := &User{}
	if err := s.Pool.QueryRow(ctx, q, email, passwordHash).Scan(
		&u.ID, &u.Email, &u.PasswordHash, &u.CreatedAt,
	); err != nil {
		return nil, err
	}
	return u, nil
}

func (s *Store) FindByEmail(ctx context.Context, email string) (*User, error) {
	const q = `SELECT id, email, password_hash, created_at FROM users WHERE email = $1`
	u := &User{}
	err := s.Pool.QueryRow(ctx, q, email).Scan(
		&u.ID, &u.Email, &u.PasswordHash, &u.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return u, nil
}

func (s *Store) GetUser(ctx context.Context, id int64) (*User, error) {
	const q = `SELECT id, email, password_hash, created_at FROM users WHERE id = $1`
	u := &User{}
	err := s.Pool.QueryRow(ctx, q, id).Scan(
		&u.ID, &u.Email, &u.PasswordHash, &u.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return u, err
}
