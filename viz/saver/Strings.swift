// The saver's user-visible strings, as in viz.html: English and Russian, English the fallback. The language is the
// `lang` key of the dev.delamain.saver defaults suite, else the first of the system's preferred languages we have.
// Journal text is shown as written.
import Foundation

struct Strings {
    let lang: String
    let connecting: (String) -> String          // server URL
    let notAnswering: (String) -> String        // error
    let noState: String, streamClosed: String   // when the system gives no error text
    let hub: String, noRepo: String
    let owner: String, roster: String           // the roster on the left: its owner row and its header
    let count: (Int, Int, Int) -> String        // stages, workers, busy
    let lastHours: (Int) -> String
    let dayMonth: String                        // date format of the replay line

    static let en = Strings(
        lang: "en",
        connecting: { "DELAMAIN · connecting to \($0)" },
        notAnswering: { "DELAMAIN · hub-viz is not answering (\($0)); retrying" },
        noState: "no answer from /state", streamClosed: "the /events stream closed",
        hub: "hub", noRepo: "no repository",
        owner: "owner", roster: "hubs and cabs",
        count: { s, w, b in "\(s) \(s == 1 ? "hub" : "hubs") · \(w) \(w == 1 ? "cab" : "cabs") · \(b) in flight" },
        lastHours: { "last \($0) h" },
        dayMonth: "MM/dd")

    static let ru = Strings(
        lang: "ru",
        connecting: { "DELAMAIN · подключаюсь к \($0)" },
        notAnswering: { "DELAMAIN · hub-viz не отвечает (\($0)); повторяю" },
        noState: "нет ответа /state", streamClosed: "поток /events закрыт",
        hub: "хаб", noRepo: "без репозитория",
        owner: "владелец", roster: "хабы и такси",
        count: { s, w, b in "\(s) \(ruPlural(s, "хаб", "хаба", "хабов")) · \(w) такси · \(b) в рейсе" },
        lastHours: { "последние \($0) ч" },
        dayMonth: "dd.MM")

    static let all = ["en": en, "ru": ru]
    /// The strings in use, set by the view from its defaults before anything is drawn.
    static var current = en

    /// The table for an explicit choice, else for the first preferred language we have, else English.
    static func resolve(_ explicit: String?, preferred: [String] = Locale.preferredLanguages) -> Strings {
        for l in [explicit].compactMap({ $0 }) + preferred {
            if let s = all[String(l.prefix(2)).lowercased()] { return s }
        }
        return en
    }
}

func ruPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = n % 10, b = n % 100
    return a == 1 && b != 11 ? one : (2...4).contains(a) && !(12...14).contains(b) ? few : many
}
