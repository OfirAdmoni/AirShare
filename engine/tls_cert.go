package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"strings"
	"time"
)

// generateSelfSignedCert builds an in-memory TLS certificate for local hub HTTPS.
// SAN includes 127.0.0.1, localhost, and [extraIPs] (e.g. detected Wi-Fi address).
func generateSelfSignedCert(extraIPs []net.IP) (tls.Certificate, string, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, "", err
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, "", err
	}

	ipSet := map[string]net.IP{
		"127.0.0.1": net.ParseIP("127.0.0.1").To4(),
	}
	for _, ip := range extraIPs {
		if ip4 := ip.To4(); ip4 != nil {
			ipSet[ip4.String()] = ip4
		}
	}
	ips := make([]net.IP, 0, len(ipSet))
	for _, ip := range ipSet {
		ips = append(ips, ip)
	}

	template := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "AirShare Hub",
			Organization: []string{"AirShare"},
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           ips,
		DNSNames:              []string{"localhost"},
	}

	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, "", err
	}

	sum := sha256.Sum256(der)
	pin := hex.EncodeToString(sum[:])
	return pair, pin, nil
}

func tlsConfigFromCert(pair tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{pair},
		MinVersion:   tls.VersionTLS12,
	}
}

func certPinPreview(pin string) string {
	pin = strings.TrimSpace(pin)
	if len(pin) <= 16 {
		return pin
	}
	return fmt.Sprintf("%s…", pin[:16])
}
