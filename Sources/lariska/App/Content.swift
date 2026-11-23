import Foundation
import LariskaCore

enum Act: CaseIterable {
    case demo, greeting, play, pad, vowels, parrot, morse, katyusha, beat, say, range, settings

    var title: String {
        switch self {
        case .demo: "демо-версия"
        case .greeting: "привет"
        case .play: "играть"
        case .pad: "дрэм-пад"
        case .vowels: "гласные"
        case .parrot: "попугай"
        case .morse: "морзе"
        case .katyusha: "катюша"
        case .beat: "бит"
        case .say: "скажи"
        case .range: "диапазон"
        case .settings: "настройки голоса"
        }
    }
}

enum Script {
    static let greeting = "Привет! Меня зовут Лариса, я твой трекпад. Раньше я умела только щёлкать, а теперь говорю. Смотри, на что я способна."
    static let rap = [
        "На часах уже за полночь, во дворе ни души,",
        "Только ветер качает пустые этажи.",
        "Я иду по району, руки глубже в карман,",
        "Все дневные проблемы уплывают в туман.",
    ]
    static let yourTurn = "Теперь твоя очередь."
    static let sample = "Привет. Меня зовут Лариса. Так звучит мой голос."
}

/// Settings on disk at ~/.config/lariska/settings.json.
enum SettingsFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lariska/settings.json")

    /// A missing file means defaults; an unreadable one is reported and replaced by defaults.
    static func load() -> (settings: Settings, problem: String?) {
        guard let data = try? Data(contentsOf: url) else { return (Settings(), nil) }
        do { return (try JSONDecoder().decode(Settings.self, from: data), nil) }
        catch { return (Settings(), "настройки не прочитаны, взяты значения по умолчанию") }
    }

    static func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try settings.json().write(to: url, options: .atomic)
    }
}
