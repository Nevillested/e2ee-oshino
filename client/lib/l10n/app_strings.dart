import 'app_locale.dart';

/// Единая точка перевода интерфейса — все строки в одном месте, по ключу,
/// с текстом на каждом поддерживаемом языке рядом. Смена языка (см.
/// LocaleStore) меняет только AppStrings.locale, дальше все места,
/// читающие tr('some.key'), сами подхватывают нужный текст при
/// перерисовке (см. ThemeReactive — он же переподписан и на LocaleStore).
///
/// ВАЖНО: это НЕ перевод абсолютно каждой строки приложения — экран чата
/// (лента сообщений, вложения, звонки и т.д.) и ряд второстепенных
/// экранов остаются на русском в этом заходе, см. обсуждение в чате.
/// Переведены: экраны входа/регистрации, список чатов, настройки и все
/// их всплывающие окна — то, что должно быть переведено ПОЛНОСТЬЮ и сразу
/// быть готовым как образец для расширения остального приложения.
class AppStrings {
  // По умолчанию — английский (см. LocaleStore: та же логика там, это
  // просто согласованное стартовое значение для самого первого кадра, до
  // того как LocaleStore.init() успеет дочитать сохранённый выбор).
  static AppLocale locale = AppLocale.en;

  static String t(String key) {
    final entry = _values[key];
    if (entry == null) return key;
    return entry[locale] ?? entry[AppLocale.ru] ?? key;
  }

  static const Map<String, Map<AppLocale, String>> _values = {
    'common.cancel': {AppLocale.ru: 'Отмена', AppLocale.en: 'Cancel'},
    'common.save': {AppLocale.ru: 'Сохранить', AppLocale.en: 'Save'},
    'common.done': {AppLocale.ru: 'Готово', AppLocale.en: 'Done'},
    'common.next': {AppLocale.ru: 'Далее', AppLocale.en: 'Next'},

    'auth.loginHint': {AppLocale.ru: 'Логин', AppLocale.en: 'Login'},
    'auth.passwordHint': {AppLocale.ru: 'Пароль', AppLocale.en: 'Password'},
    'auth.totpHint': {
      AppLocale.ru: 'Код из аутентификатора',
      AppLocale.en: 'Authenticator code',
    },
    'auth.loggingIn': {
      AppLocale.ru: 'Идёт авторизация, подождите',
      AppLocale.en: 'Signing in, please wait',
    },
    'auth.registering': {
      AppLocale.ru: 'Идёт регистрация, подождите',
      AppLocale.en: 'Registering, please wait',
    },
    'totp.title': {
      AppLocale.ru: 'Подтверждение',
      AppLocale.en: 'Confirmation',
    },
    'totp.scanInstruction': {
      AppLocale.ru:
          'Отсканируй эту ссылку в приложении-аутентификаторе '
          '(Google Authenticator, Aegis и т.п.), затем введи текущий код:',
      AppLocale.en:
          'Scan this link in your authenticator app '
          '(Google Authenticator, Aegis, etc.), then enter the current code:',
    },
    'totp.manualEntry': {
      AppLocale.ru: 'Или введи секретный код вручную:',
      AppLocale.en: 'Or enter the secret code manually:',
    },
    'totp.codeCopied': {
      AppLocale.ru: 'Код скопирован',
      AppLocale.en: 'Code copied',
    },
    'totp.confirm': {
      AppLocale.ru: 'Подтвердить',
      AppLocale.en: 'Confirm',
    },

    'common.copied': {AppLocale.ru: 'Скопировано', AppLocale.en: 'Copied'},

    'chat.queued': {AppLocale.ru: 'В очереди', AppLocale.en: 'Queued'},
    'chat.sending': {AppLocale.ru: 'Отправка…', AppLocale.en: 'Sending…'},
    'chat.cancelRecording': {
      AppLocale.ru: 'Отменить запись',
      AppLocale.en: 'Cancel recording',
    },
    'chat.swipeLeftToCancel': {
      AppLocale.ru: 'Чтобы отменить, проведите пальцем влево',
      AppLocale.en: 'Swipe left to cancel',
    },
    'chat.fileTooLarge': {
      AppLocale.ru: 'Файл слишком большой',
      AppLocale.en: 'File is too large',
    },
    'chat.encrypting': {
      AppLocale.ru: 'Шифрование…',
      AppLocale.en: 'Encrypting…',
    },
    'chat.uploading': {
      AppLocale.ru: 'Загрузка на сервер…',
      AppLocale.en: 'Uploading to server…',
    },
    'chat.negotiating': {
      AppLocale.ru: 'Согласование с собеседником…',
      AppLocale.en: 'Negotiating with peer…',
    },
    'chat.openFileFailed': {
      AppLocale.ru: 'Не удалось открыть файл',
      AppLocale.en: 'Failed to open file',
    },
    'chat.pinnedMessage': {
      AppLocale.ru: 'Закреплённое сообщение',
      AppLocale.en: 'Pinned message',
    },
    'chat.editingMessage': {
      AppLocale.ru: 'Редактирование сообщения',
      AppLocale.en: 'Editing message',
    },
    'chat.forwardingCount': {
      AppLocale.ru: 'Количество пересылаемых сообщений',
      AppLocale.en: 'Number of messages to forward',
    },
    'chat.selectedCount': {
      AppLocale.ru: 'Выбрано',
      AppLocale.en: 'Selected',
    },

    'presence.online': {AppLocale.ru: 'в сети', AppLocale.en: 'online'},
    'presence.typing': {
      AppLocale.ru: 'печатает…',
      AppLocale.en: 'typing…',
    },
    'presence.justNow': {
      AppLocale.ru: 'только что',
      AppLocale.en: 'just now',
    },
    'presence.minutesAgoSuffix': {
      AppLocale.ru: 'мин. назад',
      AppLocale.en: 'min ago',
    },

    'chatMenu.pin': {AppLocale.ru: 'Закрепить', AppLocale.en: 'Pin'},
    'chatMenu.unpin': {AppLocale.ru: 'Открепить', AppLocale.en: 'Unpin'},
    'chatMenu.mute': {
      AppLocale.ru: 'Выключить уведомления',
      AppLocale.en: 'Mute notifications',
    },
    'chatMenu.unmute': {
      AppLocale.ru: 'Включить уведомления',
      AppLocale.en: 'Unmute notifications',
    },
    'chatMenu.clearHistory': {
      AppLocale.ru: 'Очистить историю',
      AppLocale.en: 'Clear history',
    },
    'chatMenu.deleteChat': {
      AppLocale.ru: 'Удалить диалог',
      AppLocale.en: 'Delete chat',
    },
    'chatMenu.clearHistoryTitle': {
      AppLocale.ru: 'Очистить историю переписки?',
      AppLocale.en: 'Clear chat history?',
    },
    'chatMenu.clearHistoryConfirm': {
      AppLocale.ru: 'Очистить',
      AppLocale.en: 'Clear',
    },
    'chatMenu.deleteChatTitle': {
      AppLocale.ru: 'Удалить диалог?',
      AppLocale.en: 'Delete this chat?',
    },
    'chatMenu.deleteChatConfirm': {
      AppLocale.ru: 'Удалить',
      AppLocale.en: 'Delete',
    },

    'error.registerFailed': {
      AppLocale.ru: 'Не удалось зарегистрироваться',
      AppLocale.en: 'Failed to register',
    },
    'error.loginTaken': {
      AppLocale.ru: 'Пользователь с таким логином уже зарегистрирован',
      AppLocale.en: 'A user with this login is already registered',
    },
    'error.wrongTotpCode': {
      AppLocale.ru: 'Неверный код подтверждения',
      AppLocale.en: 'Invalid confirmation code',
    },
    'error.uploadFailed': {
      AppLocale.ru: 'Не удалось загрузить файл',
      AppLocale.en: 'Failed to upload file',
    },
    'error.cancelledByUser': {
      AppLocale.ru: 'Отменено пользователем',
      AppLocale.en: 'Cancelled by user',
    },
    'error.downloadFailed': {
      AppLocale.ru: 'Не удалось скачать файл',
      AppLocale.en: 'Failed to download file',
    },
    'error.wrongCredentials': {
      AppLocale.ru: 'Неверный логин, пароль или код',
      AppLocale.en: 'Incorrect login, password or code',
    },
    'error.peerOutOfKeys': {
      AppLocale.ru: 'У собеседника закончились ключи, попробуйте позже',
      AppLocale.en: "The other party is out of keys, try again later",
    },
    'error.peerKeysFailed': {
      AppLocale.ru: 'Не удалось получить ключи собеседника',
      AppLocale.en: "Failed to get the other party's keys",
    },
    'error.deviceRegisterFailed': {
      AppLocale.ru: 'Не удалось зарегистрировать устройство',
      AppLocale.en: 'Failed to register device',
    },
    'error.prekeysFailed': {
      AppLocale.ru: 'Не удалось загрузить prekeys',
      AppLocale.en: 'Failed to load prekeys',
    },
    'error.userNotFound': {
      AppLocale.ru: 'Такого пользователя нет',
      AppLocale.en: 'No such user',
    },
    'error.userLookupFailed': {
      AppLocale.ru: 'Не удалось найти пользователя',
      AppLocale.en: 'Failed to find user',
    },
    'forward.title': {AppLocale.ru: 'Переслать', AppLocale.en: 'Forward'},

    'error.languageSaveFailed': {
      AppLocale.ru: 'Не удалось сохранить язык',
      AppLocale.en: 'Failed to save language',
    },
    'error.emailSaveFailed': {
      AppLocale.ru: 'Не удалось сохранить почту',
      AppLocale.en: 'Failed to save email',
    },
    'email.title': {
      AppLocale.ru: 'Почта для восстановления',
      AppLocale.en: 'Recovery email',
    },
    'email.description': {
      AppLocale.ru:
          'Если вы забудете пароль, код для восстановления доступа придёт '
          'на эту почту. Поле необязательное.',
      AppLocale.en:
          'If you forget your password, a recovery code will be sent to '
          'this email. This field is optional.',
    },
    'email.hint': {
      AppLocale.ru: 'you@example.com',
      AppLocale.en: 'you@example.com',
    },
    'email.invalid': {
      AppLocale.ru: 'Неверный формат почты',
      AppLocale.en: 'Invalid email format',
    },
    'email.saved': {
      AppLocale.ru: 'Почта подтверждена и сохранена',
      AppLocale.en: 'Email confirmed and saved',
    },
    'email.removed': {
      AppLocale.ru: 'Почта удалена',
      AppLocale.en: 'Email removed',
    },
    'email.sendCode': {
      AppLocale.ru: 'Отправить код',
      AppLocale.en: 'Send code',
    },
    'email.removeButton': {
      AppLocale.ru: 'Убрать почту',
      AppLocale.en: 'Remove email',
    },
    'email.codeSentTo': {
      AppLocale.ru: 'Код отправлен на',
      AppLocale.en: 'Code sent to',
    },
    'error.emailTaken': {
      AppLocale.ru: 'Эта почта уже привязана к другому аккаунту',
      AppLocale.en: 'This email is already linked to another account',
    },
    'error.emailVerifyRequestFailed': {
      AppLocale.ru: 'Не удалось отправить код подтверждения',
      AppLocale.en: 'Failed to send the confirmation code',
    },

    'error.muteFailed': {
      AppLocale.ru: 'Не удалось изменить уведомления',
      AppLocale.en: 'Failed to change notifications',
    },
    'error.noAccountId': {
      AppLocale.ru: 'Сервер не вернул account_id пользователя',
      AppLocale.en: "Server did not return the user's account_id",
    },

    'encryption.info': {
      AppLocale.ru:
          'Переписка защищена сквозным шифрованием: ключи создаются '
          'и хранятся только на ваших устройствах, сервер не может '
          'прочитать содержимое сообщений.',
      AppLocale.en:
          'The conversation is protected by end-to-end encryption: keys '
          'are created and stored only on your devices, the server '
          'cannot read the contents of messages.',
    },
    'common.unknown': {AppLocale.ru: 'Неизвестный', AppLocale.en: 'Unknown'},

    'welcome.login': {AppLocale.ru: 'Войти', AppLocale.en: 'Log in'},
    'welcome.register': {AppLocale.ru: 'Регистрация', AppLocale.en: 'Register'},

    'login.title': {AppLocale.ru: 'Вход', AppLocale.en: 'Log in'},
    'register.title': {
      AppLocale.ru: 'Регистрация',
      AppLocale.en: 'Registration',
    },

    'recovery.forgotPassword': {
      AppLocale.ru: 'Забыли пароль?',
      AppLocale.en: 'Forgot password?',
    },
    'recovery.title': {
      AppLocale.ru: 'Восстановление пароля',
      AppLocale.en: 'Password recovery',
    },
    'recovery.sendCode': {
      AppLocale.ru: 'Отправить код',
      AppLocale.en: 'Send code',
    },
    'recovery.requestSentInfo': {
      AppLocale.ru:
          'Если у аккаунта указана почта, на неё отправлен код восстановления',
      AppLocale.en:
          'If the account has an email on file, a recovery code has been sent to it',
    },
    'recovery.codeTitle': {
      AppLocale.ru: 'Введите код',
      AppLocale.en: 'Enter code',
    },
    'recovery.codeHint': {
      AppLocale.ru: 'Код из письма',
      AppLocale.en: 'Code from the email',
    },
    'recovery.confirmCode': {
      AppLocale.ru: 'Подтвердить',
      AppLocale.en: 'Confirm',
    },
    'recovery.newPasswordTitle': {
      AppLocale.ru: 'Новый пароль',
      AppLocale.en: 'New password',
    },
    'recovery.newPasswordHint': {
      AppLocale.ru: 'Новый пароль',
      AppLocale.en: 'New password',
    },
    'recovery.confirmPasswordHint': {
      AppLocale.ru: 'Повторите пароль',
      AppLocale.en: 'Confirm password',
    },
    'recovery.save': {AppLocale.ru: 'Сохранить', AppLocale.en: 'Save'},
    'recovery.passwordsDontMatch': {
      AppLocale.ru: 'Пароли не совпадают',
      AppLocale.en: 'Passwords do not match',
    },
    'recovery.success': {
      AppLocale.ru: 'Пароль изменён, теперь можно войти',
      AppLocale.en: 'Password changed, you can now log in',
    },
    'error.recoveryRequestFailed': {
      AppLocale.ru: 'Не удалось отправить запрос',
      AppLocale.en: 'Failed to send request',
    },
    'error.recoveryWrongCode': {
      AppLocale.ru: 'Неверный или истёкший код',
      AppLocale.en: 'Invalid or expired code',
    },
    'error.recoveryUserNotFound': {
      AppLocale.ru: 'Пользователь с таким логином не найден',
      AppLocale.en: 'No user found with this login',
    },
    'error.recoveryNoEmailOnFile': {
      AppLocale.ru: 'У этого аккаунта не указана почта для восстановления',
      AppLocale.en: 'This account has no recovery email on file',
    },
    'error.changePasswordFailed': {
      AppLocale.ru: 'Не удалось изменить пароль',
      AppLocale.en: 'Failed to change password',
    },

    'password.tooShort': {
      AppLocale.ru: 'Пароль должен быть не короче 6 символов',
      AppLocale.en: 'Password must be at least 6 characters long',
    },
    'password.needUpper': {
      AppLocale.ru: 'Пароль должен содержать хотя бы одну заглавную букву',
      AppLocale.en: 'Password must contain at least one uppercase letter',
    },
    'password.needLower': {
      AppLocale.ru: 'Пароль должен содержать хотя бы одну строчную букву',
      AppLocale.en: 'Password must contain at least one lowercase letter',
    },
    'password.needDigit': {
      AppLocale.ru: 'Пароль должен содержать хотя бы одну цифру',
      AppLocale.en: 'Password must contain at least one digit',
    },
    'password.needSpecial': {
      AppLocale.ru: 'Пароль должен содержать хотя бы один специальный символ',
      AppLocale.en: 'Password must contain at least one special character',
    },
    'password.requirementsHint': {
      AppLocale.ru:
          'Не менее 6 символов, заглавная и строчная буквы, цифра и спецсимвол',
      AppLocale.en:
          'At least 6 characters, upper- and lowercase letters, a digit and a special character',
    },

    'recovery.chooseTitle': {
      AppLocale.ru: 'Как будем восстанавливать?',
      AppLocale.en: 'How do you want to recover it?',
    },
    'recovery.hasEmailButton': {
      AppLocale.ru: 'Я указывал(а) email для восстановления пароля',
      AppLocale.en: 'I set an email for password recovery',
    },
    'recovery.noEmailButton': {
      AppLocale.ru: 'Я не указывал(а) email для восстановления пароля',
      AppLocale.en: "I didn't set an email for password recovery",
    },
    'recovery.noEmailTitle': {
      AppLocale.ru: 'Обратитесь в поддержку',
      AppLocale.en: 'Contact support',
    },
    'recovery.noEmailBody': {
      AppLocale.ru:
          'Свяжитесь со службой технической поддержки support@oshino.space.\n\n'
          'Тема письма: «Забыл пароль к учётной записи».\n\n'
          'В теле письма опишите по возможности абсолютно всё, что помните об '
          'аккаунте. В восстановлении доступа поможет любая деталь.',
      AppLocale.en:
          'Contact technical support at support@oshino.space.\n\n'
          'Subject: "Forgot my account password".\n\n'
          'In the body, describe absolutely everything you remember about the '
          'account. Any detail can help restore access.',
    },
    'recovery.copyEmail': {
      AppLocale.ru: 'Скопировать адрес',
      AppLocale.en: 'Copy address',
    },

    'settings.changePassword': {
      AppLocale.ru: 'Изменить пароль',
      AppLocale.en: 'Change password',
    },
    'changePassword.title': {
      AppLocale.ru: 'Изменение пароля',
      AppLocale.en: 'Change password',
    },
    'changePassword.success': {
      AppLocale.ru: 'Пароль изменён',
      AppLocale.en: 'Password changed',
    },

    'home.notes': {AppLocale.ru: 'Заметки', AppLocale.en: 'Notes'},
    'call.incoming': {
      AppLocale.ru: 'Входящий звонок',
      AppLocale.en: 'Incoming call',
    },
    'call.cameraOff': {
      AppLocale.ru: 'Ваша камера выключена',
      AppLocale.en: 'Your camera is off',
    },
    'call.dialing': {AppLocale.ru: 'Вызов...', AppLocale.en: 'Calling...'},
    'call.answered': {AppLocale.ru: 'Звонок', AppLocale.en: 'Call'},
    'call.missed': {
      AppLocale.ru: 'Пропущенный звонок',
      AppLocale.en: 'Missed call',
    },
    'call.noAnswer': {
      AppLocale.ru: 'Абонент не отвечает',
      AppLocale.en: 'No answer',
    },
    'call.securingConnection': {
      AppLocale.ru: 'Устанавливаем защищённое соединение...',
      AppLocale.en: 'Establishing secure connection...',
    },
    'call.enablingMic': {
      AppLocale.ru: 'Включаем микрофон...',
      AppLocale.en: 'Enabling microphone...',
    },
    'call.buildingOffer': {
      AppLocale.ru: 'Формируем вызов...',
      AppLocale.en: 'Preparing call...',
    },
    'call.ringing': {AppLocale.ru: 'Звоним...', AppLocale.en: 'Ringing...'},
    'call.buildingAnswer': {
      AppLocale.ru: 'Формируем ответ...',
      AppLocale.en: 'Preparing answer...',
    },
    'call.connecting': {
      AppLocale.ru: 'Соединяемся...',
      AppLocale.en: 'Connecting...',
    },
    'call.returnToScreen': {
      AppLocale.ru: 'Вернуться к экрану звонка',
      AppLocale.en: 'Return to call screen',
    },
    'call.otherParty': {
      AppLocale.ru: 'собеседником',
      AppLocale.en: 'the other party',
    },

    'push.messagesChannelName': {
      AppLocale.ru: 'Сообщения',
      AppLocale.en: 'Messages',
    },
    'push.messagesChannelDescription': {
      AppLocale.ru: 'Новые сообщения',
      AppLocale.en: 'New messages',
    },
    'deleteMessage.title': {
      AppLocale.ru: 'Удалить сообщение?',
      AppLocale.en: 'Delete message?',
    },
    'deleteMessage.alsoForPeer': {
      AppLocale.ru: 'Также удалить у',
      AppLocale.en: 'Also delete for',
    },

    'action.reply': {AppLocale.ru: 'Ответить', AppLocale.en: 'Reply'},
    'action.copy': {AppLocale.ru: 'Копировать', AppLocale.en: 'Copy'},
    'action.unpin': {AppLocale.ru: 'Открепить', AppLocale.en: 'Unpin'},
    'action.pin': {AppLocale.ru: 'Закрепить', AppLocale.en: 'Pin'},
    'action.forward': {AppLocale.ru: 'Переслать', AppLocale.en: 'Forward'},
    'action.edit': {AppLocale.ru: 'Изменить', AppLocale.en: 'Edit'},
    'action.select': {AppLocale.ru: 'Выбрать', AppLocale.en: 'Select'},
    'action.delete': {AppLocale.ru: 'Удалить', AppLocale.en: 'Delete'},

    'media.limitedAccess': {
      AppLocale.ru: 'Доступны не все файлы — нажмите, чтобы разрешить полный доступ',
      AppLocale.en: 'Not all files are accessible — tap to grant full access',
    },
    'media.photo': {AppLocale.ru: 'Фото', AppLocale.en: 'Photo'},
    'media.file': {AppLocale.ru: 'Файл', AppLocale.en: 'File'},
    'media.video': {AppLocale.ru: 'Видео', AppLocale.en: 'Video'},
    'media.videoNote': {
      AppLocale.ru: 'Видеосообщение',
      AppLocale.en: 'Video message',
    },
    'media.voiceNote': {
      AppLocale.ru: 'Голосовое сообщение',
      AppLocale.en: 'Voice message',
    },

    'push.newMessageBody': {
      AppLocale.ru: 'У вас новое сообщение',
      AppLocale.en: 'You have a new message',
    },

    'connection.waitingForNetwork': {
      AppLocale.ru: 'Ожидание интернета…',
      AppLocale.en: 'Waiting for network…',
    },
    'connection.connecting': {
      AppLocale.ru: 'Подключение к серверу…',
      AppLocale.en: 'Connecting to server…',
    },
    'connection.connected': {
      AppLocale.ru: 'Подключено',
      AppLocale.en: 'Connected',
    },
    'connection.reconnecting': {
      AppLocale.ru: 'Переподключение…',
      AppLocale.en: 'Reconnecting…',
    },

    'chat.messageHint': {
      AppLocale.ru: 'Сообщение',
      AppLocale.en: 'Message',
    },
    'chat.captionHint': {
      AppLocale.ru: 'Добавьте описание',
      AppLocale.en: 'Add a caption',
    },

    'newChat.title': {AppLocale.ru: 'Новый чат', AppLocale.en: 'New chat'},
    'newChat.loginHint': {
      AppLocale.ru: 'Логин собеседника',
      AppLocale.en: "Contact's login",
    },
    'newChat.search': {AppLocale.ru: 'Найти', AppLocale.en: 'Search'},
    'home.deletedAccount': {
      AppLocale.ru: 'Удалённый аккаунт',
      AppLocale.en: 'Deleted account',
    },

    'settings.title': {AppLocale.ru: 'Настройки', AppLocale.en: 'Settings'},
    'settings.logout': {
      AppLocale.ru: 'Выйти из аккаунта',
      AppLocale.en: 'Log out',
    },
    'settings.deleteAccount': {
      AppLocale.ru: 'Удалить аккаунт',
      AppLocale.en: 'Delete account',
    },
    'settings.defaultReaction': {
      AppLocale.ru: 'Реакция по умолчанию',
      AppLocale.en: 'Default reaction',
    },
    'settings.language': {AppLocale.ru: 'Язык', AppLocale.en: 'Language'},
    'settings.theme': {AppLocale.ru: 'Тема', AppLocale.en: 'Theme'},
    'settings.avatar': {
      AppLocale.ru: 'Фото профиля',
      AppLocale.en: 'Profile photo',
    },
    'settings.avatarUploadFailed': {
      AppLocale.ru: 'Не удалось загрузить фото',
      AppLocale.en: 'Failed to upload photo',
    },
    'settings.email': {
      AppLocale.ru: 'Почта для восстановления',
      AppLocale.en: 'Recovery email',
    },
    'settings.backToChats': {
      AppLocale.ru: 'Вернуться к чатам',
      AppLocale.en: 'Back to chats',
    },

    'account.logoutTitle': {
      AppLocale.ru: 'Выйти из аккаунта?',
      AppLocale.en: 'Log out?',
    },
    'account.logoutBody': {
      AppLocale.ru:
          'Ключи шифрования будут удалены с этого устройства. '
          'Без них восстановить переписку будет невозможно.',
      AppLocale.en:
          'Encryption keys will be removed from this device. '
          'Without them, recovering the conversation history will be '
          'impossible.',
    },
    'account.logoutConfirm': {
      AppLocale.ru: 'Я понимаю, выйти из аккаунта',
      AppLocale.en: 'I understand, log out',
    },
    'account.deleteTitle': {
      AppLocale.ru: 'Удалить аккаунт?',
      AppLocale.en: 'Delete account?',
    },
    'account.deleteBody': {
      AppLocale.ru:
          'Аккаунт будет безвозвратно удалён с сервера. Собеседники увидят '
          'вас как «Удалённый аккаунт». Это действие нельзя отменить.',
      AppLocale.en:
          'The account will be permanently deleted from the server. Your '
          'contacts will see you as a "Deleted account". This action '
          'cannot be undone.',
    },
    'account.deleteConfirm': {
      AppLocale.ru: 'Удалить аккаунт навсегда',
      AppLocale.en: 'Delete account permanently',
    },
    'account.deleteOfflineError': {
      AppLocale.ru:
          'Нет соединения с сервером — удаление аккаунта возможно только '
          'онлайн',
      AppLocale.en:
          'No connection to the server — the account can only be deleted '
          'while online',
    },

    'reaction.pickerTitle': {
      AppLocale.ru: 'Реакция по умолчанию',
      AppLocale.en: 'Default reaction',
    },

    'language.title': {AppLocale.ru: 'Язык', AppLocale.en: 'Language'},
    'language.russian': {AppLocale.ru: 'Russian', AppLocale.en: 'Russian'},
    'language.english': {AppLocale.ru: 'English', AppLocale.en: 'English'},
    'language.restartNotice': {
      AppLocale.ru:
          'Чтобы изменения языка вступили в силу везде, перезапустите приложение',
      AppLocale.en:
          'Restart the app for the language change to take full effect',
    },

    'theme.title': {AppLocale.ru: 'Тема', AppLocale.en: 'Theme'},
    'theme.dark': {AppLocale.ru: 'Тёмная тема', AppLocale.en: 'Dark theme'},
    'theme.light': {
      AppLocale.ru: 'Светлая тема',
      AppLocale.en: 'Light theme',
    },
  };
}

String tr(String key) => AppStrings.t(key);
