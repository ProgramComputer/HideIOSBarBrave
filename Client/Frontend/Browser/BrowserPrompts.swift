/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import Shared

@objc protocol JSPromptAlertControllerDelegate: AnyObject {
    func promptAlertControllerDidDismiss(_ alertController: JSPromptAlertController)
}

/// A simple version of UIAlertController that attaches a delegate to the viewDidDisappear method
/// to allow forwarding the event. The reason this is needed for prompts from Javascript is we
/// need to invoke the completionHandler passed to us from the WKWebView delegate or else
/// a runtime exception is thrown.
class JSPromptAlertController: UIAlertController {
    
    var info: JSAlertInfo?
    var showsCancel: Bool = false
    
    convenience init(title: String?, message: String?, preferredStyle: UIAlertController.Style = .alert, info: JSAlertInfo, showCancel: Bool = true) {
        self.init(title: title, message: message, preferredStyle: preferredStyle)
        self.info = info
        self.showsCancel = showCancel
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if let handler = info?.suppressHandler {
            self.addAction(UIAlertAction(title: Strings.suppressAlertsActionTitle, style: .default, handler: { _ in
                handler(true)
            }))
        }
        if showsCancel {
            self.addAction(UIAlertAction(title: Strings.cancelButtonTitle, style: .cancel, handler: { _ in
                self.info?.cancel()
            }))
        }
    }
    
    weak var delegate: JSPromptAlertControllerDelegate?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        delegate?.promptAlertControllerDidDismiss(self)
    }
}

/**
 *  An JSAlertInfo is used to store information about an alert we want to show either immediately or later.
 *  Since alerts are generated by web pages and have no upper limit it would be unwise to allocate a
 *  UIAlertController instance for each generated prompt which could potentially be queued in the background.
 *  Instead, the JSAlertInfo structure retains the relevant data needed for the prompt along with a copy
 *  of the provided completionHandler to let us generate the UIAlertController when needed.
 */
protocol JSAlertInfo {
    typealias SuppressHandler = (Bool) -> Void
    func alertController() -> JSPromptAlertController
    func cancel()
    var suppressHandler: SuppressHandler? {get set}
}

struct MessageAlert: JSAlertInfo {
    let message: String
    let frame: WKFrameInfo
    let completionHandler: () -> Void
    var suppressHandler: SuppressHandler?

    func alertController() -> JSPromptAlertController {
        let alertController = JSPromptAlertController(title: titleForJavaScriptPanelInitiatedByFrame(frame),
                                                                    message: message,
                                                                    info: self,
                                                                    showCancel: false)
        alertController.addAction(UIAlertAction(title: Strings.OKString, style: .default) { _ in
            self.completionHandler()
        })
        return alertController
    }

    func cancel() {
        completionHandler()
    }
}

struct ConfirmPanelAlert: JSAlertInfo {
    let message: String
    let frame: WKFrameInfo
    let completionHandler: (Bool) -> Void
    var suppressHandler: SuppressHandler?

    func alertController() -> JSPromptAlertController {
        // Show JavaScript confirm dialogs.
        let alertController = JSPromptAlertController(title: titleForJavaScriptPanelInitiatedByFrame(frame),
                                                                    message: message,
                                                                    info: self)
        alertController.addAction(UIAlertAction(title: Strings.OKString, style: .default) { _ in
            self.completionHandler(true)
        })
        return alertController
    }

    func cancel() {
        completionHandler(false)
    }
}

struct TextInputAlert: JSAlertInfo {
    let message: String
    let frame: WKFrameInfo
    let completionHandler: (String?) -> Void
    let defaultText: String?
    var suppressHandler: SuppressHandler?
    
    func alertController() -> JSPromptAlertController {
        let alertController = JSPromptAlertController(title: titleForJavaScriptPanelInitiatedByFrame(frame),
                                                                    message: message,
                                                                    info: self)
        var input: UITextField!
        alertController.addTextField(configurationHandler: { (textField: UITextField) in
            input = textField
            input.text = self.defaultText
        })
        alertController.addAction(UIAlertAction(title: Strings.OKString, style: .default) { _ in
            self.completionHandler(input.text)
        })
        return alertController
    }

    func cancel() {
        completionHandler(nil)
    }
}

/// Show a title for a JavaScript Panel (alert) based on the WKFrameInfo. On iOS9 we will use the new securityOrigin
/// and on iOS 8 we will fall back to the request URL. If the request URL is nil, which happens for JavaScript pages,
/// we fall back to "JavaScript" as a title.
private func titleForJavaScriptPanelInitiatedByFrame(_ frame: WKFrameInfo) -> String {
    var title = "\(frame.securityOrigin.`protocol`)://\(frame.securityOrigin.host)"
    if frame.securityOrigin.port != 0 {
        title += ":\(frame.securityOrigin.port)"
    }
    return title
}
