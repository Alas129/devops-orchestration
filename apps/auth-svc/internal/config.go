package authsvc

import (
	"errors"
	"os"
	"time"
)

type Config struct {
	ListenAddr  string
	DBHost      string
	DBPort      string
	DBName      string
	DBUser      string
	DBPassword  string // empty when using IAM auth
	UseIAMAuth  bool
	AWSRegion   string
	JWTSecret   string
	JWTIssuer   string
	JWTTTL      time.Duration
}

func LoadConfig() (*Config, error) {
	cfg := &Config{
		ListenAddr: getenv("LISTEN_ADDR", ":8080"),
		DBHost:     os.Getenv("DB_HOST"),
		DBPort:     getenv("DB_PORT", "5432"),
		DBName:     os.Getenv("DB_NAME"),
		DBUser:     os.Getenv("DB_USER"),
		DBPassword: os.Getenv("DB_PASSWORD"),
		UseIAMAuth: os.Getenv("DB_IAM_AUTH") == "true",
		AWSRegion:  getenv("AWS_REGION", "us-east-1"),
		JWTSecret:  os.Getenv("JWT_SECRET"),
		JWTIssuer:  getenv("JWT_ISSUER", "auth-svc"),
		JWTTTL:     mustDuration(getenv("JWT_TTL", "1h")),
	}
	if cfg.DBHost == "" || cfg.DBName == "" || cfg.DBUser == "" {
		return nil, errors.New("DB_HOST, DB_NAME, DB_USER are required")
	}
	if cfg.JWTSecret == "" {
		return nil, errors.New("JWT_SECRET is required")
	}
	return cfg, nil
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustDuration(s string) time.Duration {
	d, err := time.ParseDuration(s)
	if err != nil {
		return time.Hour
	}
	return d
}
