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
    'common.send': {AppLocale.ru: 'Отправить', AppLocale.en: 'Send'},
    'common.next': {AppLocale.ru: 'Далее', AppLocale.en: 'Next'},
    'common.retry': {AppLocale.ru: 'Повторить', AppLocale.en: 'Retry'},

    'auth.loginHint': {AppLocale.ru: 'Логин', AppLocale.en: 'Login'},
    'auth.passwordHint': {AppLocale.ru: 'Пароль', AppLocale.en: 'Password'},
    'auth.totpHint': {
      AppLocale.ru: 'Код из аутентификатора',
      AppLocale.en: 'Authenticator code',
    },
    'auth.inviteCodeHint': {
      AppLocale.ru: 'Пригласительный код',
      AppLocale.en: 'Invite code',
    },
    'auth.loggingIn': {
      AppLocale.ru: 'Идёт авторизация, подождите',
      AppLocale.en: 'Signing in, please wait',
    },
    'auth.registering': {
      AppLocale.ru: 'Идёт регистрация, подождите',
      AppLocale.en: 'Registering, please wait',
    },
    'totp.title': {AppLocale.ru: 'Подтверждение', AppLocale.en: 'Confirmation'},
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
    'totp.confirm': {AppLocale.ru: 'Подтвердить', AppLocale.en: 'Confirm'},

    'common.copied': {AppLocale.ru: 'Скопировано', AppLocale.en: 'Copied'},

    'chat.queued': {AppLocale.ru: 'В очереди', AppLocale.en: 'Queued'},
    // Имя отправителя цитаты в баннере реплая (см. _buildReplyPreview) —
    // "Вы", если процитировано собственное сообщение, как в Telegram.
    'chat.replyYou': {AppLocale.ru: 'Вы', AppLocale.en: 'You'},
    // Показывается вместо текста цитаты в баннере реплая, если исходное
    // сообщение больше не найдено в истории чата (удалено).
    'chat.replyDeleted': {
      AppLocale.ru: 'Удалённое сообщение',
      AppLocale.en: 'Deleted message',
    },
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
    'chat.savingOnServer': {
      AppLocale.ru: 'Сохранение на сервере',
      AppLocale.en: 'Saving on server',
    },
    'chat.negotiating': {
      AppLocale.ru: 'Согласование с собеседником…',
      AppLocale.en: 'Negotiating with peer…',
    },
    'chat.retryFailedPermanently': {
      AppLocale.ru: 'Не удалось повторить отправку: файл больше недоступен',
      AppLocale.en: 'Could not retry sending: file is no longer available',
    },
    'chat.retryFailedTemporary': {
      AppLocale.ru: 'Не удалось повторить отправку, попробуйте ещё раз',
      AppLocale.en: 'Could not retry sending, please try again',
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
    'chat.mediaBarPlaying': {
      AppLocale.ru: 'Воспроизведение',
      AppLocale.en: 'Playing',
    },
    'chat.selectedCount': {AppLocale.ru: 'Выбрано', AppLocale.en: 'Selected'},

    'presence.online': {AppLocale.ru: 'в сети', AppLocale.en: 'online'},
    'presence.typing': {AppLocale.ru: 'печатает…', AppLocale.en: 'typing…'},
    'presence.justNow': {AppLocale.ru: 'только что', AppLocale.en: 'just now'},
    'presence.minutesAgoSuffix': {
      AppLocale.ru: 'мин. назад',
      AppLocale.en: 'min ago',
    },
    'presence.yesterdayAt': {
      AppLocale.ru: 'вчера в',
      AppLocale.en: 'yesterday at',
    },
    'call.outputDevices': {
      AppLocale.ru: 'Устройства вывода',
      AppLocale.en: 'Output Devices',
    },
    'call.outputSpeaker': {AppLocale.ru: 'Динамик', AppLocale.en: 'Speaker'},
    'call.outputEarpiece': {
      AppLocale.ru: 'Ушной динамик',
      AppLocale.en: 'Earpiece',
    },
    'call.outputBluetooth': {
      AppLocale.ru: 'Bluetooth',
      AppLocale.en: 'Bluetooth',
    },
    'call.outputWiredHeadset': {
      AppLocale.ru: 'Проводная гарнитура',
      AppLocale.en: 'Wired headset',
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
    'chatMenu.block': {AppLocale.ru: 'Заблокировать', AppLocale.en: 'Block'},
    'chatMenu.unblock': {
      AppLocale.ru: 'Разблокировать',
      AppLocale.en: 'Unblock',
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
    'error.loginReserved': {
      AppLocale.ru: 'Этот логин зарезервирован, выберите другой',
      AppLocale.en: 'This login is reserved, please choose another one',
    },
    'error.inviteCodeInvalid': {
      AppLocale.ru: 'Неверный или уже использованный пригласительный код',
      AppLocale.en: 'Invalid or already used invite code',
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
    'error.tooManyLoginAttempts': {
      AppLocale.ru: 'Слишком много неудачных попыток входа, попробуйте позже',
      AppLocale.en: 'Too many failed login attempts, try again later',
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
    'error.statusSaveFailed': {
      AppLocale.ru: 'Не удалось сохранить статус',
      AppLocale.en: 'Failed to save status',
    },
    'error.birthdaySaveFailed': {
      AppLocale.ru: 'Не удалось сохранить дату рождения',
      AppLocale.en: 'Failed to save birthday',
    },
    'error.displayNameSaveFailed': {
      AppLocale.ru: 'Не удалось сохранить отображаемое имя',
      AppLocale.en: 'Failed to save display name',
    },
    'error.privacySaveFailed': {
      AppLocale.ru: 'Не удалось сохранить настройки приватности',
      AppLocale.en: 'Failed to save privacy settings',
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
    'email.addButton': {
      AppLocale.ru: 'Добавить почту',
      AppLocale.en: 'Add email',
    },
    'email.notSet': {
      AppLocale.ru: 'Почта для восстановления пока не добавлена',
      AppLocale.en: 'No recovery email added yet',
    },
    'email.removeConfirmTitle': {
      AppLocale.ru: 'Удалить почту?',
      AppLocale.en: 'Remove email?',
    },
    'email.removeConfirmBody': {
      AppLocale.ru:
          'Без почты восстановить доступ при утере пароля будет '
          'невозможно.',
      AppLocale.en:
          "Without an email on file, you won't be able to recover "
          'access if you forget your password.',
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
    'error.blockFailed': {
      AppLocale.ru: 'Не удалось изменить блокировку',
      AppLocale.en: 'Failed to change block status',
    },
    'error.noAccountId': {
      AppLocale.ru: 'Сервер не вернул account_id пользователя',
      AppLocale.en: "Server did not return the user's account_id",
    },
    'error.reportFailed': {
      AppLocale.ru: 'Не удалось отправить жалобу',
      AppLocale.en: 'Failed to send the report',
    },
    'error.feedbackFailed': {
      AppLocale.ru: 'Не удалось отправить отзыв',
      AppLocale.en: 'Failed to send feedback',
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
    'register.agreementPrefix': {
      AppLocale.ru: 'Регистрируясь, вы соглашаетесь с ',
      AppLocale.en: 'By registering, you agree to the ',
    },
    'register.agreementJoiner': {AppLocale.ru: ' и ', AppLocale.en: ' and '},

    'recovery.forgotPassword': {
      AppLocale.ru: 'Забыли пароль?',
      AppLocale.en: 'Forgot password?',
    },
    'recovery.forgotTotp': {
      AppLocale.ru: 'Нет доступа к аутентификатору?',
      AppLocale.en: 'Lost access to your authenticator?',
    },
    'recovery.title': {
      AppLocale.ru: 'Восстановление пароля',
      AppLocale.en: 'Password recovery',
    },
    'recovery.titleTotp': {
      AppLocale.ru: 'Восстановление аутентификатора',
      AppLocale.en: 'Authenticator recovery',
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

    'login.invalid': {
      AppLocale.ru:
          'Логин: от 3 до 32 символов, только латинские буквы и цифры',
      AppLocale.en: 'Login: 3-32 characters, Latin letters and digits only',
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
    'recovery.hasEmailButtonTotp': {
      AppLocale.ru: 'Я указывал(а) email для восстановления доступа',
      AppLocale.en: 'I set an email for account recovery',
    },
    'recovery.noEmailButton': {
      AppLocale.ru: 'Я не указывал(а) email для восстановления пароля',
      AppLocale.en: "I didn't set an email for password recovery",
    },
    'recovery.noEmailButtonTotp': {
      AppLocale.ru: 'Я не указывал(а) email для восстановления доступа',
      AppLocale.en: "I didn't set an email for account recovery",
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
    'recovery.noEmailBodyTotp': {
      AppLocale.ru:
          'Свяжитесь со службой технической поддержки support@oshino.space.\n\n'
          'Тема письма: «Нет доступа к аутентификатору».\n\n'
          'В теле письма опишите по возможности абсолютно всё, что помните об '
          'аккаунте. В восстановлении доступа поможет любая деталь.',
      AppLocale.en:
          'Contact technical support at support@oshino.space.\n\n'
          'Subject: "Lost access to my authenticator".\n\n'
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
    'call.declined': {
      AppLocale.ru: 'Абонент занят',
      AppLocale.en: 'The person declined',
    },
    'call.busy': {
      AppLocale.ru: 'Абонент разговаривает',
      AppLocale.en: 'The person is on another call',
    },

    'push.messagesChannelName': {
      AppLocale.ru: 'Сообщения',
      AppLocale.en: 'Messages',
    },
    'push.messagesChannelDescription': {
      AppLocale.ru: 'Новые сообщения',
      AppLocale.en: 'New messages',
    },
    'notification.downloadingFiles': {
      AppLocale.ru: 'Скачивание файлов',
      AppLocale.en: 'Downloading files',
    },
    'notification.uploadingFiles': {
      AppLocale.ru: 'Выгрузка файлов',
      AppLocale.en: 'Uploading files',
    },
    'notification.downloadingAndUploadingFiles': {
      AppLocale.ru: 'Скачивание и выгрузка файлов',
      AppLocale.en: 'Downloading and uploading files',
    },
    'notification.transfersChannelName': {
      AppLocale.ru: 'Передача файлов',
      AppLocale.en: 'File transfers',
    },
    'notification.transfersChannelDescription': {
      AppLocale.ru:
          'Пока приложение свёрнуто, продолжается передача файлов',
      AppLocale.en:
          'File transfers keep running while the app is in the background',
    },
    'transfers.title': {AppLocale.ru: 'Передачи', AppLocale.en: 'Transfers'},
    'transfers.upload': {AppLocale.ru: 'Отправка', AppLocale.en: 'Upload'},
    'transfers.download': {AppLocale.ru: 'Скачивание', AppLocale.en: 'Download'},
    'transfers.manualQueue': {
      AppLocale.ru: 'Вручную',
      AppLocale.en: 'Manual',
    },
    'transfers.autoQueue': {
      AppLocale.ru: 'Автоматически',
      AppLocale.en: 'Automatic',
    },
    'transfers.textQueue': {AppLocale.ru: 'Текст', AppLocale.en: 'Text'},
    'transfers.fileQueue': {AppLocale.ru: 'Файлы', AppLocale.en: 'Files'},
    'transfers.textMessage': {
      AppLocale.ru: 'Текстовое сообщение',
      AppLocale.en: 'Text message',
    },
    'transfers.empty': {AppLocale.ru: 'Пусто', AppLocale.en: 'Empty'},
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
    'action.report': {AppLocale.ru: 'Пожаловаться', AppLocale.en: 'Report'},
    'action.cancelSend': {
      AppLocale.ru: 'Отменить отправку',
      AppLocale.en: 'Cancel sending',
    },
    'action.retrySend': {
      AppLocale.ru: 'Повторить отправку',
      AppLocale.en: 'Retry sending',
    },
    'mediaViewer.saveToGallery': {
      AppLocale.ru: 'Сохранить в галерею',
      AppLocale.en: 'Save to gallery',
    },
    'mediaViewer.saved': {
      AppLocale.ru: 'Сохранено в галерею',
      AppLocale.en: 'Saved to gallery',
    },
    'chat.saveToDevice': {
      AppLocale.ru: 'Сохранить на устройство',
      AppLocale.en: 'Save to device',
    },
    'chat.savedToDevice': {
      AppLocale.ru: 'Сохранено на устройство',
      AppLocale.en: 'Saved to device',
    },
    'chat.saveToDeviceFailed': {
      AppLocale.ru: 'Не удалось сохранить файл',
      AppLocale.en: 'Failed to save the file',
    },
    'mediaViewer.saveFailed': {
      AppLocale.ru: 'Не удалось сохранить',
      AppLocale.en: 'Failed to save',
    },
    'mediaViewer.savePermissionDenied': {
      AppLocale.ru: 'Нет доступа к галерее — разрешите доступ в настройках',
      AppLocale.en: 'No access to gallery — allow access in settings',
    },
    'mediaViewer.openSettings': {
      AppLocale.ru: 'Настройки',
      AppLocale.en: 'Settings',
    },
    'report.title': {
      AppLocale.ru: 'Пожаловаться на сообщение',
      AppLocale.en: 'Report message',
    },
    'report.commentHint': {
      AppLocale.ru: 'Комментарий (необязательно) — почему вы жалуетесь',
      AppLocale.en: 'Comment (optional) — why are you reporting this',
    },
    'report.sent': {
      AppLocale.ru: 'Жалоба отправлена',
      AppLocale.en: 'Report sent',
    },

    'media.limitedAccess': {
      AppLocale.ru:
          'Доступны не все файлы — нажмите, чтобы разрешить полный доступ',
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
    'media.selectedCount': {AppLocale.ru: 'Выбрано', AppLocale.en: 'Selected'},
    'unit.bytes': {AppLocale.ru: 'Б', AppLocale.en: 'B'},
    'unit.kb': {AppLocale.ru: 'КБ', AppLocale.en: 'KB'},
    'unit.mb': {AppLocale.ru: 'МБ', AppLocale.en: 'MB'},
    'unit.gb': {AppLocale.ru: 'ГБ', AppLocale.en: 'GB'},
    'media.downloading': {
      AppLocale.ru: 'Скачивание…',
      AppLocale.en: 'Downloading…',
    },
    'media.playbackFailed': {
      AppLocale.ru: 'Не удалось воспроизвести. Нажмите ещё раз',
      AppLocale.en: 'Playback failed. Tap to retry',
    },
    'media.hideWithSpoiler': {
      AppLocale.ru: 'Скрыть спойлером',
      AppLocale.en: 'Hide with spoiler',
    },
    'media.spoilerHint': {
      AppLocale.ru: 'Нажмите, чтобы посмотреть',
      AppLocale.en: 'Tap to view',
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

    'chat.messageHint': {AppLocale.ru: 'Сообщение', AppLocale.en: 'Message'},
    // Приоритет 1 — я заблокировал собеседника (показывается даже если
    // блокировка взаимная, см. _blockedComposerText в chat_screen.dart).
    'chat.blockedByMe': {
      AppLocale.ru:
          'Вы не можете отправлять сообщения пользователю, которого заблокировали',
      AppLocale.en: 'You can\'t send messages to a user you have blocked',
    },
    // Приоритет 2 — собеседник заблокировал меня (а я его — нет).
    'chat.blockingMe': {
      AppLocale.ru:
          'Вы не можете отправлять сообщения пользователю, который вас заблокировал',
      AppLocale.en: 'You can\'t send messages to a user who has blocked you',
    },
    // Оба заблокировали друг друга — отдельная, третья формулировка (не
    // приоритет 1 и не приоритет 2), см. спецификацию блокировки.
    'chat.blockedMutual': {
      AppLocale.ru: 'Просто знай, неприязнь друг к другу взаимная',
      AppLocale.en: 'Just so you know — the dislike is mutual',
    },
    'chat.searchHint': {
      AppLocale.ru: 'Поиск по переписке',
      AppLocale.en: 'Search chat',
    },
    'chat.searchAction': {AppLocale.ru: 'Поиск', AppLocale.en: 'Search'},
    'chat.resetSessionAction': {
      AppLocale.ru: 'Сбросить шифрование',
      AppLocale.en: 'Reset encryption',
    },
    'chat.resetSessionTitle': {
      AppLocale.ru: 'Сбросить шифрование?',
      AppLocale.en: 'Reset encryption?',
    },
    'chat.resetSessionBody': {
      AppLocale.ru:
          'Текущая сессия шифрования с собеседником будет стёрта и установлена заново при следующем сообщении. Используйте, если сообщения перестали расшифровываться.',
      AppLocale.en:
          'The current encryption session with this contact will be cleared and re-established on the next message. Use this if messages have stopped decrypting.',
    },
    'chat.resetSessionConfirm': {
      AppLocale.ru: 'Сбросить',
      AppLocale.en: 'Reset',
    },
    'chat.resetSessionDone': {
      AppLocale.ru: 'Шифрование сброшено',
      AppLocale.en: 'Encryption reset',
    },
    'chat.showAsList': {
      AppLocale.ru: 'Показать списком',
      AppLocale.en: 'Show as list',
    },
    'chat.showAsChat': {
      AppLocale.ru: 'Показать в чате',
      AppLocale.en: 'Show as chat',
    },
    'chat.searchNoResults': {
      AppLocale.ru: 'Ничего не найдено',
      AppLocale.en: 'No results',
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
    'settings.avatarChange': {
      AppLocale.ru: 'Изменить фото',
      AppLocale.en: 'Change photo',
    },
    'settings.avatarRemove': {
      AppLocale.ru: 'Удалить фото',
      AppLocale.en: 'Remove photo',
    },
    'settings.avatarView': {AppLocale.ru: 'Просмотр', AppLocale.en: 'View'},
    'settings.email': {
      AppLocale.ru: 'Почта для восстановления',
      AppLocale.en: 'Recovery email',
    },
    'settings.backToChats': {
      AppLocale.ru: 'Вернуться к чатам',
      AppLocale.en: 'Back to chats',
    },
    'settings.about': {
      AppLocale.ru: 'О приложении',
      AppLocale.en: 'About the app',
    },
    'settings.clearCache': {
      AppLocale.ru: 'Очистить кэш медиа',
      AppLocale.en: 'Clear media cache',
    },
    'settings.clearCacheTitle': {
      AppLocale.ru: 'Очистить кэш медиа?',
      AppLocale.en: 'Clear media cache?',
    },
    'settings.clearCacheBody': {
      AppLocale.ru:
          'Скачанные фото, видео и другие файлы будут удалены с устройства ({size}) — сама переписка не пострадает, при необходимости файлы можно будет скачать заново.',
      AppLocale.en:
          'Downloaded photos, videos and other files will be removed from this device ({size}) — the chats themselves are not affected, files can be re-downloaded when needed.',
    },
    'settings.cacheEmpty': {
      AppLocale.ru: 'Кэш медиа уже пуст',
      AppLocale.en: 'Media cache is already empty',
    },
    'settings.cacheCleared': {
      AppLocale.ru: 'Кэш медиа очищен',
      AppLocale.en: 'Media cache cleared',
    },
    'settings.privacy': {
      AppLocale.ru: 'Приватность и безопасность',
      AppLocale.en: 'Privacy and security',
    },

    'nav.chats': {AppLocale.ru: 'Чаты', AppLocale.en: 'Chats'},
    'nav.settings': {AppLocale.ru: 'Настройки', AppLocale.en: 'Settings'},
    'nav.profile': {AppLocale.ru: 'Профиль', AppLocale.en: 'Profile'},

    'profile.title': {AppLocale.ru: 'Профиль', AppLocale.en: 'Profile'},
    'profile.login': {AppLocale.ru: 'Логин', AppLocale.en: 'Username'},
    'profile.displayName': {
      AppLocale.ru: 'Отображаемое имя',
      AppLocale.en: 'Display name',
    },
    'profile.displayNameEmpty': {
      AppLocale.ru: 'Не указано',
      AppLocale.en: 'Not set',
    },
    'profile.displayNameHint': {
      AppLocale.ru: 'Как вас будут видеть собеседники',
      AppLocale.en: 'How people will see you',
    },
    'profile.editDisplayName': {
      AppLocale.ru: 'Изменить отображаемое имя',
      AppLocale.en: 'Edit display name',
    },
    'profile.status': {AppLocale.ru: 'Био', AppLocale.en: 'Bio'},
    'profile.statusEmpty': {
      AppLocale.ru: 'Не указано',
      AppLocale.en: 'Not set',
    },
    'profile.statusHint': {
      AppLocale.ru: 'Расскажите о себе',
      AppLocale.en: 'Tell people about yourself',
    },
    'profile.editStatus': {
      AppLocale.ru: 'Изменить био',
      AppLocale.en: 'Edit bio',
    },
    'profile.birthday': {
      AppLocale.ru: 'Дата рождения',
      AppLocale.en: 'Birthday',
    },
    'profile.birthdayEmpty': {
      AppLocale.ru: 'Не указана',
      AppLocale.en: 'Not set',
    },

    'privacy.title': {
      AppLocale.ru: 'Приватность и безопасность',
      AppLocale.en: 'Privacy and security',
    },
    'privacy.findByLogin': {
      AppLocale.ru: 'Кто может найти меня по логину',
      AppLocale.en: 'Who can find me by username',
    },
    'privacy.avatar': {
      AppLocale.ru: 'Кто может видеть моё фото профиля',
      AppLocale.en: 'Who can see my profile photo',
    },
    'privacy.birthday': {
      AppLocale.ru: 'Кто может видеть мою дату рождения',
      AppLocale.en: 'Who can see my birthday',
    },
    'privacy.status': {
      AppLocale.ru: 'Кто видит моё био',
      AppLocale.en: 'Who can see my bio',
    },
    'privacy.everyone': {
      AppLocale.ru: 'Все пользователи',
      AppLocale.en: 'Everyone',
    },
    'privacy.contactsOnly': {
      AppLocale.ru: 'Мои контакты',
      AppLocale.en: 'My contacts',
    },
    'privacy.nobody': {AppLocale.ru: 'Никто', AppLocale.en: 'No one'},
    'privacy.saved': {
      AppLocale.ru: 'Настройки сохранены',
      AppLocale.en: 'Settings saved',
    },
    'privacy.saving': {AppLocale.ru: 'Сохраняем…', AppLocale.en: 'Saving…'},

    'settings.appLock': {
      AppLocale.ru: 'Вход в приложение',
      AppLocale.en: 'App lock',
    },
    'applock.title': {
      AppLocale.ru: 'Вход в приложение',
      AppLocale.en: 'App lock',
    },
    'applock.status': {AppLocale.ru: 'Статус', AppLocale.en: 'Status'},
    'applock.on': {AppLocale.ru: 'Включено', AppLocale.en: 'On'},
    'applock.off': {AppLocale.ru: 'Выключено', AppLocale.en: 'Off'},
    'applock.timeout': {
      AppLocale.ru: 'Время срабатывания блокировки',
      AppLocale.en: 'Lock after',
    },
    'applock.unlockMethod': {
      AppLocale.ru: 'Тип разблокировки',
      AppLocale.en: 'Unlock method',
    },
    'applock.pin': {AppLocale.ru: 'Числовой код', AppLocale.en: 'PIN code'},
    'applock.pinSet': {AppLocale.ru: 'Задан', AppLocale.en: 'Set'},
    'applock.pinNotSet': {AppLocale.ru: 'Не задан', AppLocale.en: 'Not set'},
    'applock.setPin': {
      AppLocale.ru: 'Задать код',
      AppLocale.en: 'Set PIN code',
    },
    'applock.changePin': {
      AppLocale.ru: 'Изменить код',
      AppLocale.en: 'Change PIN code',
    },
    'applock.removePin': {
      AppLocale.ru: 'Убрать код',
      AppLocale.en: 'Remove PIN code',
    },
    'applock.fingerprint': {
      AppLocale.ru: 'Вход по отпечатку пальца',
      AppLocale.en: 'Unlock with fingerprint',
    },
    'applock.face': {
      AppLocale.ru: 'Вход по распознаванию лица',
      AppLocale.en: 'Unlock with face recognition',
    },
    'applock.biometric': {
      AppLocale.ru: 'Биометрический вход',
      AppLocale.en: 'Biometric unlock',
    },
    'applock.needPinFirst': {
      AppLocale.ru: 'Сначала задайте числовой код',
      AppLocale.en: 'Set a PIN code first',
    },
    'applock.enterPin': {
      AppLocale.ru: 'Введите код',
      AppLocale.en: 'Enter your PIN',
    },
    'applock.newPin': {
      AppLocale.ru: 'Придумайте код (4–8 цифр)',
      AppLocale.en: 'Choose a PIN (4–8 digits)',
    },
    'applock.confirmPin': {
      AppLocale.ru: 'Повторите код',
      AppLocale.en: 'Confirm your PIN',
    },
    'applock.pinMismatch': {
      AppLocale.ru: 'Коды не совпадают, попробуйте снова',
      AppLocale.en: "PINs don't match, try again",
    },
    'applock.wrongPin': {
      AppLocale.ru: 'Неверный код',
      AppLocale.en: 'Wrong PIN',
    },
    'applock.unlockWithBiometric': {
      AppLocale.ru: 'Разблокировать по биометрии',
      AppLocale.en: 'Unlock with biometrics',
    },
    'applock.useBiometricReason': {
      AppLocale.ru: 'Подтвердите вход в Oshinobu',
      AppLocale.en: 'Confirm it\'s you to open Oshinobu',
    },
    'applock.usePinInstead': {
      AppLocale.ru: 'Ввести код',
      AppLocale.en: 'Use PIN instead',
    },
    'applock.timeout.30': {
      AppLocale.ru: '30 секунд',
      AppLocale.en: '30 seconds',
    },
    'applock.timeout.60': {AppLocale.ru: '1 минута', AppLocale.en: '1 minute'},
    'applock.timeout.120': {
      AppLocale.ru: '2 минуты',
      AppLocale.en: '2 minutes',
    },
    'applock.timeout.300': {AppLocale.ru: '5 минут', AppLocale.en: '5 minutes'},
    'applock.timeout.600': {
      AppLocale.ru: '10 минут',
      AppLocale.en: '10 minutes',
    },
    'applock.timeout.900': {
      AppLocale.ru: '15 минут',
      AppLocale.en: '15 minutes',
    },
    'applock.timeout.1800': {
      AppLocale.ru: '30 минут',
      AppLocale.en: '30 minutes',
    },
    'applock.timeout.3600': {AppLocale.ru: '1 час', AppLocale.en: '1 hour'},
    'applock.timeout.7200': {AppLocale.ru: '2 часа', AppLocale.en: '2 hours'},

    'about.title': {AppLocale.ru: 'О приложении', AppLocale.en: 'About'},
    'about.version': {
      AppLocale.ru: 'Версия приложения',
      AppLocale.en: 'App version',
    },
    'about.terms': {
      AppLocale.ru: 'Условия использования',
      AppLocale.en: 'Terms of Service',
    },
    'about.privacy': {
      AppLocale.ru: 'Политика конфиденциальности',
      AppLocale.en: 'Privacy Policy',
    },
    'about.feedback': {
      AppLocale.ru: 'Обратная связь',
      AppLocale.en: 'Feedback',
    },
    'about.feedbackHint': {
      AppLocale.ru: 'Расскажите, что понравилось или что стоит улучшить',
      AppLocale.en: "Tell us what you liked or what we should improve",
    },
    'about.feedbackEmpty': {
      AppLocale.ru: 'Напишите хотя бы пару слов',
      AppLocale.en: 'Please write at least a few words',
    },
    'about.feedbackSent': {
      AppLocale.ru: 'Спасибо! Отзыв отправлен',
      AppLocale.en: 'Thanks! Feedback sent',
    },
    'about.shareLog': {
      AppLocale.ru: 'Поделиться логом',
      AppLocale.en: 'Share debug log',
    },
    'about.logEmpty': {
      AppLocale.ru: 'Лог пока пуст',
      AppLocale.en: 'Log is empty',
    },
    'about.clearLog': {
      AppLocale.ru: 'Очистить лог',
      AppLocale.en: 'Clear debug log',
    },
    'about.logCleared': {
      AppLocale.ru: 'Лог очищен',
      AppLocale.en: 'Log cleared',
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
    'theme.light': {AppLocale.ru: 'Светлая тема', AppLocale.en: 'Light theme'},

    'settings.fontSize': {
      AppLocale.ru: 'Размер шрифта',
      AppLocale.en: 'Font size',
    },
    'fontSize.title': {
      AppLocale.ru: 'Размер шрифта',
      AppLocale.en: 'Font size',
    },
    'fontSize.preview': {
      AppLocale.ru: 'Пример текста интерфейса',
      AppLocale.en: 'Interface text preview',
    },
  };
}

String tr(String key) => AppStrings.t(key);
