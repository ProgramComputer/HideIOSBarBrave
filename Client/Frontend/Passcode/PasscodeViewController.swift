// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import UIKit
import LocalAuthentication
import Shared
import Combine
import BraveShared
import BraveUI
import SwiftKeychainWrapper

private let log = Logger.browserLogger

class WindowProtection {
    
    private class LockedView: UIView {
        let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        let lockImageView = UIImageView(image: UIImage(systemName: "lock.circle")?.applyingSymbolConfiguration(.init(pointSize: 80))).then {
            $0.tintColor = .secondarySystemFill
        }
        let unlockButton = UIButton(type: .system).then {
            $0.setTitle("Unlock", for: .normal)
            $0.setTitleColor(BraveUX.braveOrange, for: .normal)
        }
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            
            addSubview(backgroundView)
            addSubview(lockImageView)
            addSubview(unlockButton)
            backgroundView.snp.makeConstraints {
                $0.edges.equalToSuperview()
            }
            lockImageView.snp.makeConstraints {
                $0.center.equalToSuperview()
            }
            unlockButton.snp.makeConstraints {
                $0.centerX.equalToSuperview()
                $0.top.equalTo(lockImageView.snp.bottom).offset(60)
            }
        }
        
        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError()
        }
    }
    
    private let lockedView = LockedView().then {
        $0.isHidden = true
    }
    private var cancellables: Set<AnyCancellable> = []
    private var protectedWindow: UIWindow
    
    private var isVisible: Bool = false {
        didSet {
            lockedView.isHidden = !isVisible
            if isVisible {
                lockedView.frame = protectedWindow.frame
                protectedWindow.bringSubviewToFront(lockedView)
            }
        }
    }
    
    init(window: UIWindow) {
        protectedWindow = window
        window.addSubview(lockedView)
        
        lockedView.unlockButton.addTarget(self, action: #selector(tappedUnlock), for: .touchUpInside)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink(receiveValue: { _ in
                // Update visibility when entering background
                self.isVisible = Preferences.Privacy.lockWithPasscode.value
            })
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didFinishLaunchingNotification))
            .sink(receiveValue: { _ in
                let isLocked = Preferences.Privacy.lockWithPasscode.value
                self.isVisible = isLocked
                if isLocked {
                    self.presentLocalAuthentication()
                }
            })
            .store(in: &cancellables)
    }
    
    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError()
    }
    
    @objc private func tappedUnlock() {
        presentLocalAuthentication()
    }
    
    private func presentLocalAuthentication() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            lockedView.unlockButton.isHidden = true
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: Strings.authenticationLoginsTouchReason) { success, error in
                DispatchQueue.main.async { [self] in
                    if success {
                        UIView.animate(withDuration: 0.1, animations: {
                            lockedView.alpha = 0.0
                        }, completion: { _ in
                            isVisible = false
                            lockedView.alpha = 1.0
                        })
                    } else {
                        lockedView.unlockButton.isHidden = false
                        if let error = error {
                            log.error("Failed to unlock browser using local authentication: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }
}
