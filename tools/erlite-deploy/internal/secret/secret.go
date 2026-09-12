// Package secret generates local random credentials for the "generate"
// adminCredentialSource option. It never contacts anything external.
package secret

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// Token returns a hex-encoded random token with n bytes of entropy.
func Token(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating random token: %w", err)
	}
	return hex.EncodeToString(b), nil
}
