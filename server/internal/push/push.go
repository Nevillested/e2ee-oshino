package push

import (
	"context"
	"log"
	"os"
	"sync"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"google.golang.org/api/option"
)

// PushType — тип push-уведомления. Пуш нужен ТОЛЬКО как сигнал разбудить
// приложение и заставить его подключиться к нашему серверу — само тело
// пуша сознательно не содержит ничего осмысленного (ни отправителя, ни
// текста сообщения): реальные данные идут только через собственный
// зашифрованный канал приложения (WebSocket), Google в этой схеме не
// видит содержимого переписки.
type PushType string

const (
	TypeMessage PushType = "message"
	// TypeCallCancel — звонящий передумал ждать до того, как получатель
	// успел подключиться (см. PendingCallRegistry.Cancel). Получатель к
	// этому моменту уже мог показать нативный экран/рингтон по TypeCall —
	// этот пуш просит его остановиться, не дожидаясь TTL.
	TypeCallCancel PushType = "call_cancel"
	TypeCall       PushType = "call"
)

var (
	clientOnce sync.Once
	client     *messaging.Client
)

// getClient лениво инициализирует Firebase Messaging клиент из файла
// сервисного аккаунта, путь к которому задаётся переменной окружения
// FCM_CREDENTIALS_PATH. Если она не задана (или файл недоступен) — клиент
// остаётся nil, и отправка push просто молча пропускается: сервер обязан
// продолжать нормально работать и без настроенной push-инфраструктуры.
func getClient(ctx context.Context) *messaging.Client {
	clientOnce.Do(func() {
		credPath := os.Getenv("FCM_CREDENTIALS_PATH")
		if credPath == "" {
			log.Printf("push: FCM_CREDENTIALS_PATH не задан — push-уведомления отключены")
			return
		}

		app, err := firebase.NewApp(ctx, nil, option.WithCredentialsFile(credPath))
		if err != nil {
			log.Printf("push: ошибка инициализации Firebase App: %v", err)
			return
		}

		c, err := app.Messaging(ctx)
		if err != nil {
			log.Printf("push: ошибка инициализации Messaging-клиента: %v", err)
			return
		}

		client = c
		log.Printf("push: FCM-клиент инициализирован")
	})
	return client
}

// SendDataPush шлёт data-only push указанного типа на конкретный токен
// устройства. Ошибки логируются, но никогда не возвращаются наружу —
// недоставленный push не должен ронять основной поток (постановку
// сообщения в очередь, обработку сигнала звонка и т.д.).
func SendDataPush(ctx context.Context, token string, pushType PushType) {
	if token == "" {
		return
	}
	c := getClient(ctx)
	if c == nil {
		return
	}

	msg := &messaging.Message{
		Token: token,
		Data: map[string]string{
			"type": string(pushType),
		},
		Android: &messaging.AndroidConfig{
			// high — чтобы система доставила и разбудила приложение как
			// можно быстрее даже в Doze/App Standby; особенно важно для
			// звонков.
			Priority: "high",
		},
	}

	if _, err := c.Send(ctx, msg); err != nil {
		log.Printf("push: ошибка отправки push (%s): %v", pushType, err)
	}
}
