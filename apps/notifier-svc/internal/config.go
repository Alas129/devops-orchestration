package notifier

import (
	"errors"
	"os"
)

type Config struct {
	ListenAddr string
	DBHost     string
	DBPort     string
	DBName     string
	DBUser     string
	DBPassword string
	UseIAMAuth bool
	AWSRegion  string
	NATSURL    string
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
		NATSURL:    getenv("NATS_URL", "nats://nats.messaging.svc.cluster.local:4222"),
	}
	if cfg.DBHost == "" || cfg.DBName == "" || cfg.DBUser == "" {
		return nil, errors.New("DB_HOST/DB_NAME/DB_USER required")
	}
	return cfg, nil
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
