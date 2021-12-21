import Foundation
import UIKit
import Display
import AccountContext
import NaturalLanguage

// Incuding at least one Objective-C class in a swift file ensures that it doesn't get stripped by the linker
private final class LinkHelperClass: NSObject {
}

public var supportedTranslationLanguages = [
    "en",
    "ar",
    "zh",
    "fr",
    "de",
    "it",
    "jp",
    "ko",
    "pt",
    "ru",
    "es"
]

@available(iOS 12.0, *)
private let languageRecognizer = NLLanguageRecognizer()

public func canTranslateText(context: AccountContext, text: String, showTranslate: Bool, ignoredLanguages: [String]?) -> Bool {
    guard showTranslate, text.count > 0 else {
        return false
    }
    
    if #available(iOS 15.0, *) {
        var dontTranslateLanguages: [String] = []
        if let ignoredLanguages = ignoredLanguages {
            dontTranslateLanguages = ignoredLanguages
        } else {
            dontTranslateLanguages = [context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode]
        }
        
        let text = String(text.prefix(64))
        languageRecognizer.processString(text)
        let hypotheses = languageRecognizer.languageHypotheses(withMaximum: 2)
        languageRecognizer.reset()
        
        if let language = hypotheses.first(where: { supportedTranslationLanguages.contains($0.key.rawValue) }) {
            return !dontTranslateLanguages.contains(language.key.rawValue)
        } else {
            return false
        }
    } else {
        return false
    }
}

public func translateText(context: AccountContext, text: String) {
    guard !text.isEmpty else {
        return
    }
    if #available(iOS 15.0, *) {
        let textView = UITextView()
        textView.text = text
        textView.isEditable = false
        if let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController, let topController = navigationController.topViewController as? ViewController {
            topController.view.addSubview(textView)
            textView.selectAll(nil)
            textView.perform(NSSelectorFromString(["_", "trans", "late:"].joined(separator: "")), with: nil)
            
            DispatchQueue.main.async {
                textView.removeFromSuperview()
            }
        }
    }
}
