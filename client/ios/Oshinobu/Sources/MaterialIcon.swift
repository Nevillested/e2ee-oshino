import SwiftUI

/// Значки Material Icons — те же, что в Android-клиенте (Compose `Icons.Filled.*` / `Icons.Outlined.*`),
/// из шрифтов Google (Apache 2.0): `MaterialIcons-Regular.ttf`, `MaterialIconsOutlined-Regular.otf`.
/// Имя case = имя в Compose; у Outlined — префикс `o` (`Icons.Outlined.Lock` → `.oLock`).
/// Файл сгенерирован по списку значков Android-клиента; новые добавлять так же — кодовая точка из
/// `MaterialIcons*-Regular.codepoints` (github.com/google/material-design-icons, папка font/).
enum MaterialIcon: String {
    case arrowBack = "Fe5c4"  // AutoMirrored
    case article = "Fef42"  // AutoMirrored
    case callMade = "Fe0b2"  // AutoMirrored
    case callMissed = "Fe0b4"  // AutoMirrored
    case callReceived = "Fe0b5"  // AutoMirrored
    case forward = "Fe154"  // AutoMirrored
    case insertDriveFile = "Fe24d"  // AutoMirrored
    case logout = "Fe9ba"  // AutoMirrored
    case reply = "Fe15e"  // AutoMirrored
    case send = "Fe163"  // AutoMirrored
    case oBackspace = "Oe14a"  // AutoMirrored
    case oChat = "Oe0b7"  // AutoMirrored
    case oForward = "Oe154"  // AutoMirrored
    case oInsertDriveFile = "Oe24d"  // AutoMirrored
    case oStickyNote2 = "Of1fc"  // AutoMirrored
    case add = "Fe145"
    case android = "Fe859"
    case attachFile = "Fe226"
    case audiotrack = "Fe3a1"
    case block = "Fe14b"
    case bluetoothAudio = "Fe60f"
    case brokenImage = "Fe3ad"
    case call = "Fe0b0"
    case callEnd = "Fe0b1"
    case cameraAlt = "Fe3b0"
    case cameraswitch = "Fefeb"
    case check = "Fe5ca"
    case checkBox = "Fe834"
    case checkBoxOutlineBlank = "Fe835"
    case checkCircle = "Fe86c"
    case chevronLeft = "Fe5cb"
    case cleaningServices = "Ff0ff"
    case close = "Fe5cd"
    case closeFullscreen = "Ff1cf"
    case code = "Fe86f"
    case contentCopy = "Fe14d"
    case deleteForever = "Fe92b"
    case description = "Fe873"
    case done = "Fe876"
    case doneAll = "Fe877"
    case download = "Ff090"
    case edit = "Fe3c9"
    case errorOutline = "Fe001"
    case face = "Fe87c"
    case fingerprint = "Fe90d"
    case folderZip = "Feb2c"
    case headset = "Fe310"
    case hearing = "Fe023"
    case image = "Fe3f4"
    case keyboard = "Fe312"
    case keyboardArrowDown = "Fe313"
    case keyboardArrowUp = "Fe316"
    case lockReset = "Feade"
    case mic = "Fe029"
    case micOff = "Fe02b"
    case moreVert = "Fe5d4"
    case notificationsOff = "Fe7f6"
    case pause = "Fe034"
    case person = "Fe7fd"
    case pictureAsPdf = "Fe415"
    case playArrow = "Fe037"
    case playCircleFilled = "Fe038"
    case pushPin = "Ff10d"
    case refresh = "Fe5d5"
    case schedule = "Fe8b5"
    case search = "Fe8b6"
    case slideshow = "Fe41b"
    case swapVert = "Fe8d5"
    case systemUpdate = "Fe62a"
    case tableChart = "Fe265"
    case textFields = "Fe262"
    case tune = "Fe429"
    case videocam = "Fe04b"
    case videocamOff = "Fe04c"
    case visibility = "Fe8f4"
    case visibilityOff = "Fe8f5"
    case volumeUp = "Fe050"
    case oBadge = "Oea67"
    case oCake = "Oe7e9"
    case oCall = "Oe0b0"
    case oChatBubbleOutline = "Oe0cb"
    case oCheckCircleOutline = "Oe92d"
    case oContentCopy = "Of08a"
    case oDelete = "Oe872"
    case oDescription = "Oe873"
    case oDownload = "Of090"
    case oEdit = "Oe3c9"
    case oEmail = "Oe0be"
    case oEmojiEmotions = "Oea22"
    case oFlag = "Oe153"
    case oFolderZip = "Oeb2c"
    case oHideImage = "Of022"
    case oImage = "Oe3f4"
    case oInfo = "Oe88e"
    case oLanguage = "Oe894"
    case oLock = "Oe897"
    case oMic = "Oe029"
    case oPalette = "Oe40a"
    case oPermMedia = "Oe8a7"
    case oPerson = "Oe7fd"
    case oPhonelinkLock = "Oe0dc"
    case oPhoto = "Oe410"
    case oPhotoCamera = "Oe412"
    case oPin = "Of045"
    case oPrivacyTip = "Of0dc"
    case oPushPin = "Of10d"
    case oRadioButtonUnchecked = "Oe836"
    case oSchedule = "Oe8b5"
    case oSearch = "Oe8b6"
    case oTimer = "Oe425"
    case oVisibility = "Oe8f4"
    case oWallpaper = "Oe75f"

    var outlined: Bool { rawValue.hasPrefix("O") }

    /// Символ в шрифте.
    var glyph: String { String(UnicodeScalar(UInt32(rawValue.dropFirst(), radix: 16)!)!) }
}
