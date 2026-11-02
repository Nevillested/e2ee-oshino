# Oshinobu — Linux

Нативный клиент для Linux на **C++20 и Qt 6** (Qt Quick), как Telegram Desktop. Протокол и формат на
проводе — те же, что у Android (`client/android/client-kotlin`) и iOS (`client/ios`): X3DH + Double
Ratchet, REST + WebSocket. Переписывается с Android и iOS — проверено на живом сервере 2026-11-01
(`testlinux` ↔ `g1ts0`, `test`). Код других клиентов не подключается — всё своё лежит в этой папке,
общий у клиентов только протокол.

Один аккаунт — одно устройство (как сейчас на сервере): вход на ПК выводит из аккаунта телефон, и
наоборот. Поддержку нескольких устройств пока не делаем (решено 2026-11-01).

## Структура

```
CMakeLists.txt           корневой: C++20, Qt 6.2+, OpenSSL 3, zlib, libsecret
core/                    ядро без UI (аналог :core на Android) — статическая библиотека oshinobu_core
  src/support/           Task.h — корутины C++20 поверх цикла событий Qt (аналог suspend):
                         Task<T>, spawn, delay, awaitReply, Deferred (ack/сигналы с таймаутом),
                         runInThread; Json.h, Log (журнал → feedback), Zip (паки стикеров)
  src/crypto/            X25519/Ed25519/HMAC/HKDF/AES-256-GCM (OpenSSL 3), AAD конверта, X3DH,
                         Double Ratchet, шифры вложений (целиком и потоково блоками 4 МБ), StoredIdentity
  src/protocol/          InnerMessage (все типы), PeerCipher (сборка/вскрытие конверта)
  src/net/               ApiClient (все REST-методы Android), WebSocketClient (переподключение,
                         проверка сессии, ping/pong, ack/rejected, сигналы звонков)
  src/storage/           SecureStore — один файл secure.bin под AES-GCM, мастер-ключ в связке ключей
                         GNOME (libsecret); KeyStore, SessionStore (с архивом сессий), очереди;
                         ChatStore — SQLite, каждая запись зашифрована; Prefs — QSettings
  src/service/           Infra (AsyncMutex, AckRegistry), Messaging (SendQueueProcessor, PeerMessenger,
                         DeviceSetup), MessageRouter (архив сессий, самолечение, все типы),
                         Media (загрузка целиком/частями с докачкой, две очереди скачивания),
                         Extras (стикеры, аватары, обои), Calls (CallManager — сигнальный протокол)
  src/media/             GstRtcEngine — WebRTC на GStreamer webrtcbin (собирается, если есть dev-пакеты):
                         звук PulseAudio/PipeWire с выбором устройств, Opus, видео v4l2 → VP8;
                         GstRecorder — голосовые (AAC/m4a) и кружки (H.264 openh264 + AAC/mp4, SD)
  src/Core.*             фасад: вход/регистрация, сессия, отправка, действия с чатами, отчёты
  tests/                 ProtocolVectorsTest (стенограмма Android), StorageTest; GstLoopbackTest — два
                         сеанса звонка в одном процессе (не в ctest: нужны настоящие микрофон и вывод):
                         соединение, звук в обе стороны, смена устройств, видео, обмен с SDP libwebrtc;
                         GstRecorderTest — запись голосового и кружка (moov, avc1/mp4a, превью)
app/                     приложение Qt Quick
  src/                   main (один экземпляр, --chat <логин>), AppModel (синглтон App в QML),
                         модели списков, запись голосовых (AAC/m4a), уведомления D-Bus, TgsItem (rlottie)
  qml/                   Main, AuthFlow (вход, регистрация с TOTP, восстановление), HomeView (список
                         чатов + переписка), ChatPane, MessageBubble, StickerPanel, SettingsDialog,
                         CallOverlay, LockScreen и мелкие компоненты
  i18n/                  en/ru.json — из Android strings.xml (tools/gen_strings.py, ключи те же);
                         linux_*.json — строки только Linux-клиента
tools/                   cli.cpp — консольный клиент для проверки ядра на живом сервере
                         (register/login/send/listen; TOTP считает сам); gen_strings.py
```

## Сборка и установка

Пакеты (Ubuntu 22.04):
```
sudo apt install qt6-base-dev qt6-declarative-dev libqt6websockets6-dev qt6-multimedia-dev \
  qt6-tools-dev qt6-l10n-tools libgl-dev libssl-dev libsqlite3-dev libopus-dev libsecret-1-dev \
  qml6-module-qtquick qml6-module-qtqml qml6-module-qtqml-models qml6-module-qtqml-workerscript \
  qml6-module-qtquick-controls qml6-module-qtquick-templates qml6-module-qtquick-layouts \
  qml6-module-qtquick-window qml6-module-qtquick-dialogs qml6-module-qtmultimedia \
  qml6-module-qt5compat-graphicaleffects
# стикеры WebP и TGS, звонки:
sudo apt install qt6-image-formats-plugins librlottie-dev gstreamer1.0-nice \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev
```

```
cmake -S client/linux -B client/linux/build -G Ninja -DCMAKE_INSTALL_PREFIX=$HOME/.local
cmake --build client/linux/build
ctest --test-dir client/linux/build --output-on-failure
cmake --install client/linux/build        # ~/.local/bin/oshinobu + ярлык в меню приложений
```

**GCC 11 (Ubuntu 22.04):** временные объекты прямо в выражении `co_await` (`{...}`-списки, лямбды)
компилятор обрабатывает с ошибками — то внутренняя ошибка компилятора, то разрушение временного
объекта раньше времени (падение в колбэке ack), то двойное разрушение: `co_await Awaiter{...}` с
нетривиальными полями GCC 11 разрушает дважды (так `runInThread` портил кучу — вылет
`malloc_consolidate()`). Правило кода: всё, что передаётся в `co_await`, сначала в именованную
переменную. То же с `?:` и `&&`/`||`: `x = c ? co_await a() : co_await b()` GCC 11 собирает с двойным
освобождением временного объекта (так `MediaUploader::upload` портил кучу после каждой загрузки —
вылет на отправке голосового); условие — заранее в переменную, `co_await` — отдельной строкой в if.
Порча кучи не всегда видна ASan: при вылете — gdb (`gdb -batch -ex run -ex bt`) и стек.
Проверка — сборка с AddressSanitizer:
```
cmake -S client/linux -B client/linux/build-asan -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address"
cmake --build client/linux/build-asan && ASAN_OPTIONS=detect_leaks=0 client/linux/build-asan/app/oshinobu
```

## Сделано (2026-11-01)

- **Ядро:** криптография и протокол (векторы Android — зелёные), все REST-методы, WebSocket, хранилища
  (секреты зашифрованы, мастер-ключ в связке ключей; история — SQLite с шифрованием записей), очередь
  отправки (ack, поздний ack, `rejected`, повтор при переподключении), PeerMessenger + регистрация
  устройства и пополнение prekey, MessageRouter (все типы, архив сессий, самолечение — один в один с
  Android, включая поведение после неудачной расшифровки), вложения (целиком / частями с докачкой,
  ручная и авто-очередь скачивания), стикеры (паки ZIP, «Недавние»), аватары, обои, звонки
  (CallManager: offer/answer/ICE, perfect negotiation, занято, 2 мин дозвона, таймаут шагов, история,
  пропущенный, отчёт `call_problem`), отчёты в feedback с журналом.
- **Проверено на живом сервере:** регистрация `testlinux` (код приглашения, TOTP), вход, регистрация
  устройства, отправка на `test` и `g1ts0`, приём и расшифровка ответов с Android, подтверждения
  прочтения.
- **Приложение:** вход, регистрация с TOTP (секрет текстом и кнопкой «Копировать»), восстановление
  пароля и аутентификатора; список чатов (поиск, открытие по логину, непрочитанные, закреп/мьют/удаление
  по правому клику, статус соединения); переписка (ответ, правка, удаление у обоих, закреп с переходом,
  пересылка (тексты, стикеры, вложения — как на Android), выбор сообщений протяжкой, поиск по
  переписке, реакции (в уголке пузыря), копирование, повтор/отмена отправки, «в сети»/«печатает…», обои (превью на
весь чат с перемещением и масштабом, обрезка и JPEG 1920/85 как на Android, в фоне), кнопка
  «вниз», перетаскивание файлов в окно); фото с автоскачиванием, видео и файлы (открытие в системном
  приложении, сохранение), голосовые и кружки как на Android (тап — микрофон ⇄ камера, удержание —
  запись, вверх на замок — фиксация с «отменой» и «отправить»; кружок играет в круге со звуком); стикеры
  (панель: «Недавние» и паки, свайп между паками, мягкое проявление по нажатию, загрузка своего пака,
  убрать пак; нажатие на стикер в переписке — его пак: добавить в панель / убрать); цветные эмодзи
(Noto Color Emoji раньше системного запасного шрифта); профиль (фото, имя, био, дата рождения), 5 тем, RU/EN на лету, приватность, почта,
  смена пароля, блокировка PIN-кодом с таймаутом, «Передачи» с отменой, очистка кэша, выход, удаление
  аккаунта; уведомления рабочего стола (без текста — как на Android), один экземпляр приложения;
  звук нового сообщения (окно свёрнуто или не в фокусе; QSoundEffect — QMediaPlayer в Qt 6.2
  второй раз не играет); трей: иконка всегда, левый клик — окно, правый — «Открыть / Выключить уведомления / Выйти»;
  крестик — по настройке «При закрытии окна» (в трей или закрыть; не выбрано — спрашивает один раз);
  экран звонка (входящий, рингтон и гудки, таймер, микрофон, камера и видео собеседника на весь
  экран, своё — окошком, выбор микрофона и вывода посреди разговора, завершение). Блокировка
  PIN-кодом срабатывает по таймеру и когда окно не в фокусе.
- **Установлено на этот ПК** в `~/.local` (ярлык «Oshinobu» в меню приложений).

## Звонки — что было не так (2026-11-01)

Первые звонки с Android соединялись, но без звука и рвались через ~6 с; исходящий не соединялся.
Найдено по отчётам `call_problem` телефона и `build/core/gst_loopback_test`:

- **sdpMid** — кандидатам ставился номер строки («0»), а webrtcbin называет m-строки «audio0»:
  libwebrtc отвергал все кандидаты. Теперь mid берётся из своего SDP.
- **Кандидаты до offer** — webrtcbin выдаёт их раньше, чем offer уходит; Android игнорирует
  `call_ice` до `call_offer`. CallManager придерживает свои кандидаты до отправки offer/answer.
- **Конвейер стоял в PAUSED** — вывод звука ждал первые данные (preroll), а микшеру нечего отдать,
  пока собеседник молчит: микрофон не писал ни пакета. У приёмников `async=false`.
- **Входящий звук не подключался** — микшер внутри bin вывода, связь снаружи без ghost-пада не
  создаётся (wrong hierarchy): первый же пакет — `not-linked`, приём (nicesrc) встаёт целиком, ICE
  перестаёт отвечать на проверки и рвётся через несколько секунд.
- **Камера до перезапроса** — VP8 до ответа собеседник не к чему привязать (тот же not-linked);
  камера стартует, когда сигналинг снова stable.
- **Opus без «/2»** — offer давал `OPUS/48000`, а libwebrtc знает Opus только как `opus/48000/2`:
  Android не находил общего кодека, отклонял звук, ICE не начинался (исходящий «висел» после ответа).
- **Роль DTLS в перезапросе** — webrtcbin 1.20 в каждом ответе пишет `setup:active`; если звонили мы
  (мы passive), ответ на перезапрос Android (включил камеру) менял роль, libwebrtc отвечал «Failed
  to set SSL role» — видео не было ни в одну сторону. Роль запоминается и сохраняется в ответах.
- **Своя камера без перезапроса** — webrtcbin не просит перезапрос, если видео-трансивер уже создан
  по offer собеседника; движок просит сам.
- **Камера Android поверх нашей** — включая камеру после нас, Android (addTrack) переиспользует нашу
  видеостроку и просит sendrecv; webrtcbin 1.20 направление согласованной строки менять не умеет
  («transceiver direction changes are not implemented») — перезапрос падал. Теперь направление
  каждой согласованной строки сохраняется (итог считается по SDP: current-direction в 1.20 неверен),
  а Android шлёт свою камеру новой строкой (addTransceiver) — видео собеседника приходит.
- Подробный журнал GStreamer звонка — `~/.local/share/Oshinobu/Oshinobu/gst-call.log` (локально,
  перезаписывается на каждый звонок, до 30 МБ).
- ssrc в caps (иначе в SDP нет a=ssrc), сводка SDP и ошибки set-*-description — в журнал, «соединено» и по ICE-состоянию (connection-state в 1.20
  отстаёт), ошибки конвейера и счётчики RTP (раз в 5 с) — в журнал, он уходит с `call_problem`.

## Дальше

1. Звонки: проверить живой звонок с Android после исправлений 2026-11-01 (см. ниже), голос и видео.
2. Альбомы и пересылка вложений, видео-кружки, просмотр фото внутри приложения.
