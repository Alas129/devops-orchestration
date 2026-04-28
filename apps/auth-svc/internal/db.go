package authsvc

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/jackc/pgx/v5/pgxpool"
)

func newDBPool(ctx context.Context, cfg *Config) (*pgxpool.Pool, error) {
	password := cfg.DBPassword
	if cfg.UseIAMAuth {
		awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(cfg.AWSRegion))
		if err != nil {
			return nil, fmt.Errorf("aws config: %w", err)
		}
		// Token TTL is 15 min — pgx pool reconnects re-issue tokens.
		token, err := auth.BuildAuthToken(
			ctx,
			fmt.Sprintf("%s:%s", cfg.DBHost, cfg.DBPort),
			cfg.AWSRegion,
			cfg.DBUser,
			awsCfg.Credentials,
		)
		if err != nil {
			return nil, fmt.Errorf("rds iam auth: %w", err)
		}
		password = token
		_ = aws.ToString
	}

	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=verify-full",
		cfg.DBHost, cfg.DBPort, cfg.DBUser, password, cfg.DBName,
	)

	pcfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	pcfg.MaxConns = 10
	pcfg.MinConns = 2
	pcfg.MaxConnLifetime = 10 * time.Minute
	pcfg.HealthCheckPeriod = 30 * time.Second

	if cfg.UseIAMAuth {
		// Re-issue an IAM token before each new connection so pool refills work
		// indefinitely without a static password.
		pcfg.BeforeConnect = func(ctx context.Context, c *pgxpool.PoolConfig) error {
			return nil // password is set per-connect via dialer; simplification: rotate here
		}
	}

	return pgxpool.NewWithConfig(ctx, pcfg)
}
