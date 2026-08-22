package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"server/internal/db"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"server/internal/api"
)

func main() {

	//экспортируем переменные окружения из файла .env в системные переменные окружения
	var env_error = godotenv.Load()

	//если произошла ошибка при загрузке переменных окружения, то выводим сообщение об ошибке и выходим из программы с кодом 1
	if env_error != nil {
		log.Fatalf("ошибка загрузки переменных окружения из файла .env: %v", env_error)
	}

	//создание нового подключения к постгре с использованием переменной окружения DATABASE_URL. pgxpool.New возвращает два значения: объект подключения и ошибку подключения
	var pg_connect, pg_con_error = pgxpool.New(context.Background(), os.Getenv("DATABASE_URL"))

	//проверка подключения к базе данных. Если произошла ошибка, то выводим сообщение об ошибке и выходим из программы с кодом 1
	if pg_con_error != nil {
		log.Fatalf("ошибка подключения к базе данных: %v", pg_con_error)
	}

	//подключаемся к бд
	var queries = db.New(pg_connect)

	//закрытие соединения с базой данных ПОСЛЕ того, как main завершит свою работу
	//defer - это ключевое слово, которое откладывает выполнение функции до тех пор, пока не завершится выполнение функции, где был написан defer
	defer pg_connect.Close()

	//Подключаемся к MinIO серверу. Он нужен будет для загрузки медиа файлов, которые будут храниться в MinIO, а не в базе данных. MinIO - это объектное хранилище
	var minioClient, minioErr = minio.New(os.Getenv("MINIO_ENDPOINT"), &minio.Options{
		Creds:  credentials.NewStaticV4(os.Getenv("MINIO_ACCESS_KEY"), os.Getenv("MINIO_SECRET_KEY"), ""),
		Secure: false,
	})

	//Проверка подключения к MinIO серверу
	if minioErr != nil {
		log.Fatalf("ошибка подключения к MinIO: %v", minioErr)
	}

	//создание переменной, в которой будет храниться записи о всех подключенных пользователях к серверу. У это переменной есть свои методы, описанные в registry.go
	var registry = api.NewConnectionRegistry()

	//создаем свою таблицу маршрутов (mux) для обработки HTTP-запросов
	var mux = http.NewServeMux()

	//подтверждение доставки
	var ackRegistry = api.NewAckRegistry()

	//очередь отложенных (ещё не доставленных) звонков для оффлайн-получателей
	var pendingCalls = api.NewPendingCallRegistry()

	//rate-limit по IP на /login — раньше от перебора паролей были защищены
	//только коды восстановления, сам вход в аккаунт — нет
	var loginLimiter = api.NewLoginRateLimiter()

	/*
	  mux.HandleFunc - принимает на вход строку и функцию, тем самым сопоставляя моршрут.
	  То есть если через http пришло что-то вроде /qwsdfg ты мы этому значению сопоставляем функцию, которую нужно вызвать
	*/
	mux.HandleFunc("GET /health", api.NewHealthHandler(queries))
	mux.HandleFunc("GET /ws", api.NewWebSocketHandler(queries, registry, ackRegistry, pendingCalls))
	mux.HandleFunc("POST /register", api.NewRegisterHandler(queries, pg_connect))
	mux.HandleFunc("POST /verify-totp", api.NewVerifyTOTPHandler(queries))
	mux.HandleFunc("POST /login", api.NewLoginHandler(queries, loginLimiter))
	mux.HandleFunc("POST /register-device", api.NewRegisterDeviceHandler(queries, registry))
	mux.HandleFunc("POST /prekeys/upload", api.NewUploadPrekeysHandler(queries))
	mux.HandleFunc("GET /devices/{device_id}/prekey-bundle", api.NewGetPrekeyBundleHandler(queries))
	mux.HandleFunc("GET /accounts/{login}/devices", api.NewGetDevicesByLoginHandler(queries))
	mux.HandleFunc("GET /devices/{device_id}/owner", api.NewGetDeviceOwnerHandler(queries))
	mux.HandleFunc("POST /upload-media", api.NewUploadMediaHandler(queries, minioClient))
	mux.HandleFunc("GET /media/{id}", api.NewGetMediaHandler(queries, minioClient))
	mux.HandleFunc("GET /session/check", api.NewSessionCheckHandler(queries))
	mux.HandleFunc("DELETE /account", api.NewDeleteAccountHandler(queries))
	mux.HandleFunc("GET /account/me", api.NewAccountMeHandler(queries))
	mux.HandleFunc("GET /turn-credentials", api.NewTurnCredentialsHandler(queries))
	mux.HandleFunc("POST /push/register", api.NewRegisterPushTokenHandler(queries))
	mux.HandleFunc("DELETE /push/register", api.NewUnregisterPushTokenHandler(queries))
	mux.HandleFunc("POST /calls/decline", api.NewDeclineCallHandler(queries, registry, pendingCalls))
	mux.HandleFunc("PUT /account/language", api.NewUpdateLanguageHandler(queries))
	mux.HandleFunc("PUT /account/email", api.NewUpdateEmailHandler(queries))
	mux.HandleFunc("POST /account/email/request", api.NewRequestEmailVerificationHandler(queries))
	mux.HandleFunc("POST /account/email/confirm", api.NewConfirmEmailVerificationHandler(queries))
	mux.HandleFunc("POST /account/avatar", api.NewUploadAvatarHandler(queries, minioClient, registry))
	mux.HandleFunc("DELETE /account/avatar", api.NewDeleteAvatarHandler(queries, minioClient, registry))
	mux.HandleFunc("GET /account/avatar", api.NewGetMyAvatarHandler(queries, minioClient))
	mux.HandleFunc("GET /account/avatar/{account_id}", api.NewGetAvatarHandler(queries, minioClient))
	mux.HandleFunc("PUT /account/status", api.NewUpdateStatusHandler(queries, registry))
	mux.HandleFunc("PUT /account/birthday", api.NewUpdateBirthdayHandler(queries, registry))
	mux.HandleFunc("PUT /account/privacy", api.NewUpdatePrivacyHandler(queries))
	mux.HandleFunc("GET /account/profile/{login}", api.NewGetAccountProfileHandler(queries))
	mux.HandleFunc("POST /chats/mute", api.NewMuteChatHandler(queries))
	mux.HandleFunc("POST /chats/unmute", api.NewUnmuteChatHandler(queries))
	mux.HandleFunc("GET /chats/muted", api.NewGetMutedChatsHandler(queries))
	mux.HandleFunc("POST /account/recover/request", api.NewRecoverRequestHandler(queries))
	mux.HandleFunc("POST /account/recover/verify", api.NewRecoverVerifyHandler(queries))
	mux.HandleFunc("POST /account/recover/reset", api.NewRecoverResetHandler(queries))
	mux.HandleFunc("PUT /account/password", api.NewChangePasswordHandler(queries))
	mux.HandleFunc("POST /contacts/block", api.NewBlockContactHandler(queries, registry))
	mux.HandleFunc("POST /contacts/unblock", api.NewUnblockContactHandler(queries, registry))
	mux.HandleFunc("GET /contacts/blocked", api.NewGetBlockedContactsHandler(queries))
	mux.HandleFunc("POST /reports", api.NewReportHandler(queries))
	mux.HandleFunc("POST /feedback", api.NewFeedbackHandler(queries))

	//сохраняем в переменную и запускаем HTTP-сервер на порту 8080. ListenAndServe - блокирующая функция, которая будет работать до тех пор, пока сервер не будет остановлен или не произойдет ошибка
	//внутри запускается бесконечный цикл, который как раз через mux проверяет, какие запросы пришли и вызывает в горутине (параллельно) соответствующие функции-обработчики, а сам цикл продолжает работать и ждать новых запросов
	var server_error = http.ListenAndServe(":8080", mux)

	//если сервер не запустился, то выводим сообщение об ошибке и выходим с кодом 1
	if server_error != nil {
		log.Fatalf("ошибка запуска сервера на порту 8080: %v", server_error)
	}

}
