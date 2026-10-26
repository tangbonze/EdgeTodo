import Foundation

/// 界面语言：默认跟随系统，也可以在菜单里锁定成中文或英文。
///
/// 这里没有走 `Localizable.strings` / `.lproj` 那一套，而是用
/// `L10n.t("中文", "English")` 把两种文案直接写在调用点 —— 只有一个 app
/// 内置两种语言，字符串就在旁边，翻译漏了编译器不影响但 review 一眼能看出来，
/// 也不用维护一份 key 表。
enum AppLanguage: String, CaseIterable {
    case system
    case chinese
    case english

    /// 菜单里显示的名字
    var menuTitle: String {
        switch self {
        case .system:  return L10n.t("跟随系统", "Follow System")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

enum L10n {
    private static let key = "appLanguage"

    static var language: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? AppLanguage.system.rawValue
            return AppLanguage(rawValue: raw) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// 系统首选语言是不是中文（含粤语）
    static var systemIsChinese: Bool {
        let code = Locale.preferredLanguages.first ?? "en"
        return code.hasPrefix("zh") || code.hasPrefix("yue")
    }

    static var isEnglish: Bool {
        switch language {
        case .chinese: return false
        case .english: return true
        case .system:  return !systemIsChinese
        }
    }

    /// 双语文案：中文在前、英文在后
    static func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }

    /// 当前界面语言对应的 Locale（给日期格式用）
    static var uiLocale: Locale {
        Locale(identifier: isEnglish ? "en_US" : "zh_CN")
    }

    /// 通知界面重建（切换语言后调用）
    static let languageChanged = Notification.Name("EdgeTodoLanguageChanged")
}
