package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testClient(t *testing.T, handler http.HandlerFunc) (*apnsClient, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	c := newAPNsClient(key, "KEY123", "TEAM456", "com.oshinobu.app")
	c.hosts = [2]string{srv.URL + "/prod", srv.URL + "/sandbox"}
	return c, key
}

func verifyJWT(t *testing.T, jwt string, pub *ecdsa.PublicKey) map[string]any {
	t.Helper()
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatalf("JWT из %d частей", len(parts))
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		t.Fatalf("подпись: %v, длина %d", err, len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("подпись JWT не сходится")
	}
	var header map[string]any
	raw, _ := base64.RawURLEncoding.DecodeString(parts[0])
	_ = json.Unmarshal(raw, &header)
	if header["alg"] != "ES256" || header["kid"] != "KEY123" {
		t.Fatalf("заголовок JWT: %v", header)
	}
	var claims map[string]any
	raw, _ = base64.RawURLEncoding.DecodeString(parts[1])
	_ = json.Unmarshal(raw, &claims)
	return claims
}

func TestAPNsCallIsVoIPWithSignedJWT(t *testing.T) {
	var got *http.Request
	var body map[string]any
	c, key := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		got = r
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
	})
	res, err := c.send(context.Background(), "abcdef", true, c.apnsRequestFor(TypeCall, map[string]string{"call_id": "c1"}))
	if err != nil || res.Gone {
		t.Fatalf("send: %v %v", res, err)
	}
	if got.URL.Path != "/sandbox/3/device/abcdef" {
		t.Fatalf("путь: %s", got.URL.Path)
	}
	if got.Header.Get("apns-push-type") != "voip" || got.Header.Get("apns-topic") != "com.oshinobu.app.voip" || got.Header.Get("apns-priority") != "10" {
		t.Fatalf("заголовки: %v", got.Header)
	}
	if body["type"] != "call" || body["call_id"] != "c1" {
		t.Fatalf("тело: %v", body)
	}
	if _, hasAps := body["aps"]; hasAps {
		t.Fatal("в VoIP-пуше не должно быть aps")
	}
	claims := verifyJWT(t, strings.TrimPrefix(got.Header.Get("authorization"), "bearer "), &key.PublicKey)
	if claims["iss"] != "TEAM456" {
		t.Fatalf("claims: %v", claims)
	}
}

func TestAPNsMessageAlertWithoutContent(t *testing.T) {
	var got *http.Request
	var body map[string]any
	c, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		got = r
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
	})
	if _, err := c.send(context.Background(), "ff", false, c.apnsRequestFor(TypeMessage, nil)); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got.URL.Path, "/prod/") || got.Header.Get("apns-push-type") != "alert" || got.Header.Get("apns-topic") != "com.oshinobu.app" {
		t.Fatalf("запрос: %s %v", got.URL.Path, got.Header)
	}
	aps := body["aps"].(map[string]any)
	alert := aps["alert"].(map[string]any)
	if alert["loc-key"] != "push_newMessageBody" || len(alert) != 1 {
		t.Fatalf("alert должен быть только общим текстом приложения: %v", alert)
	}
}

func TestAPNsGoneToken(t *testing.T) {
	c, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"reason":"BadDeviceToken"}`))
	})
	res, err := c.send(context.Background(), "ab", false, c.apnsRequestFor(TypeMessage, nil))
	if err == nil || !res.Gone {
		t.Fatalf("ожидался Gone: %v %v", res, err)
	}
}

func TestAPNsJWTReusedThenRefreshed(t *testing.T) {
	c, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {})
	now := time.Unix(1_800_000_000, 0)
	c.now = func() time.Time { return now }
	first, _ := c.token()
	now = now.Add(10 * time.Minute)
	if again, _ := c.token(); again != first {
		t.Fatal("JWT должен переиспользоваться")
	}
	now = now.Add(time.Hour)
	if fresh, _ := c.token(); fresh == first {
		t.Fatal("старый JWT должен обновиться")
	}
}

func TestParseAPNsKey(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	parsed, err := parseAPNsKey(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	if err != nil || !parsed.Equal(key) {
		t.Fatalf("parse: %v", err)
	}
}
