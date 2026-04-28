package authsvc

import (
	"errors"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type Tokens struct {
	Secret []byte
	Issuer string
	TTL    time.Duration
}

func (t *Tokens) Issue(userID int64) (string, error) {
	claims := jwt.RegisteredClaims{
		Subject:   strconv.FormatInt(userID, 10),
		Issuer:    t.Issuer,
		IssuedAt:  jwt.NewNumericDate(time.Now()),
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(t.TTL)),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return tok.SignedString(t.Secret)
}

func (t *Tokens) Parse(tokenStr string) (int64, error) {
	parsed, err := jwt.ParseWithClaims(tokenStr, &jwt.RegisteredClaims{}, func(tk *jwt.Token) (interface{}, error) {
		if tk.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("unexpected signing method")
		}
		return t.Secret, nil
	}, jwt.WithIssuer(t.Issuer), jwt.WithExpirationRequired())
	if err != nil {
		return 0, err
	}
	claims, ok := parsed.Claims.(*jwt.RegisteredClaims)
	if !ok || !parsed.Valid {
		return 0, errors.New("invalid token")
	}
	return strconv.ParseInt(claims.Subject, 10, 64)
}
