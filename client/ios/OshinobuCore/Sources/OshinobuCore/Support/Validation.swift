import Foundation

// Проверки ввода при регистрации и смене пароля — те же правила, что у сервера
// (auth.ValidateLogin / password_policy.go) и Android (core/auth/Validation.kt).
// Возвращают ключ локализации ошибки или nil.

/// Логин: только латиница и цифры, 3–32 символа (закрывает кириллические омоглифы).
public func validateLogin(_ login: String) -> String? {
    login.range(of: "^[A-Za-z0-9]{3,32}$", options: .regularExpression) == nil ? "login.invalid" : nil
}

/// Пароль: от 6 символов, заглавная, строчная, цифра и спецсимвол.
public func validatePassword(_ password: String) -> String? {
    func any(_ r: ClosedRange<Character>) -> Bool { password.contains { r.contains($0) } }
    if password.count < 6 { return "password.tooShort" }
    if !any("A"..."Z") { return "password.needUpper" }
    if !any("a"..."z") { return "password.needLower" }
    if !any("0"..."9") { return "password.needDigit" }
    if password.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) }) { return "password.needSpecial" }
    return nil
}

/// Секрет TOTP из otpauth://-ссылки (для ручного ввода в приложение-аутентификатор).
public func totpSecret(_ otpauthURL: String) -> String {
    guard let query = otpauthURL.split(separator: "?", maxSplits: 1).dropFirst().first else { return "" }
    return query.split(separator: "&").first { $0.hasPrefix("secret=") }.map { String($0.dropFirst("secret=".count)) } ?? ""
}
