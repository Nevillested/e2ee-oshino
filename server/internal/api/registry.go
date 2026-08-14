package api

import (
	"context"
	"log"
	"sync"

	"github.com/coder/websocket"
)

// структура хранения подключенных пользователей к серверу
type ConnectionRegistry struct {
	mu    sync.Mutex
	conns map[string]*websocket.Conn
	// presenceSubs[targetDeviceID] = набор deviceID, которые сейчас смотрят
	// на экран чата с targetDeviceID и хотят живые обновления о его
	// онлайн/офлайн статусе (см. NewWebSocketHandler, "presence_subscribe").
	// Подписка — только на время открытого экрана чата, не постоянная:
	// сервер не хранит "у кого с кем есть переписка" вообще, поэтому
	// сам разослать статус всем контактам не может — только тем, кто
	// прямо сейчас явно попросил.
	presenceSubs map[string]map[string]bool
}

// метод для type ConnectionRegistry, который добавляет запись в словарь/мапу/список присутствующих
func (reg *ConnectionRegistry) Add(deviceID string, conn *websocket.Conn) {

	//блокируем
	reg.mu.Lock()

	//заранее определяем разблокировку, чтобы после завершения работы текущей функции, разблокировка точно сработала
	defer reg.mu.Unlock()

	//добавлеяем запись вида: "deviceID": "ID_вебсокет_подключения"
	reg.conns[deviceID] = conn
}

// метод для type ConnectionRegistry, который удаляет запись из словаря/мапы/списка присутствующих
func (reg *ConnectionRegistry) Remove(deviceID string) {

	//блокируем
	reg.mu.Lock()

	//заранее определяем разблокировку, чтобы после завершения работы текущей функции, разблокировка точно сработала
	defer reg.mu.Unlock()

	//удаляем запись вида: "deviceID": "ID_вебсокет_подключения"
	delete(reg.conns, deviceID)
}

// метод для type ConnectionRegistry, который выдает инфу, подключен ли пользователь к серверу или нет
func (reg *ConnectionRegistry) Get(deviceID string) (*websocket.Conn, bool) {

	//блокируем
	reg.mu.Lock()

	//заранее определяем разблокировку, чтобы после завершения работы текущей функции, разблокировка точно сработала
	defer reg.mu.Unlock()

	//проверяем есть ли такой пользователь в списке подключенных или нет
	conn, ok := reg.conns[deviceID]

	//возвращаем результат
	return conn, ok
}

// чтобы каждое подключение работало не со своей копией, а с общей структурой - возвращаем указатель на структуру. Так с одной структурой будет работать весь сервер
func NewConnectionRegistry() *ConnectionRegistry {

	//объявляем переменную структуры
	var NewRegistry ConnectionRegistry

	//инициализация второго поля переменной, тк по умолчанию это nil
	NewRegistry.conns = make(map[string]*websocket.Conn)
	NewRegistry.presenceSubs = make(map[string]map[string]bool)

	//возврат
	return &NewRegistry
}

// IsOnline — то же самое, что и Get, но без отдачи самого соединения —
// нужно там, где важен только сам факт "подключён ли он сейчас".
func (reg *ConnectionRegistry) IsOnline(deviceID string) bool {
	reg.mu.Lock()
	defer reg.mu.Unlock()
	_, ok := reg.conns[deviceID]
	return ok
}

// SubscribePresence — subscriberID хочет живые обновления о статусе
// targetID (открыл экран чата с ним). Возвращает true, если targetID
// сейчас в сети — этим значением вызывающая сторона сразу отвечает
// подписчику, не дожидаясь следующего изменения статуса.
func (reg *ConnectionRegistry) SubscribePresence(subscriberID, targetID string) bool {
	reg.mu.Lock()
	defer reg.mu.Unlock()

	if reg.presenceSubs[targetID] == nil {
		reg.presenceSubs[targetID] = make(map[string]bool)
	}
	reg.presenceSubs[targetID][subscriberID] = true

	_, online := reg.conns[targetID]
	return online
}

// UnsubscribePresence — обратное действие (ушёл с экрана чата).
func (reg *ConnectionRegistry) UnsubscribePresence(subscriberID, targetID string) {
	reg.mu.Lock()
	defer reg.mu.Unlock()

	if subs, ok := reg.presenceSubs[targetID]; ok {
		delete(subs, subscriberID)
		if len(subs) == 0 {
			delete(reg.presenceSubs, targetID)
		}
	}
}

// UnsubscribeAllFor — subscriberID отключился от сервера вообще, снимаем
// все его подписки разом, чтобы они не копились в памяти вечно.
func (reg *ConnectionRegistry) UnsubscribeAllFor(subscriberID string) {
	reg.mu.Lock()
	defer reg.mu.Unlock()

	for targetID, subs := range reg.presenceSubs {
		delete(subs, subscriberID)
		if len(subs) == 0 {
			delete(reg.presenceSubs, targetID)
		}
	}
}

// PresenceSubscribers — кто сейчас хочет знать о смене статуса targetID
// (см. NewWebSocketHandler — вызывается при подключении/отключении
// каждого устройства, чтобы разослать живое обновление подписчикам).
func (reg *ConnectionRegistry) PresenceSubscribers(targetID string) []string {
	reg.mu.Lock()
	defer reg.mu.Unlock()

	subs, ok := reg.presenceSubs[targetID]
	if !ok {
		return nil
	}
	result := make([]string, 0, len(subs))
	for id := range subs {
		result = append(result, id)
	}
	return result
}

// удаляет запись только если в реестре сейчас лежит именно это соединение — а не более новое, которое могло успеть зарегистрироваться позже (защита от гонки при быстром переподключении).
// Возвращает true, если запись реально была удалена — этим значением
// вызывающая сторона (см. NewWebSocketHandler) решает, стоит ли рассылать
// "офлайн" подписчикам на статус: если тут false, устройство на самом
// деле уже переподключилось по-новой, и слать "офлайн" не нужно.
func (reg *ConnectionRegistry) RemoveIfCurrent(deviceID string, conn *websocket.Conn) bool {
	reg.mu.Lock()
	defer reg.mu.Unlock()

	if reg.conns[deviceID] == conn {
		delete(reg.conns, deviceID)
		return true
	}
	return false
}

// Broadcast — шлёт сырые байты ВСЕМ сейчас подключённым устройствам, без
// исключения. Используется только для сигналов, у которых сервер
// принципиально не знает конкретного адресата (например, "у аккаунта X
// поменялось фото профиля" — сервер не хранит "кто чей контакт", в
// отличие от presence-подписок, поэтому адресной рассылки тут не сделать
// без отдельного графа контактов; сам сигнал ничего секретного не несёт —
// просто account_id, для которого стоит перепроверить кэш аватара). Копия
// списка соединений снимается под локом, а сама отправка — уже без
// него, чтобы не держать мьютекс всего реестра на время сетевого I/O по
// потенциально многим соединениям.
func (reg *ConnectionRegistry) Broadcast(ctx context.Context, msgBytes []byte) {
	reg.mu.Lock()
	conns := make([]*websocket.Conn, 0, len(reg.conns))
	for _, conn := range reg.conns {
		conns = append(conns, conn)
	}
	reg.mu.Unlock()

	for _, conn := range conns {
		if err := conn.Write(ctx, websocket.MessageText, msgBytes); err != nil {
			log.Printf("Broadcast: ошибка отправки одному из устройств: %v", err)
		}
	}
}

/*
принудительно закрывает соединение конкретногоустройства и убирает его из реестра — используется, когда старое
устройство нужно немедленно "выгнать" при входе с нового устройства
того же аккаунта, не дожидаясь, пока оно само что-то пришлёт и получит отказ.
*/
func (reg *ConnectionRegistry) CloseAndRemove(deviceID string) {
	reg.mu.Lock()
	conn, ok := reg.conns[deviceID]
	if ok {
		delete(reg.conns, deviceID)
	}
	reg.mu.Unlock()

	if ok {
		conn.Close(websocket.StatusPolicyViolation, "logged in on another device")
	}
}
