package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"server/internal/db"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"

	"server/internal/api"
)

func main() {

	//экспоортируем переменные окружения из файла .env в системные переменные окружения
	var env_error = godotenv.Load()

	//если произошла ошибка при загрузке переменных окружения, то выводим сообщение об ошибке и выходим из программы с кодом 1
	if env_error != nil {
		log.Fatalf("ошибка загрузки переменных окружения из файла .env: %v", env_error)
	}

	//создание нового подключения к пгsql базе данных с использованием переменной окружения DATABASE_URL. pgxpool.New возвращает два значения: объект подключения и ошибку подключения
	var pg_connect, pg_con_error = pgxpool.New(context.Background(), os.Getenv("DATABASE_URL"))

	//проверка подключения к базе данных. Если произошла ошибка, то выводим сообщение об ошибке и выходим из программы с кодом 1
	if pg_con_error != nil {
		log.Fatalf("ошибка подключения к базе данных: %v", pg_con_error)
	}

	var queries = db.New(pg_connect)

	//закрытие соединения с базой данных ПОСЛЕ того, как main завершит свою работу
	//defer - это ключевое слово, которое откладывает выполнение функции до тех пор, пока не завершится выполнение функции, где был написан defer
	defer pg_connect.Close()

	//создаем свою таблицу маршрутов (mux) для обработки HTTP-запросов
	var mux = http.NewServeMux()

	/*
	  mux.HandleFunc - принимает на вход строку и функцию, тем самым сопоставляя моршрут.
	  То есть если через http пришло что-то вроде /qwsdfg ты мы этому значению сопоставляем функцию, которую нужно вызвать
	*/
	mux.HandleFunc("/health", api.NewHealthHandler(queries))
	mux.HandleFunc("/ws", api.NewWebSocketHandler(queries))
	mux.HandleFunc("/register", api.NewRegisterHandler(queries))
	mux.HandleFunc("/verify-totp", api.NewVerifyTOTPHandler(queries))
	mux.HandleFunc("/login", api.NewLoginHandler(queries))
	mux.HandleFunc("/register-device", api.NewRegisterDeviceHandler(queries))
	mux.HandleFunc("/prekeys/upload", api.NewUploadPrekeysHandler(queries))
	mux.HandleFunc("GET /devices/{device_id}/prekey-bundle", api.NewGetPrekeyBundleHandler(queries))

	//сохраняем в переменную и запускаем HTTP-сервер на порту 8080. ListenAndServe - блокирующая функция, которая будет работать до тех пор, пока сервер не будет остановлен или не произойдет ошибка
	//внутри запускается бесконечный цикл, который как раз через mux проверяет, какие запросы пришли и вызывает в горутине (параллельно) соответствующие функции-обработчики, а сам цикл продолжает работать и ждать новых запросов
	var server_error = http.ListenAndServe(":8080", mux)

	//если сервер не запустился, то выводим сообщение об ошибке и выходим с кодом 1
	if server_error != nil {
		log.Fatalf("ошибка запуска сервера на порту 8080: %v", server_error)
	}

}
