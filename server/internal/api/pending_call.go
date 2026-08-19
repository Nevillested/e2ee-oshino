package api

import (
	"sync"
	"time"
)

// pendingCallEntry — один отложенный (ещё не доставленный) звонок,
// ожидающий, пока получатель подключится по WebSocket. frames хранит
// исходные байты каждого call_*-кадра ровно в том виде, в каком их прислал
// звонящий (call_offer первым, следом любые call_ice/call_video_state,
// пришедшие пока получатель ещё не в сети) — чтобы доставить их получателю
// одним пакетом сразу после подключения, в исходном порядке.
type pendingCallEntry struct {
	callID         string
	callerDeviceID string
	frames         [][]byte
	timer          *time.Timer
}

// PendingCallRegistry — по одному отложенному звонку на устройство-получатель.
// В отличие от pending_messages (которые лежат в БД), это чисто
// оперативная память: звонок эфемерен, и если сервер перезапустится
// посреди ожидания — все WebSocket-соединения и так оборвутся, восстанавливать
// тут нечего.
type PendingCallRegistry struct {
	mu    sync.Mutex
	calls map[string]*pendingCallEntry
}

func NewPendingCallRegistry() *PendingCallRegistry {
	return &PendingCallRegistry{calls: make(map[string]*pendingCallEntry)}
}

// Start заводит новый отложенный звонок для оффлайн-получателя и таймер:
// если получатель не подключится за ttl, вызывается onExpire (там сервер
// должен уведомить звонящего, что абонент недоступен). Если для этого
// получателя уже был другой отложенный звонок — он молча вытесняется
// (считаем это редким случаем повторного/пересекающегося вызова).
func (r *PendingCallRegistry) Start(toDeviceID, callID, callerDeviceID string, offerFrame []byte, ttl time.Duration, onExpire func()) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if existing, ok := r.calls[toDeviceID]; ok {
		existing.timer.Stop()
	}

	entry := &pendingCallEntry{
		callID:         callID,
		callerDeviceID: callerDeviceID,
		frames:         [][]byte{offerFrame},
	}
	entry.timer = time.AfterFunc(ttl, onExpire)
	r.calls[toDeviceID] = entry
}

// Append добавляет ещё один кадр сигнала (например ICE-кандидат) к уже
// ожидающему звонку — только если он относится к тому же callID. Возвращает
// false, если подходящего отложенного звонка нет (кадр придётся обработать
// по старой схеме — ответом call_unavailable).
func (r *PendingCallRegistry) Append(toDeviceID, callID string, frame []byte) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	entry, ok := r.calls[toDeviceID]
	if !ok || entry.callID != callID {
		return false
	}
	entry.frames = append(entry.frames, frame)
	return true
}

// Cancel убирает отложенный звонок без уведомления получателя — вызывается,
// когда сам звонящий передумал (call_cancel/call_end/...) ещё до того, как
// получатель успел подключиться. Возвращает true, если действительно что-то
// отменили (запись существовала и принадлежала этому же звонящему).
func (r *PendingCallRegistry) Cancel(toDeviceID, callID, callerDeviceID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	entry, ok := r.calls[toDeviceID]
	if !ok || entry.callID != callID || entry.callerDeviceID != callerDeviceID {
		return false
	}
	entry.timer.Stop()
	delete(r.calls, toDeviceID)
	return true
}

// Peek возвращает кадры отложенного звонка для получателя, НЕ удаляя саму
// запись и не останавливая её TTL-таймер — используется, когда доставку
// ещё только предстоит подтвердить (см. NewWebSocketHandler): пока ack на
// call_offer не пришёл, звонок должен оставаться в очереди, а таймер — по
// прежнему тикать, чтобы звонящий в любом случае получил "недоступен" по
// истечении TTL, а не завис в неопределённости, если доставка тихо не
// удалась (зомби-соединение и т.п.).
func (r *PendingCallRegistry) Peek(toDeviceID string) (callID string, frames [][]byte, ok bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	entry, exists := r.calls[toDeviceID]
	if !exists {
		return "", nil, false
	}
	return entry.callID, entry.frames, true
}

// TakeIfSame — как Take, но удаляет запись, только если это всё ещё тот же
// звонок (callID совпадает) — защита от гонки: пока сервер ждал ack на
// доставку call_offer, звонящий мог успеть отменить этот звонок или начать
// новый для того же получателя (Start молча вытесняет предыдущую запись).
// Возвращает nil и ничего не трогает, если запись уже другая.
func (r *PendingCallRegistry) TakeIfSame(toDeviceID, callID string) [][]byte {
	r.mu.Lock()
	defer r.mu.Unlock()

	entry, ok := r.calls[toDeviceID]
	if !ok || entry.callID != callID {
		return nil
	}
	entry.timer.Stop()
	delete(r.calls, toDeviceID)
	return entry.frames
}

// Decline — получатель отклонил звонок с кнопки в push-уведомлении, минуя
// WebSocket (приложение не обязательно открыто). В отличие от Cancel (его
// вызывает звонящий) и Take (его вызывает WebSocket-подключение получателя),
// сюда получатель приходит через отдельный HTTP-эндпоинт. Возвращает
// device_id звонящего — чтобы вызывающий код сообщил ЕМУ, что звонок
// отклонён (в реальном времени, а не по TTL).
func (r *PendingCallRegistry) Decline(toDeviceID, callID string) (callerDeviceID string, ok bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	entry, exists := r.calls[toDeviceID]
	if !exists || entry.callID != callID {
		return "", false
	}
	entry.timer.Stop()
	delete(r.calls, toDeviceID)
	return entry.callerDeviceID, true
}

// Expire удаляет запись ТОЛЬКО если она всё ещё та же самая (по callID) —
// защита от гонки, когда таймер уже успел сработать в момент, когда
// получатель как раз подключился и Take() либо Cancel() успели выполниться
// первыми.
func (r *PendingCallRegistry) Expire(toDeviceID, callID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	entry, ok := r.calls[toDeviceID]
	if !ok || entry.callID != callID {
		return false
	}
	delete(r.calls, toDeviceID)
	return true
}
