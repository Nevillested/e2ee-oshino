package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

// APNs — пуши на iOS. Как и FCM, это только сигнал "подключись к серверу":
// ни отправителя, ни текста в пуше нет. Уведомление о сообщении — общий
// текст из строк самого приложения (loc-key), звонок — VoIP-пуш (PushKit),
// по нему iOS сразу показывает экран CallKit, а сам offer приложение
// забирает по WebSocket из PendingCallRegistry.
//
// Ключ — токен-аутентификация (.p8 из Apple Developer), переменные окружения:
// APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (bundle id приложения).
// Не заданы — APNs выключен, сервер работает как прежде.

const (
	apnsProductionHost = "https://api.push.apple.com"
	apnsSandboxHost    = "https://api.sandbox.push.apple.com"
	// Apple принимает JWT не старше часа и не чаще обновления раз в 20 минут.
	apnsJWTLifetime = 50 * time.Minute
	// Звонок, не доставленный за это время, показывать уже поздно.
	apnsCallExpiration = 60 * time.Second
)

// APNsResult — итог отправки. Gone — токен больше не действует (приложение
// удалено, токен от другой сборки): его надо забыть.
type APNsResult struct {
	Gone bool
}

type apnsClient struct {
	keyID   string
	teamID  string
	topic   string
	key     *ecdsa.PrivateKey
	http    *http.Client
	hosts   [2]string // [production, sandbox] — подменяются в тестах
	now     func() time.Time
	mu      sync.Mutex
	jwt     string
	jwtTime time.Time
}

var (
	apnsOnce     sync.Once
	apnsInstance *apnsClient
)

func getAPNs() *apnsClient {
	apnsOnce.Do(func() {
		keyPath, keyID, teamID, topic := os.Getenv("APNS_KEY_PATH"), os.Getenv("APNS_KEY_ID"), os.Getenv("APNS_TEAM_ID"), os.Getenv("APNS_TOPIC")
		if keyPath == "" || keyID == "" || teamID == "" || topic == "" {
			log.Printf("push: APNS_KEY_PATH/APNS_KEY_ID/APNS_TEAM_ID/APNS_TOPIC не заданы — пуши iOS отключены")
			return
		}
		pemBytes, err := os.ReadFile(keyPath)
		if err != nil {
			log.Printf("push: не удалось прочитать ключ APNs: %v", err)
			return
		}
		key, err := parseAPNsKey(pemBytes)
		if err != nil {
			log.Printf("push: ключ APNs не разобран: %v", err)
			return
		}
		apnsInstance = newAPNsClient(key, keyID, teamID, topic)
		log.Printf("push: APNs-клиент инициализирован (topic=%s)", topic)
	})
	return apnsInstance
}

func newAPNsClient(key *ecdsa.PrivateKey, keyID, teamID, topic string) *apnsClient {
	return &apnsClient{
		keyID: keyID, teamID: teamID, topic: topic, key: key,
		// HTTP/2 Go включает сам (TLS + ALPN) — APNs принимает только его.
		http:  &http.Client{Timeout: 15 * time.Second},
		hosts: [2]string{apnsProductionHost, apnsSandboxHost},
		now:   time.Now,
	}
}

// parseAPNsKey — .p8 из Apple Developer: PEM с PKCS#8 ключом P-256.
func parseAPNsKey(pemBytes []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return nil, errors.New("нет PEM-блока")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("ключ не ECDSA")
	}
	return key, nil
}

// token — JWT провайдера (ES256), переиспользуется до apnsJWTLifetime.
func (c *apnsClient) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.jwt != "" && now.Sub(c.jwtTime) < apnsJWTLifetime {
		return c.jwt, nil
	}
	enc := base64.RawURLEncoding
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.keyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.teamID, "iat": now.Unix()})
	signing := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signing))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS: r и s — по 32 байта подряд (не DER)
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.jwt = signing + "." + enc.EncodeToString(sig)
	c.jwtTime = now
	return c.jwt, nil
}

type apnsRequest struct {
	pushType   string // alert | voip | background
	topic      string
	priority   int
	expiration time.Time // нулевое — "не хранить, если устройство недоступно"
	collapseID string
	payload    map[string]any
}

// apnsRequestFor — что и как отправить для данного типа пуша.
func (c *apnsClient) apnsRequestFor(pushType PushType, extra map[string]string) apnsRequest {
	payload := map[string]any{"type": string(pushType)}
	for k, v := range extra {
		payload[k] = v
	}
	switch pushType {
	case TypeCall:
		// VoIP: iOS обязана тут же показать звонок через CallKit (иначе
		// перестанет будить приложение) — поэтому VoIP только для звонка.
		return apnsRequest{pushType: "voip", topic: c.topic + ".voip", priority: 10,
			expiration: c.now().Add(apnsCallExpiration), payload: payload}
	case TypeCallCancel:
		// Отмена — фоновый пуш: если приложение ещё не подключилось, оно
		// закроет экран CallKit само (звонок без offer по WebSocket).
		payload["aps"] = map[string]any{"content-available": 1}
		return apnsRequest{pushType: "background", topic: c.topic, priority: 5, payload: payload}
	default:
		// Сообщение: общий текст из строк приложения + разбудить, чтобы
		// забрало очередь. Одно уведомление на все непрочитанные (collapse).
		payload["aps"] = map[string]any{
			"alert":             map[string]any{"loc-key": "push_newMessageBody"},
			"sound":             "default",
			"content-available": 1,
			"thread-id":         "messages",
		}
		return apnsRequest{pushType: "alert", topic: c.topic, priority: 10,
			expiration: c.now().Add(24 * time.Hour), collapseID: "new-message", payload: payload}
	}
}

func (c *apnsClient) send(ctx context.Context, deviceToken string, sandbox bool, req apnsRequest) (APNsResult, error) {
	jwt, err := c.token()
	if err != nil {
		return APNsResult{}, err
	}
	body, err := json.Marshal(req.payload)
	if err != nil {
		return APNsResult{}, err
	}
	host := c.hosts[0]
	if sandbox {
		host = c.hosts[1]
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+deviceToken, bytes.NewReader(body))
	if err != nil {
		return APNsResult{}, err
	}
	httpReq.Header.Set("authorization", "bearer "+jwt)
	httpReq.Header.Set("apns-topic", req.topic)
	httpReq.Header.Set("apns-push-type", req.pushType)
	httpReq.Header.Set("apns-priority", strconv.Itoa(req.priority))
	exp := "0"
	if !req.expiration.IsZero() {
		exp = strconv.FormatInt(req.expiration.Unix(), 10)
	}
	httpReq.Header.Set("apns-expiration", exp)
	if req.collapseID != "" {
		httpReq.Header.Set("apns-collapse-id", req.collapseID)
	}
	resp, err := c.http.Do(httpReq)
	if err != nil {
		return APNsResult{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return APNsResult{}, nil
	}
	var reason struct {
		Reason string `json:"reason"`
	}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	_ = json.Unmarshal(raw, &reason)
	switch {
	case resp.StatusCode == http.StatusGone,
		reason.Reason == "BadDeviceToken", reason.Reason == "DeviceTokenNotForTopic", reason.Reason == "Unregistered":
		return APNsResult{Gone: true}, fmt.Errorf("APNs %d %s", resp.StatusCode, reason.Reason)
	case resp.StatusCode == http.StatusForbidden && reason.Reason == "ExpiredProviderToken":
		c.mu.Lock()
		c.jwt = "" // следующая отправка подпишет новый
		c.mu.Unlock()
	}
	return APNsResult{}, fmt.Errorf("APNs %d %s", resp.StatusCode, reason.Reason)
}

// SendAPNs шлёт пуш на iOS-устройство. Как и SendDataPush, ошибки только
// логируются; Gone — токен надо удалить из базы.
func SendAPNs(ctx context.Context, deviceToken string, sandbox bool, pushType PushType, extra map[string]string) APNsResult {
	if deviceToken == "" {
		return APNsResult{}
	}
	c := getAPNs()
	if c == nil {
		return APNsResult{}
	}
	res, err := c.send(ctx, deviceToken, sandbox, c.apnsRequestFor(pushType, extra))
	if err != nil {
		log.Printf("push: ошибка отправки APNs (%s): %v", pushType, err)
	}
	return res
}
